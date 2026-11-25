// SVPlayer modification (2026-11-25): Tolerant stream-info probing, staged budgets,
// auxiliary-stream parking, server MediaStreams hint backfilling, and deferred
// packet-time codec parameter completion for incomplete/high-latency media headers.

import Foundation
import os
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

// MARK: - Server-Supplied Stream Hints (e.g. Jellyfin / Emby PlaybackInfo MediaStreams)

/// Stream-level metadata supplied by an upstream media server (such as Jellyfin/Emby
/// `PlaybackInfo.MediaStreams`) used strictly as a non-destructive backfill when container
/// headers or bounded stream probing leave `AVCodecParameters` incomplete.
public struct DemuxerStreamHint: Sendable, Equatable {
    public enum MediaKind: String, Sendable, Equatable {
        case video
        case audio
        case subtitle
    }

    public let kind: MediaKind
    public let streamIndex: Int?
    public let codecName: String?
    public let width: Int32?
    public let height: Int32?
    public let frameRate: Double?
    public let bitDepth: Int32?
    public let sampleRate: Int32?
    public let channels: Int32?
    public let bitrate: Int64?
    public let language: String?
    public let title: String?
    public let isDefault: Bool
    public let isForced: Bool
    public let colorPrimaries: String?
    public let colorTransfer: String?
    public let colorSpace: String?

    public init(
        kind: MediaKind,
        streamIndex: Int? = nil,
        codecName: String? = nil,
        width: Int32? = nil,
        height: Int32? = nil,
        frameRate: Double? = nil,
        bitDepth: Int32? = nil,
        sampleRate: Int32? = nil,
        channels: Int32? = nil,
        bitrate: Int64? = nil,
        language: String? = nil,
        title: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        colorPrimaries: String? = nil,
        colorTransfer: String? = nil,
        colorSpace: String? = nil
    ) {
        self.kind = kind
        self.streamIndex = streamIndex
        self.codecName = codecName
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitrate = bitrate
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.isForced = isForced
        self.colorPrimaries = colorPrimaries
        self.colorTransfer = colorTransfer
        self.colorSpace = colorSpace
    }
}

/// Container + per-stream hints registered for a playback URL before `AetherEngine.load` / `probe`.
public struct DemuxerMediaHints: Sendable, Equatable {
    public let durationSeconds: Double?
    public let container: String?
    public let streams: [DemuxerStreamHint]

    public init(
        durationSeconds: Double? = nil,
        container: String? = nil,
        streams: [DemuxerStreamHint] = []
    ) {
        self.durationSeconds = durationSeconds
        self.container = container
        self.streams = streams
    }

    public var isEmpty: Bool {
        let hasDuration = (durationSeconds ?? 0) > 0
        return !hasDuration && streams.isEmpty
    }
}

/// Scoped, thread-safe registry associating active media URLs with upstream `DemuxerMediaHints`.
/// Mirrors `EngineTLS` so hosts can attach Jellyfin/Emby `PlaybackInfo` hints without expanding
/// every intermediate signature between the app layer and `Demuxer`.
public enum DemuxerStreamHintRegistry {
    private struct Entry: Sendable {
        let urls: Set<String>
        let pathKeys: Set<String>
        let hints: DemuxerMediaHints
        let registeredAt: Date
    }

    private struct State: Sendable {
        var entries: [UUID: Entry] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    /// Safety TTL so an abandoned token never accumulates indefinitely.
    private static let entryTTL: TimeInterval = 30 * 60

    @discardableResult
    public static func register(hints: DemuxerMediaHints, for urls: [URL]) -> UUID? {
        guard !hints.isEmpty, !urls.isEmpty else { return nil }
        let normalizedExact = Set(urls.map(exactKey))
        let normalizedPath = Set(urls.compactMap(originPathKey))
        let token = UUID()
        let now = Date()
        state.withLock { s in
            s.entries = s.entries.filter { now.timeIntervalSince($0.value.registeredAt) < entryTTL }
            s.entries[token] = Entry(
                urls: normalizedExact,
                pathKeys: normalizedPath,
                hints: hints,
                registeredAt: now
            )
        }
        return token
    }

    public static func unregister(_ token: UUID?) {
        guard let token else { return }
        state.withLock { _ = $0.entries.removeValue(forKey: token) }
    }

    public static func hints(for url: URL) -> DemuxerMediaHints? {
        let exact = exactKey(url)
        let pathKey = originPathKey(url)
        let now = Date()
        return state.withLock { s in
            var exactMatch: (Date, DemuxerMediaHints)?
            var pathMatch: (Date, DemuxerMediaHints)?
            for entry in s.entries.values where now.timeIntervalSince(entry.registeredAt) < entryTTL {
                if entry.urls.contains(exact) {
                    if exactMatch == nil || entry.registeredAt > exactMatch!.0 {
                        exactMatch = (entry.registeredAt, entry.hints)
                    }
                } else if let pathKey, entry.pathKeys.contains(pathKey) {
                    if pathMatch == nil || entry.registeredAt > pathMatch!.0 {
                        pathMatch = (entry.registeredAt, entry.hints)
                    }
                }
            }
            return exactMatch?.1 ?? pathMatch?.1
        }
    }

    static func resetForTesting() {
        state.withLock { $0.entries.removeAll() }
    }

    private static func exactKey(_ url: URL) -> String {
        url.standardizedFileURL.absoluteString
    }

    private static func originPathKey(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)\(url.path)"
    }
}

// MARK: - Staged Probe Planning & Guard

/// Pure, unit-testable policy governing staged `avformat_find_stream_info` budgets,
/// auxiliary stream parking, soft wall-clock timeouts, and deferred parameter completion.
enum StreamInfoTolerance {

    // MARK: Staged Budget Plan

    /// Pure, unit-testable policy governing staged stream-info probing:
    /// - Stage 1 narrows `avformat_find_stream_info` to a bounded byte/duration/wall-clock cap
    ///   (always calling `avformat_find_stream_info` at most ONCE per `AVFormatContext`).
    /// - Stage 2 (if primary video/audio codecpar is still incomplete after Stage 1) performs a
    ///   bounded `av_read_frame` in-band bitstream scan for SPS/PPS/VPS/ADTS/EAC3 headers.
    struct ProbeStagePlan: Equatable, Sendable {
        /// Stage 1: fast bounded `avformat_find_stream_info` budget that resolves healthy streams
        /// in milliseconds without scanning 50 MiB / 60 s when an auxiliary stream is incomplete.
        let stage1Probesize: Int64
        let stage1MaxAnalyzeDuration: Int64
        /// Optional wall-clock soft timeout for Stage 1 (nil when caller's `ProbeControl` owns timing).
        let stage1SoftTimeoutSeconds: TimeInterval?
        /// Grace window after primary video+audio are already resolved before soft early-exit fires.
        let primaryReadyGraceSeconds: TimeInterval
        /// Grace window when primary video is resolved but audio is still pending.
        let videoOnlyReadyGraceSeconds: TimeInterval

        /// Stage 2: bounded in-band `av_read_frame` scan budget used ONLY when Stage 1 left
        /// primary video/audio parameters incomplete (e.g. late first keyframe / mid-GOP TS).
        let stage2ScanMaxPackets: Int
        let stage2ScanMaxBytes: Int
        let stage2ScanMaxSeconds: TimeInterval

        var hasStage2Scan: Bool {
            stage2ScanMaxPackets > 0 && stage2ScanMaxBytes > 0 && stage2ScanMaxSeconds > 0
        }
    }

    static let defaultStage1Probesize: Int64 = 8 * 1024 * 1024          // 8 MiB
    static let defaultStage1AnalyzeDuration: Int64 = 8 * 1_000_000      // 8 s
    static let defaultStage2ScanMaxPackets: Int = 1500
    static let defaultStage2ScanMaxBytes: Int = 16 * 1024 * 1024        // 16 MiB
    static let defaultStage2ScanMaxSecondsVOD: TimeInterval = 4.0
    static let defaultStage2ScanMaxSecondsLive: TimeInterval = 2.0
    static let defaultStage1SoftTimeoutVOD: TimeInterval = 8.0
    static let defaultStage1SoftTimeoutLive: TimeInterval = 8.0
    static let defaultPrimaryReadyGraceSeconds: TimeInterval = 1.5
    static let defaultVideoOnlyReadyGraceSeconds: TimeInterval = 3.0

    /// Build a staged probe plan bounded strictly by `profile.probesize` / `profile.maxAnalyzeDuration`.
    static func makeStagePlan(
        profile: DemuxerOpenProfile,
        isLive: Bool,
        hasProbeControl: Bool
    ) -> ProbeStagePlan {
        let capProbe = max(32, profile.probesize)
        let capAnalyze = max(100_000, profile.maxAnalyzeDuration)

        guard profile.tolerantStreamInfo else {
            return ProbeStagePlan(
                stage1Probesize: capProbe,
                stage1MaxAnalyzeDuration: capAnalyze,
                stage1SoftTimeoutSeconds: nil,
                primaryReadyGraceSeconds: .infinity,
                videoOnlyReadyGraceSeconds: .infinity,
                stage2ScanMaxPackets: 0,
                stage2ScanMaxBytes: 0,
                stage2ScanMaxSeconds: 0
            )
        }

        let targetStage1Probe = profile.probeStage1Probesize ?? defaultStage1Probesize
        let targetStage1Analyze = profile.probeStage1MaxAnalyzeDuration ?? defaultStage1AnalyzeDuration
        let s1Probe = min(capProbe, max(32, targetStage1Probe))
        let s1Analyze = min(capAnalyze, max(100_000, targetStage1Analyze))

        let s1Timeout: TimeInterval? = hasProbeControl
            ? nil
            : (profile.probeSoftWallClockTimeout ?? (isLive ? defaultStage1SoftTimeoutLive : defaultStage1SoftTimeoutVOD))

        let primaryGrace = profile.primaryReadyGraceSeconds ?? defaultPrimaryReadyGraceSeconds
        let videoOnlyGrace = max(primaryGrace + 1.0, defaultVideoOnlyReadyGraceSeconds)

        // Stage 2 in-band scan respects tighter caller probe ceilings (e.g. stillExtraction at 2 MiB).
        let allowExtendedScan = capProbe > s1Probe || capAnalyze > s1Analyze
        let s2Packets = allowExtendedScan ? defaultStage2ScanMaxPackets : 96
        let s2Bytes = Int(min(capProbe, Int64(allowExtendedScan ? defaultStage2ScanMaxBytes : 2 * 1024 * 1024)))
        let s2Seconds: TimeInterval
        if let custom = profile.probeSoftWallClockTimeout {
            s2Seconds = min(custom, 1.5)
        } else {
            s2Seconds = allowExtendedScan
                ? (isLive ? defaultStage2ScanMaxSecondsLive : defaultStage2ScanMaxSecondsVOD)
                : 1.5
        }

        return ProbeStagePlan(
            stage1Probesize: s1Probe,
            stage1MaxAnalyzeDuration: s1Analyze,
            stage1SoftTimeoutSeconds: s1Timeout,
            primaryReadyGraceSeconds: primaryGrace,
            videoOnlyReadyGraceSeconds: videoOnlyGrace,
            stage2ScanMaxPackets: s2Packets,
            stage2ScanMaxBytes: max(0, s2Bytes),
            stage2ScanMaxSeconds: s2Seconds
        )
    }

    // MARK: Auxiliary Stream Parking Policy

    struct ParkedStream: Equatable {
        let index: Int
        let originalType: AVMediaType
        let originalDiscard: AVDiscard
        let changedType: Bool
        let changedDiscard: Bool
    }

    static let stillImageVideoCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_MJPEG,
        AV_CODEC_ID_PNG,
        AV_CODEC_ID_BMP,
        AV_CODEC_ID_GIF,
        AV_CODEC_ID_WEBP,
    ]

    /// Sparse / bitmap / auxiliary subtitle codecs whose `has_codec_parameters` check in FFmpeg
    /// can stall `avformat_find_stream_info` until the full probe ceiling when the first cue is
    /// minutes into the movie or missing altogether.
    static let sparseAuxiliarySubtitleCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_HDMV_PGS_SUBTITLE,
        AV_CODEC_ID_DVB_SUBTITLE,
        AV_CODEC_ID_DVD_SUBTITLE,
        AV_CODEC_ID_XSUB,
        AV_CODEC_ID_DVB_TELETEXT,
        AV_CODEC_ID_EIA_608,
        AV_CODEC_ID_HDMV_TEXT_SUBTITLE,
    ]

    /// Pure predicate deciding whether a stream should be parked during Stage 1 `find_stream_info`
    /// so incomplete/sparse auxiliary streams never stall primary playback startup.
    static func shouldParkAuxiliaryStreamForStage1(
        codecType: AVMediaType,
        codecID: AVCodecID,
        disposition: Int32,
        hasDecoder: Bool,
        containerHasPrimaryVideo: Bool,
        containerHasKnownAudio: Bool
    ) -> (parkAsAttachment: Bool, discardPackets: Bool) {
        if Demuxer.isAttachedPicture(disposition: disposition) {
            return (false, false) // handled by reclassifyAttachedPictures
        }
        switch codecType {
        case AVMEDIA_TYPE_SUBTITLE:
            if codecID == AV_CODEC_ID_NONE {
                return (true, true)
            }
            if sparseAuxiliarySubtitleCodecs.contains(codecID) || !hasDecoder {
                return (true, false)
            }
            return (false, false)

        case AVMEDIA_TYPE_UNKNOWN:
            // Only park UNKNOWN tracks if the container already declares a real video or audio track;
            // otherwise FFmpeg needs to sniff the stream to discover the media.
            if containerHasPrimaryVideo || containerHasKnownAudio {
                return (true, true)
            }
            return (false, false)

        case AVMEDIA_TYPE_DATA:
            if codecID == AV_CODEC_ID_NONE || codecID == AV_CODEC_ID_BIN_DATA {
                return (true, true)
            }
            return (false, false)

        case AVMEDIA_TYPE_VIDEO:
            // Never park the only video track or a split Dolby Vision HEVC enhancement layer.
            guard containerHasPrimaryVideo else { return (false, false) }
            if codecID == AV_CODEC_ID_NONE {
                return (true, true)
            }
            if stillImageVideoCodecs.contains(codecID) {
                return (true, false)
            }
            return (false, false)

        case AVMEDIA_TYPE_AUDIO:
            // If a known audio track already exists, a secondary track with AV_CODEC_ID_NONE
            // (corrupt/unidentified track header) must not stall probing.
            if containerHasKnownAudio && codecID == AV_CODEC_ID_NONE {
                return (true, true)
            }
            return (false, false)

        default:
            return (false, false)
        }
    }

    static func parkAuxiliaryStreamsForStage1(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> [ParkedStream] {
        let nbStreams = Int(ctx.pointee.nb_streams)
        var hasPrimaryVideo = false
        var hasKnownAudio = false
        for i in 0..<nbStreams {
            guard let stream = ctx.pointee.streams[i],
                  let par = stream.pointee.codecpar else { continue }
            let disp = stream.pointee.disposition
            if Demuxer.isAttachedPicture(disposition: disp) { continue }
            if par.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
               par.pointee.codec_id != AV_CODEC_ID_NONE,
               !stillImageVideoCodecs.contains(par.pointee.codec_id) {
                hasPrimaryVideo = true
            }
            if par.pointee.codec_type == AVMEDIA_TYPE_AUDIO,
               par.pointee.codec_id != AV_CODEC_ID_NONE {
                hasKnownAudio = true
            }
        }

        var parked: [ParkedStream] = []
        for i in 0..<nbStreams {
            guard let stream = ctx.pointee.streams[i],
                  let par = stream.pointee.codecpar else { continue }
            let codecID = par.pointee.codec_id
            let hasDecoder = codecID != AV_CODEC_ID_NONE && avcodec_find_decoder(codecID) != nil
            let decision = shouldParkAuxiliaryStreamForStage1(
                codecType: par.pointee.codec_type,
                codecID: codecID,
                disposition: stream.pointee.disposition,
                hasDecoder: hasDecoder,
                containerHasPrimaryVideo: hasPrimaryVideo,
                containerHasKnownAudio: hasKnownAudio
            )
            guard decision.parkAsAttachment || decision.discardPackets else { continue }
            let originalType = par.pointee.codec_type
            let originalDiscard = stream.pointee.discard
            if decision.parkAsAttachment {
                par.pointee.codec_type = AVMEDIA_TYPE_ATTACHMENT
            }
            if decision.discardPackets {
                stream.pointee.discard = AVDISCARD_ALL
            }
            parked.append(ParkedStream(
                index: i,
                originalType: originalType,
                originalDiscard: originalDiscard,
                changedType: decision.parkAsAttachment,
                changedDiscard: decision.discardPackets
            ))
        }
        return parked
    }

    static func unparkStreams(_ ctx: UnsafeMutablePointer<AVFormatContext>, _ parked: [ParkedStream]) {
        let nbStreams = Int(ctx.pointee.nb_streams)
        for entry in parked where entry.index < nbStreams {
            guard let stream = ctx.pointee.streams[entry.index] else { continue }
            if entry.changedType {
                stream.pointee.codecpar?.pointee.codec_type = entry.originalType
            }
            if entry.changedDiscard {
                stream.pointee.discard = entry.originalDiscard
            }
        }
    }

    // MARK: Primary Readiness Evaluation & Soft Probe Guard

    struct StreamReadiness: Equatable, Sendable {
        let hasAnyVideoStream: Bool
        let hasResolvedVideo: Bool
        let hasAnyAudioStream: Bool
        let hasResolvedAudio: Bool
        /// True when at least one video or audio stream carries a known codec ID (even if
        /// dimensions / sample_rate are not yet filled and will be backfilled or completed lazily).
        let hasKnownCodecMediaStream: Bool

        /// Primary playback readiness: resolved video (or resolved audio for audio-only media).
        var isPrimaryPlayable: Bool {
            if hasAnyVideoStream {
                return hasResolvedVideo
            }
            return hasResolvedAudio
        }

        /// Both video and audio (when audio exists) are resolved.
        var areAllPrimaryTracksResolved: Bool {
            if hasAnyVideoStream {
                return hasResolvedVideo && (!hasAnyAudioStream || hasResolvedAudio)
            }
            return hasResolvedAudio
        }
    }

    static func evaluateReadiness(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> StreamReadiness {
        let nbStreams = Int(ctx.pointee.nb_streams)
        var hasAnyVideo = false
        var hasResolvedVideo = false
        var hasAnyAudio = false
        var hasResolvedAudio = false
        var hasKnownCodec = false

        for i in 0..<nbStreams {
            guard let stream = ctx.pointee.streams[i],
                  let par = stream.pointee.codecpar,
                  !Demuxer.isAttachedPicture(disposition: stream.pointee.disposition) else { continue }
            let p = par.pointee
            switch p.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                if stillImageVideoCodecs.contains(p.codec_id) { continue }
                hasAnyVideo = true
                if p.codec_id != AV_CODEC_ID_NONE {
                    hasKnownCodec = true
                    if p.width > 0 && p.height > 0 {
                        hasResolvedVideo = true
                    }
                }
            case AVMEDIA_TYPE_AUDIO:
                hasAnyAudio = true
                if p.codec_id != AV_CODEC_ID_NONE {
                    hasKnownCodec = true
                    if p.sample_rate > 0 && p.ch_layout.nb_channels > 0 {
                        hasResolvedAudio = true
                    }
                }
            default:
                break
            }
        }
        return StreamReadiness(
            hasAnyVideoStream: hasAnyVideo,
            hasResolvedVideo: hasResolvedVideo,
            hasAnyAudioStream: hasAnyAudio,
            hasResolvedAudio: hasResolvedAudio,
            hasKnownCodecMediaStream: hasKnownCodec
        )
    }

    /// Pure decision function for `DemuxInterrupt`'s soft probe guard.
    enum GuardVerdict: Equatable, Sendable {
        case keepProbing
        case stopPrimaryReady
        case stopWallClockTimeout
    }

    struct ProbeGuardState: Sendable {
        let startedAtNs: UInt64
        let softTimeoutNs: UInt64?
        let primaryReadyGraceNs: UInt64
        let videoOnlyReadyGraceNs: UInt64
        var primaryReadySinceNs: UInt64?
        var videoOnlyReadySinceNs: UInt64?
        var triggerReason: GuardVerdict = .keepProbing

        init(
            startedAtNs: UInt64,
            softTimeoutSeconds: TimeInterval?,
            primaryReadyGraceSeconds: TimeInterval,
            videoOnlyReadyGraceSeconds: TimeInterval
        ) {
            self.startedAtNs = startedAtNs
            self.softTimeoutNs = softTimeoutSeconds.flatMap {
                $0.isFinite && $0 > 0 ? UInt64($0 * 1_000_000_000) : nil
            }
            self.primaryReadyGraceNs = primaryReadyGraceSeconds.isFinite && primaryReadyGraceSeconds >= 0
                ? UInt64(primaryReadyGraceSeconds * 1_000_000_000) : .max
            self.videoOnlyReadyGraceNs = videoOnlyReadyGraceSeconds.isFinite && videoOnlyReadyGraceSeconds >= 0
                ? UInt64(videoOnlyReadyGraceSeconds * 1_000_000_000) : .max
        }

        mutating func evaluate(nowNs: UInt64, readiness: StreamReadiness) -> GuardVerdict {
            if triggerReason != .keepProbing { return triggerReason }
            let elapsed = nowNs >= startedAtNs ? (nowNs - startedAtNs) : 0

            if let softTimeoutNs, elapsed >= softTimeoutNs {
                triggerReason = .stopWallClockTimeout
                return .stopWallClockTimeout
            }

            if readiness.areAllPrimaryTracksResolved {
                if primaryReadySinceNs == nil { primaryReadySinceNs = nowNs }
                let readyElapsed = nowNs >= primaryReadySinceNs! ? (nowNs - primaryReadySinceNs!) : 0
                if readyElapsed >= primaryReadyGraceNs {
                    triggerReason = .stopPrimaryReady
                    return .stopPrimaryReady
                }
            } else if readiness.isPrimaryPlayable {
                if videoOnlyReadySinceNs == nil { videoOnlyReadySinceNs = nowNs }
                let readyElapsed = nowNs >= videoOnlyReadySinceNs! ? (nowNs - videoOnlyReadySinceNs!) : 0
                if readyElapsed >= videoOnlyReadyGraceNs {
                    triggerReason = .stopPrimaryReady
                    return .stopPrimaryReady
                }
            }
            return .keepProbing
        }
    }

    // MARK: Tolerant Primary Stream Selection

    /// Selects the best video stream even when `av_find_best_stream` skips an incomplete
    /// stream (e.g., `width == 0` pending deferred SPS completion), while ignoring attached
    /// pictures, `AV_CODEC_ID_NONE` broken tracks, and unflagged still-image cover tracks
    /// when a real video track exists.
    static func tolerantBestVideoStreamIndex(in ctx: UnsafeMutablePointer<AVFormatContext>) -> Int32 {
        let native = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        if native >= 0, native < Int32(ctx.pointee.nb_streams),
           let st = ctx.pointee.streams[Int(native)],
           let par = st.pointee.codecpar,
           !Demuxer.isAttachedPicture(disposition: st.pointee.disposition),
           par.pointee.codec_id != AV_CODEC_ID_NONE,
           !stillImageVideoCodecs.contains(par.pointee.codec_id) {
            return native
        }

        let nbStreams = Int(ctx.pointee.nb_streams)
        var resolvedCandidate: Int32 = -1
        var knownCodecCandidate: Int32 = -1
        var stillFallback: Int32 = -1

        for i in 0..<nbStreams {
            guard let st = ctx.pointee.streams[i],
                  let par = st.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                  !Demuxer.isAttachedPicture(disposition: st.pointee.disposition),
                  par.pointee.codec_id != AV_CODEC_ID_NONE else { continue }
            if stillImageVideoCodecs.contains(par.pointee.codec_id) {
                if stillFallback < 0 { stillFallback = Int32(i) }
                continue
            }
            if par.pointee.width > 0 && par.pointee.height > 0 {
                let isDefault = (st.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0
                if resolvedCandidate < 0 || isDefault {
                    resolvedCandidate = Int32(i)
                    if isDefault { break }
                }
            } else if knownCodecCandidate < 0 {
                knownCodecCandidate = Int32(i)
            }
        }

        if resolvedCandidate >= 0 { return resolvedCandidate }
        if knownCodecCandidate >= 0 { return knownCodecCandidate }
        if native >= 0 { return native }
        return stillFallback
    }

    /// Selects the best audio stream even when `av_find_best_stream` skips an audio stream
    /// whose `sample_rate` or `channels` was not yet resolved during a bounded probe.
    static func tolerantBestAudioStreamIndex(in ctx: UnsafeMutablePointer<AVFormatContext>) -> Int32 {
        let native = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if native >= 0, native < Int32(ctx.pointee.nb_streams),
           let st = ctx.pointee.streams[Int(native)],
           let par = st.pointee.codecpar,
           par.pointee.codec_id != AV_CODEC_ID_NONE {
            return native
        }

        let nbStreams = Int(ctx.pointee.nb_streams)
        var resolvedDecodable: Int32 = -1
        var decodableIncomplete: Int32 = -1
        var knownCodecFallback: Int32 = -1

        for i in 0..<nbStreams {
            guard let st = ctx.pointee.streams[i],
                  let par = st.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_AUDIO,
                  par.pointee.codec_id != AV_CODEC_ID_NONE else { continue }
            let hasDecoder = avcodec_find_decoder(par.pointee.codec_id) != nil
            let hasParams = par.pointee.sample_rate > 0 && par.pointee.ch_layout.nb_channels > 0
            if hasDecoder && hasParams {
                let isDefault = (st.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0
                if resolvedDecodable < 0 || isDefault {
                    resolvedDecodable = Int32(i)
                    if isDefault { break }
                }
            } else if hasDecoder && decodableIncomplete < 0 {
                decodableIncomplete = Int32(i)
            } else if knownCodecFallback < 0 {
                knownCodecFallback = Int32(i)
            }
        }

        if resolvedDecodable >= 0 { return resolvedDecodable }
        if decodableIncomplete >= 0 { return decodableIncomplete }
        return knownCodecFallback
    }

    // MARK: Server Hint Backfill

    static func codecID(forServerCodecName raw: String?) -> AVCodecID {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !name.isEmpty else { return AV_CODEC_ID_NONE }
        switch name {
        case "hevc", "h265", "h.265", "hev1", "hvc1": return AV_CODEC_ID_HEVC
        case "h264", "h.264", "avc", "avc1", "x264": return AV_CODEC_ID_H264
        case "av1", "av01": return AV_CODEC_ID_AV1
        case "vp9", "vp09": return AV_CODEC_ID_VP9
        case "vp8": return AV_CODEC_ID_VP8
        case "mpeg2video", "mpeg2": return AV_CODEC_ID_MPEG2VIDEO
        case "mpeg4", "mp4v", "xvid", "divx": return AV_CODEC_ID_MPEG4
        case "vc1", "wvc1": return AV_CODEC_ID_VC1
        case "aac", "mp4a", "aac_latm": return AV_CODEC_ID_AAC
        case "eac3", "ec3", "ec-3", "ddp", "dd+": return AV_CODEC_ID_EAC3
        case "ac3", "ac-3", "dd": return AV_CODEC_ID_AC3
        case "dts", "dca", "dts-hd", "dtshd": return AV_CODEC_ID_DTS
        case "truehd", "mlp": return AV_CODEC_ID_TRUEHD
        case "flac": return AV_CODEC_ID_FLAC
        case "mp3": return AV_CODEC_ID_MP3
        case "mp2": return AV_CODEC_ID_MP2
        case "opus": return AV_CODEC_ID_OPUS
        case "vorbis": return AV_CODEC_ID_VORBIS
        case "alac": return AV_CODEC_ID_ALAC
        case "pcm_s16le": return AV_CODEC_ID_PCM_S16LE
        case "pcm_s24le": return AV_CODEC_ID_PCM_S24LE
        case "pcm_s16be": return AV_CODEC_ID_PCM_S16BE
        case "pcm_s24be": return AV_CODEC_ID_PCM_S24BE
        case "pcm_f32le": return AV_CODEC_ID_PCM_F32LE
        case "subrip", "srt": return AV_CODEC_ID_SUBRIP
        case "ass": return AV_CODEC_ID_ASS
        case "ssa": return AV_CODEC_ID_SSA
        case "webvtt", "vtt": return AV_CODEC_ID_WEBVTT
        case "pgssub", "hdmv_pgs_subtitle", "pgs": return AV_CODEC_ID_HDMV_PGS_SUBTITLE
        case "dvdsub", "dvd_subtitle", "vobsub": return AV_CODEC_ID_DVD_SUBTITLE
        case "dvbsub", "dvb_subtitle": return AV_CODEC_ID_DVB_SUBTITLE
        case "mov_text", "tx3g": return AV_CODEC_ID_MOV_TEXT
        default: return AV_CODEC_ID_NONE
        }
    }

    static func rationalFrameRate(for fps: Double) -> AVRational? {
        guard fps.isFinite, fps > 1.0, fps < 240.0 else { return nil }
        let standards: [(Double, Int32, Int32)] = [
            (23.976, 24000, 1001),
            (24.0, 24, 1),
            (25.0, 25, 1),
            (29.97, 30000, 1001),
            (30.0, 30, 1),
            (48.0, 48, 1),
            (50.0, 50, 1),
            (59.94, 60000, 1001),
            (60.0, 60, 1),
            (120.0, 120, 1),
        ]
        for (target, num, den) in standards where abs(fps - target) < 0.06 {
            return AVRational(num: num, den: den)
        }
        return AVRational(num: Int32((fps * 1000).rounded()), den: 1000)
    }

    /// Backfills ONLY missing (`0` / `NONE` / unspecified) `AVCodecParameters` fields on open
    /// streams using upstream server `DemuxerMediaHints`. Never overwrites valid values parsed
    /// from the container or bitstream. Returns the count of streams enriched.
    @discardableResult
    static func backfillMissingParameters(
        in ctx: UnsafeMutablePointer<AVFormatContext>,
        from hints: DemuxerMediaHints
    ) -> Int {
        guard !hints.streams.isEmpty else { return 0 }
        let nbStreams = Int(ctx.pointee.nb_streams)
        guard nbStreams > 0 else { return 0 }

        var enrichedCount = 0
        var videoOrdinal = 0
        var audioOrdinal = 0
        var subtitleOrdinal = 0

        let videoHints = hints.streams.filter { $0.kind == .video }
        let audioHints = hints.streams.filter { $0.kind == .audio }
        let subtitleHints = hints.streams.filter { $0.kind == .subtitle }

        for i in 0..<nbStreams {
            guard let stream = ctx.pointee.streams[i],
                  let par = stream.pointee.codecpar,
                  !Demuxer.isAttachedPicture(disposition: stream.pointee.disposition) else { continue }

            let matchedHint: DemuxerStreamHint?
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                let exact = videoHints.first { $0.streamIndex == i }
                matchedHint = exact ?? (videoOrdinal < videoHints.count ? videoHints[videoOrdinal] : nil)
                videoOrdinal += 1
            case AVMEDIA_TYPE_AUDIO:
                let exact = audioHints.first { $0.streamIndex == i }
                matchedHint = exact ?? (audioOrdinal < audioHints.count ? audioHints[audioOrdinal] : nil)
                audioOrdinal += 1
            case AVMEDIA_TYPE_SUBTITLE:
                let exact = subtitleHints.first { $0.streamIndex == i }
                matchedHint = exact ?? (subtitleOrdinal < subtitleHints.count ? subtitleHints[subtitleOrdinal] : nil)
                subtitleOrdinal += 1
            case AVMEDIA_TYPE_UNKNOWN:
                matchedHint = hints.streams.first { $0.streamIndex == i }
            default:
                matchedHint = nil
            }

            guard let hint = matchedHint else { continue }
            var changed = false

            if par.pointee.codec_type == AVMEDIA_TYPE_UNKNOWN {
                switch hint.kind {
                case .video: par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
                case .audio: par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
                case .subtitle: par.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
                }
                changed = true
            }

            if par.pointee.codec_id == AV_CODEC_ID_NONE {
                let hintedID = codecID(forServerCodecName: hint.codecName)
                if hintedID != AV_CODEC_ID_NONE {
                    par.pointee.codec_id = hintedID
                    changed = true
                }
            }

            if par.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                if par.pointee.width <= 0, let w = hint.width, w > 0 {
                    par.pointee.width = w
                    changed = true
                }
                if par.pointee.height <= 0, let h = hint.height, h > 0 {
                    par.pointee.height = h
                    changed = true
                }
                if stream.pointee.avg_frame_rate.num <= 0,
                   stream.pointee.r_frame_rate.num <= 0,
                   let fps = hint.frameRate,
                   let rational = rationalFrameRate(for: fps) {
                    stream.pointee.avg_frame_rate = rational
                    changed = true
                }
                if par.pointee.color_trc == AVCOL_TRC_UNSPECIFIED,
                   let trc = hint.colorTransfer?.lowercased() {
                    if trc.contains("2084") || trc.contains("pq") {
                        par.pointee.color_trc = AVCOL_TRC_SMPTE2084
                        changed = true
                    } else if trc.contains("b67") || trc.contains("hlg") {
                        par.pointee.color_trc = AVCOL_TRC_ARIB_STD_B67
                        changed = true
                    } else if trc.contains("709") {
                        par.pointee.color_trc = AVCOL_TRC_BT709
                        changed = true
                    }
                }
                if par.pointee.color_primaries == AVCOL_PRI_UNSPECIFIED,
                   let pri = hint.colorPrimaries?.lowercased() {
                    if pri.contains("2020") {
                        par.pointee.color_primaries = AVCOL_PRI_BT2020
                        changed = true
                    } else if pri.contains("709") {
                        par.pointee.color_primaries = AVCOL_PRI_BT709
                        changed = true
                    } else if pri.contains("432") || pri.contains("p3") {
                        par.pointee.color_primaries = AVCOL_PRI_SMPTE432
                        changed = true
                    }
                }
                if par.pointee.color_space == AVCOL_SPC_UNSPECIFIED,
                   let spc = hint.colorSpace?.lowercased() {
                    if spc.contains("2020") {
                        par.pointee.color_space = AVCOL_SPC_BT2020_NCL
                        changed = true
                    } else if spc.contains("709") {
                        par.pointee.color_space = AVCOL_SPC_BT709
                        changed = true
                    }
                }
            } else if par.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                if par.pointee.sample_rate <= 0, let sr = hint.sampleRate, sr > 0 {
                    par.pointee.sample_rate = sr
                    changed = true
                }
                if par.pointee.ch_layout.nb_channels <= 0, let ch = hint.channels, ch > 0, ch <= 16 {
                    av_channel_layout_default(&par.pointee.ch_layout, ch)
                    changed = true
                }
            }

            if par.pointee.bit_rate <= 0, let br = hint.bitrate, br > 0 {
                par.pointee.bit_rate = br
                changed = true
            }
            if let lang = hint.language?.trimmingCharacters(in: .whitespacesAndNewlines),
               !lang.isEmpty, lang.lowercased() != "und",
               av_dict_get(stream.pointee.metadata, "language", nil, 0) == nil {
                av_dict_set(&stream.pointee.metadata, "language", lang, 0)
                changed = true
            }

            if changed {
                enrichedCount += 1
            }
        }
        return enrichedCount
    }

    /// Identifies audio/video streams whose `codecpar` still lacks essential fields after probing
    /// and therefore benefit from deferred in-band packet parameter completion.
    static func streamsNeedingDeferredCompletion(in ctx: UnsafeMutablePointer<AVFormatContext>) -> Set<Int32> {
        let nbStreams = Int(ctx.pointee.nb_streams)
        var pending: Set<Int32> = []
        for i in 0..<nbStreams {
            guard let stream = ctx.pointee.streams[i],
                  let par = stream.pointee.codecpar,
                  !Demuxer.isAttachedPicture(disposition: stream.pointee.disposition) else { continue }
            let p = par.pointee
            switch p.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                guard p.codec_id != AV_CODEC_ID_NONE, !stillImageVideoCodecs.contains(p.codec_id) else { continue }
                let missingDims = p.width <= 0 || p.height <= 0
                let missingConfig = (p.codec_id == AV_CODEC_ID_H264 || p.codec_id == AV_CODEC_ID_HEVC)
                    && (p.extradata == nil || p.extradata_size <= 0)
                if missingDims || missingConfig {
                    pending.insert(Int32(i))
                }
            case AVMEDIA_TYPE_AUDIO:
                guard p.codec_id != AV_CODEC_ID_NONE else { continue }
                if p.sample_rate <= 0 || p.ch_layout.nb_channels <= 0 {
                    pending.insert(Int32(i))
                }
            default:
                break
            }
        }
        return pending
    }

    // MARK: Deferred In-Band Bitstream Parameter Extraction

    struct ExtractedVideoParams: Equatable, Sendable {
        let width: Int32
        let height: Int32
        let annexBExtradata: [UInt8]?
    }

    struct ExtractedAudioParams: Equatable, Sendable {
        let sampleRate: Int32
        let channels: Int32
        let profile: Int32?
    }

    /// Extracts width/height and optional Annex-B SPS/PPS (H.264) or VPS/SPS/PPS (HEVC) from
    /// an arriving compressed packet, supporting both Annex-B start codes and 4-byte length prefixes.
    static func extractVideoParams(
        codecID: AVCodecID,
        packetData: UnsafePointer<UInt8>,
        size: Int
    ) -> ExtractedVideoParams? {
        guard size > 4 else { return nil }
        let buf = UnsafeBufferPointer(start: packetData, count: size)
        switch codecID {
        case AV_CODEC_ID_H264:
            if let extracted = H264SPS.extractSPSandPPS(fromAnnexB: buf),
               let dims = H264SPS.dimensions(fromNAL: extracted.sps),
               dims.width > 0, dims.height > 0 {
                let extra = H264SPS.annexBExtradata(sps: extracted.sps, pps: extracted.pps)
                return ExtractedVideoParams(width: Int32(dims.width), height: Int32(dims.height), annexBExtradata: extra)
            }
            var lp = VideoConfigRecord.H264ParameterSets()
            lp.collect(from: packetData, size: size, naluLengthSize: 4)
            if let sps = lp.sps, let dims = H264SPS.dimensions(fromNAL: sps), dims.width > 0, dims.height > 0 {
                let extra = lp.pps.map { H264SPS.annexBExtradata(sps: sps, pps: $0) }
                return ExtractedVideoParams(width: Int32(dims.width), height: Int32(dims.height), annexBExtradata: extra)
            }
            return nil

        case AV_CODEC_ID_HEVC:
            let rawBuf = UnsafeRawBufferPointer(buf)
            let ranges = AnnexB.nalRanges(rawBuf)
            var vps: [UInt8]?
            var sps: [UInt8]?
            var pps: [UInt8]?
            if !ranges.isEmpty {
                for r in ranges where !r.isEmpty {
                    let nalType = (Int(buf[r.lowerBound]) >> 1) & 0x3F
                    switch nalType {
                    case 32 where vps == nil: vps = Array(buf[r])
                    case 33 where sps == nil: sps = Array(buf[r])
                    case 34 where pps == nil: pps = Array(buf[r])
                    default: break
                    }
                }
            }
            if sps == nil {
                var lp = VideoConfigRecord.HEVCParameterSets()
                lp.collect(from: packetData, size: size, naluLengthSize: 4)
                vps = vps ?? lp.vps
                sps = lp.sps
                pps = pps ?? lp.pps
            }
            guard let sps, let dims = parseHEVCSPSDimensions(fromNAL: sps), dims.width > 0, dims.height > 0 else {
                return nil
            }
            var annexB: [UInt8]? = nil
            if let vps, let pps {
                var out: [UInt8] = []
                out.reserveCapacity(12 + vps.count + sps.count + pps.count)
                for nal in [vps, sps, pps] {
                    out.append(contentsOf: [0, 0, 0, 1])
                    out.append(contentsOf: nal)
                }
                annexB = out
            }
            return ExtractedVideoParams(width: Int32(dims.width), height: Int32(dims.height), annexBExtradata: annexB)

        default:
            return nil
        }
    }

    /// Parses cropped luma dimensions from a raw HEVC SPS NAL (2-byte NAL header included).
    static func parseHEVCSPSDimensions(fromNAL nal: [UInt8]) -> (width: Int, height: Int)? {
        guard nal.count > 16 else { return nil }
        let nalType = (Int(nal[0]) >> 1) & 0x3F
        guard nalType == 33 else { return nil }
        let rbsp = A53SEIParser.unescapeRBSP(Array(nal[2...]))
        var r = H264SPS.BitReader(rbsp)

        // sps_video_parameter_set_id(4), sps_max_sub_layers_minus1(3), sps_temporal_id_nesting_flag(1)
        guard r.skip(4), let maxSubLayersMinus1 = r.u(3), r.skip(1) else { return nil }
        // profile_tier_level(1, maxSubLayersMinus1): 88 bits general profile + 8 bits general_level_idc
        guard r.skip(96) else { return nil }
        if maxSubLayersMinus1 > 0 {
            var subProfilePresent: [Bool] = []
            var subLevelPresent: [Bool] = []
            for _ in 0..<maxSubLayersMinus1 {
                guard let p = r.u(1), let l = r.u(1) else { return nil }
                subProfilePresent.append(p == 1)
                subLevelPresent.append(l == 1)
            }
            if maxSubLayersMinus1 < 8 {
                guard r.skip(2 * (8 - maxSubLayersMinus1)) else { return nil }
            }
            for i in 0..<maxSubLayersMinus1 {
                if subProfilePresent[i], !r.skip(88) { return nil }
                if subLevelPresent[i], !r.skip(8) { return nil }
            }
        }
        guard r.ue() != nil, let chromaFormatIdc = r.ue() else { return nil }
        if chromaFormatIdc == 3 {
            guard r.skip(1) else { return nil } // separate_colour_plane_flag
        }
        guard let picWidth = r.ue(), let picHeight = r.ue(),
              picWidth > 0, picHeight > 0,
              picWidth <= H264SPS.maxDimension, picHeight <= H264SPS.maxDimension else { return nil }

        var width = picWidth
        var height = picHeight
        if r.u(1) == 1 {
            guard let left = r.ue(), let right = r.ue(), let top = r.ue(), let bottom = r.ue() else {
                return nil
            }
            let subWidthC = (chromaFormatIdc == 1 || chromaFormatIdc == 2) ? 2 : 1
            let subHeightC = (chromaFormatIdc == 1) ? 2 : 1
            let croppedW = picWidth - subWidthC * (left + right)
            let croppedH = picHeight - subHeightC * (top + bottom)
            if croppedW > 0, croppedH > 0 {
                width = croppedW
                height = croppedH
            }
        }
        return (width, height)
    }

    /// Parses sample rate & channel count from an AAC ADTS syncframe or AC-3/E-AC-3 syncframe.
    static func extractAudioParams(
        codecID: AVCodecID,
        packetData: UnsafePointer<UInt8>,
        size: Int
    ) -> ExtractedAudioParams? {
        switch codecID {
        case AV_CODEC_ID_AAC:
            guard size >= 7, packetData[0] == 0xFF, (packetData[1] & 0xF0) == 0xF0 else { return nil }
            let profileMinus1 = Int((packetData[2] >> 6) & 0x03)
            let srIndex = Int((packetData[2] >> 2) & 0x0F)
            let chConfig = Int(((packetData[2] & 0x01) << 2) | ((packetData[3] >> 6) & 0x03))
            let srTable: [Int32] = [
                96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                16000, 12000, 11025, 8000, 7350
            ]
            guard srIndex < srTable.count else { return nil }
            let channels: Int32 = switch chConfig {
            case 1...6: Int32(chConfig)
            case 7: 8
            default: 2
            }
            return ExtractedAudioParams(
                sampleRate: srTable[srIndex],
                channels: channels,
                profile: Int32(profileMinus1)
            )

        case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3:
            guard size >= 7, packetData[0] == 0x0B, packetData[1] == 0x77 else { return nil }
            let bsid = Int((packetData[5] >> 3) & 0x1F)
            let srTable: [Int32] = [48000, 44100, 32000]
            let acmodChannels: [Int32] = [2, 1, 2, 3, 3, 4, 4, 5]
            if bsid > 10 {
                // E-AC-3 (bsid 11..16): byte 4 bits 7..6 = fscod, bits 5..4 = fscod2, bits 3..1 = acmod, bit 0 = lfeon
                let fscod = Int((packetData[4] >> 6) & 0x03)
                let fscod2 = Int((packetData[4] >> 4) & 0x03)
                let acmod = Int((packetData[4] >> 1) & 0x07)
                let lfeon: Int32 = (packetData[4] & 0x01) != 0 ? 1 : 0
                let sampleRate: Int32
                if fscod < 3 {
                    sampleRate = srTable[fscod]
                } else if fscod2 < 3 {
                    sampleRate = srTable[fscod2] / 2
                } else {
                    return nil
                }
                return ExtractedAudioParams(sampleRate: sampleRate, channels: acmodChannels[acmod] + lfeon, profile: nil)
            } else {
                // Classic AC-3 (bsid <= 10): byte 4 bits 7..6 = fscod; byte 6 bits 7..5 = acmod
                let fscod = Int((packetData[4] >> 6) & 0x03)
                guard fscod < 3 else { return nil }
                let acmod = Int((packetData[6] >> 5) & 0x07)
                // Approximate lfeon without parsing cmixlev/surmixlev/dsurmod: at least base channels
                return ExtractedAudioParams(sampleRate: srTable[fscod], channels: acmodChannels[acmod], profile: nil)
            }

        default:
            return nil
        }
    }

    /// Attempts to complete missing `codecpar` fields on `stream` from a single arriving packet.
    /// Returns true if `codecpar` was updated.
    @discardableResult
    static func applyDeferredPacketParameters(
        packet: UnsafeMutablePointer<AVPacket>,
        to stream: UnsafeMutablePointer<AVStream>
    ) -> Bool {
        guard let par = stream.pointee.codecpar,
              let data = packet.pointee.data,
              packet.pointee.size > 0 else { return false }
        let size = Int(packet.pointee.size)

        switch par.pointee.codec_type {
        case AVMEDIA_TYPE_VIDEO:
            guard let extracted = extractVideoParams(
                codecID: par.pointee.codec_id,
                packetData: data,
                size: size
            ) else { return false }
            var changed = false
            if par.pointee.width <= 0 || par.pointee.height <= 0 {
                par.pointee.width = extracted.width
                par.pointee.height = extracted.height
                changed = true
            }
            if (par.pointee.extradata == nil || par.pointee.extradata_size <= 0),
               let extra = extracted.annexBExtradata, !extra.isEmpty {
                if Demuxer.replaceExtradata(of: par, with: extra) {
                    changed = true
                }
            }
            return changed

        case AVMEDIA_TYPE_AUDIO:
            guard par.pointee.sample_rate <= 0 || par.pointee.ch_layout.nb_channels <= 0,
                  let extracted = extractAudioParams(
                      codecID: par.pointee.codec_id,
                      packetData: data,
                      size: size
                  ) else { return false }
            var changed = false
            if par.pointee.sample_rate <= 0 {
                par.pointee.sample_rate = extracted.sampleRate
                changed = true
            }
            if par.pointee.ch_layout.nb_channels <= 0 {
                av_channel_layout_default(&par.pointee.ch_layout, extracted.channels)
                changed = true
            }
            if let profile = extracted.profile, par.pointee.profile < 0 {
                par.pointee.profile = profile
                changed = true
            }
            return changed

        default:
            return false
        }
    }
}

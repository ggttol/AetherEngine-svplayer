// SVPlayer modification (2026-11-21): Support downscaled .preview mode in boundedSnapshot for 4K scrub refinement.
import Foundation
import CoreGraphics

/// A bounded one-shot still. nil PTS means the source supplied no timestamp;
/// callers must label the requested time rather than claim a measured one.
// CGImage is immutable; all other stored properties are immutable Sendable values.
public struct BoundedStillFrame: @unchecked Sendable {
    public let image: CGImage
    public let actualSeconds: Double?
    public init(image: CGImage, actualSeconds: Double?) {
        self.image = image; self.actualSeconds = actualSeconds
    }
}

/// Produces still images from a media URL via an isolated FFmpeg decode context,
/// separate from playback. Three modes share one decode core: `snapshot` (frame-accurate,
/// full-res), `preview` (frame-accurate, downscaled) and `thumbnail` (keyframe-snapped, fast). Lazy: context opens on
/// first use; blocking FFmpeg work runs on a dedicated serial queue, not the cooperative pool.
/// Create one per URL; for the playing item prefer `AetherEngine.makeFrameExtractor()`.
public actor FrameExtractor {
    private let context: FrameDecodeContext
    private let cache: FrameCache
    private let decodeQueue: DispatchQueue
    /// #93 startup: session-coupled extractors yield elective thumbnail/preview decodes while the
    /// playback pipeline is starved (see `shouldYield`). nil = never yield (standalone use).
    private let yieldWhile: (@Sendable () -> Bool)?

    /// Cancellation flag for the in-flight decode; a new request flips the previous
    /// token so a superseded scrub decode bails promptly.
    private final class CancelToken: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _cancelled
        }
        func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    }
    private var currentToken: CancelToken?
    private var boundedCancellation: ProbeCancellation?

    /// Set by `shutdown()`. Once true, the extractor refuses further
    /// work instead of lazily reopening a closed context.
    private var isShutDown = false

    private var idleInterval: Duration
    /// Resident extractors close sooner: a scrub moves on within seconds, and each open 4K decoder
    /// holds 100 to 160 MB (AE#1059). `releaseDecoder()` is the faster path the engine takes.
    nonisolated static let residentIdleInterval: Duration = .seconds(3)
    /// Coded pixel area of the decoder as of the last finished queue job, 0 while closed. Read by
    /// the engine's scrub decoder budget.
    private(set) var openDecoderPixelArea = 0
    /// The area the source decoded at the last time it was open, kept across a close so the budget
    /// can count a decoder before it reopens.
    private(set) var knownDecoderPixelArea = 0
    /// Queue jobs submitted but not yet reported back. While one runs the decoder may be opening,
    /// and `openDecoderPixelArea` cannot say so yet.
    private(set) var queueJobsInFlight = 0
    /// Stamped on the queue, so a report that reenters the actor late never overwrites a newer one.
    private final class QueueStamp: @unchecked Sendable { var value = 0 }
    private let queueStamp = QueueStamp()
    private var lastReportedStamp = 0
    /// What the scrub decoder budget counts for this extractor: the open area, or the last known
    /// one while a queue job may be opening the decoder. 0 when nothing is or may be open.
    var budgetedDecoderPixelArea: Int {
        queueJobsInFlight > 0 ? max(openDecoderPixelArea, knownDecoderPixelArea) : openDecoderPixelArea
    }
    var decoderMayBeOpen: Bool { openDecoderPixelArea > 0 || queueJobsInFlight > 0 }

    /// Counts this extractor's decoder as possibly open from the moment a caller decides to decode,
    /// before the job reaches the queue. Without it two concurrent budget passes each see the other's
    /// incoming decoder as closed and both open it (AE#1059). Paired with `endDecodeReservation()`.
    func reserveDecode() { queueJobsInFlight += 1 }
    func endDecodeReservation() { queueJobsInFlight -= 1 }
    private var idleTask: Task<Void, Never>?
    private var residentApproximation: (width: Int, frame: ScrubFrame)?
    nonisolated let residentIdentity: String?
    func clearResidentPreviewCache() {
        currentToken?.cancel()
        residentApproximation = nil
    }

    /// Closes the decoder and demuxer but keeps the cached stills, so a repeat request for this
    /// segment still answers without a decode. The next decode reopens lazily. Queued behind any
    /// decode in flight, which therefore finishes first.
    func releaseDecoder() async {
        guard !isShutDown, decoderMayBeOpen else { return }
        idleTask?.cancel()
        idleTask = nil
        let context = self.context
        await runOnQueue { context.close() }
    }

    /// Only used with a one-segment DataIOReader. No URL or provider fallback.
    /// Refined results bypass the rendered-frame cache so they carry the actual decoded PTS.
    func residentPreview(rawTarget: Double, refined: Bool, maxWidth: Int,
                                isCancelled: @escaping @Sendable () -> Bool) async -> ScrubFrame? {
        guard !isShutDown, rawTarget.isFinite,
              !Task.isCancelled, !isCancelled() else { return nil }
        guard maxWidth > 0 else { return nil }
        // A cached approximation is still the latest scrub intent; retire an older refinement
        // before returning it, using the same cross-mode ownership rule as ordinary stills.
        currentToken?.cancel()
        boundedCancellation?.cancel()
        let token = CancelToken(); currentToken = token
        defer {
            if !isShutDown, currentToken === token { scheduleIdleClose() }
        }
        let width = maxWidth
        if !refined, let cached = residentApproximation, cached.width == width {
            return cached.frame
        }
        let context = self.context
        let result: ScrubFrame? = await withTaskCancellationHandler {
            await runOnQueue {
                guard !token.isCancelled, !isCancelled() else { return nil }
                do { try context.ensureOpen() } catch { return nil }
                var actual: Double?
                var didRefine = false
                let image = context.decodeFrame(at: 0, mode: refined ? .snapshot : .thumbnail,
                    targetWidth: width, maxSize: CGSize(width: CGFloat(width), height: CGFloat(width)),
                    isCancelled: { token.isCancelled || isCancelled() }, residentTarget: rawTarget,
                    reportResidentTime: { actual = $0; didRefine = $1 })
                guard let image, let actual, !token.isCancelled, !isCancelled() else { return nil }
                return ScrubFrame(image: image, actualSeconds: actual, refined: didRefine)
            }
        } onCancel: { token.cancel() }
        guard !Task.isCancelled, !isCancelled(), !token.isCancelled else { return nil }
        if !refined, let result, result.image.bytesPerRow * result.image.height <= 512 * 1_024 {
            residentApproximation = (width, result)
        }
        return result
    }

    private init(context: FrameDecodeContext, yieldWhile: (@Sendable () -> Bool)?, residentIdentity: String? = nil,
                 idleInterval: Duration = .seconds(10)) {
        self.context = context
        self.idleInterval = idleInterval
        self.residentIdentity = residentIdentity
        self.yieldWhile = yieldWhile
        self.cache = FrameCache(
            thumbnailLimit: 24,
            snapshotLimit: 2,
            thumbnailBucketSeconds: 1.0
        )
        // Still extraction is elective work and must yield to playback under CPU contention.
        self.decodeQueue = DispatchQueue(label: "com.aetherengine.frameextractor", qos: .utility)
    }

    /// `selectTitleID` picks the disc title for a Blu-ray / DVD ISO URL (nil = main title); it lets a
    /// still follow the currently-selected title instead of always the default one (AE#105). Inert for
    /// non-disc URLs.
    public init(url: URL, httpHeaders: [String: String] = [:],
                selectTitleID: Int? = nil,
                yieldWhile: (@Sendable () -> Bool)? = nil) {
        self.init(context: FrameDecodeContext(url: url, httpHeaders: httpHeaders, selectTitleID: selectTitleID),
                  yieldWhile: yieldWhile)
    }

    /// AE#792: an extractor over the session's own source, whose requests follow
    /// `updateRequestHeaders(_:)` like the session's other readers.
    init(url: URL, requestHeaderStore: RequestHeaderStore, selectTitleID: Int?,
         yieldWhile: (@Sendable () -> Bool)?) {
        self.init(context: FrameDecodeContext(url: url, httpHeaders: requestHeaderStore.current,
                                              selectTitleID: selectTitleID,
                                              requestHeaderStore: requestHeaderStore),
                  yieldWhile: yieldWhile)
    }

    /// Construct over a custom `IOReader` source (a clone with its own cursor).
    /// The extractor owns the reader and closes it on teardown.
    public init(reader: IOReader, formatHint: String? = nil,
                yieldWhile: (@Sendable () -> Bool)? = nil) {
        self.init(context: FrameDecodeContext(reader: reader, formatHint: formatHint),
                  yieldWhile: yieldWhile)
    }

    init(residentReader: IOReader, formatHint: String, identity: String,
         residentBudget: Duration = .milliseconds(750)) {
        self.init(context: FrameDecodeContext(reader: residentReader, formatHint: formatHint,
                                              residentBudget: residentBudget),
                  yieldWhile: nil, residentIdentity: identity, idleInterval: Self.residentIdleInterval)
    }

    /// Yield decision for elective thumbnail/preview extraction. The disposable decode's demuxer pulls
    /// megabytes over the same link the segment producer needs; during startup and recovery that
    /// contention tipped the first segment past CoreMedia's ~4 s media timeout and killed the
    /// AVPlayer loader (-15628, #93 startup). Yield while a producer restart is in flight or the
    /// consumer's forward buffer has not stayed healthy long enough: a SINGLE 1 Hz tick above
    /// the floor (post-load seek shapes buffer spikes) let a 3.3 MB warm pull through the exact
    /// startup window that killed the loader, so the gate opens only after several consecutive
    /// healthy ticks. Unknown (nil) buffer resets the run, covering the cold startup window.
    public nonisolated static let yieldMinForwardBufferSeconds: Double = 3.0
    public nonisolated static let yieldHealthyTicksRequired = 3
    public nonisolated static func shouldYield(
        restartInFlight: Bool, consecutiveHealthyTicks: Int
    ) -> Bool {
        restartInFlight || consecutiveHealthyTicks < yieldHealthyTicksRequired
    }

    // MARK: - Public API

    public func thumbnail(at seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        await produce(at: seconds, mode: .thumbnail, targetWidth: maxWidth, maxSize: nil)
    }

    /// Produce a frame-accurate, downscaled still for interactive scrubbing.
    /// Like thumbnails, uncached previews yield while the playback pipeline is starved.
    public func preview(at seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        await produce(at: seconds, mode: .preview, targetWidth: maxWidth, maxSize: nil)
    }

    public func snapshot(at seconds: Double, maxSize: CGSize? = nil) async -> CGImage? {
        // targetWidth is inert for snapshot; FrameDecodeContext.clampedWidth governs size.
        await produce(at: seconds, mode: .snapshot, targetWidth: 0, maxSize: maxSize)
    }

    /// AE#711 follow-up: the frame `offset` seconds after the first one this source decodes, for a
    /// one-segment cache source whose timestamps may sit on either axis. Frame-accurate like
    /// `snapshot`, uncached (the cache keys on stream time), and with the same Dolby Vision and HDR
    /// conversion as every still.
    func snapshot(afterFirstFrameBy offset: Double, maxSize: CGSize? = nil) async -> CGImage? {
        guard !isShutDown, offset.isFinite else { return nil }
        let context = self.context
        let image = await runOnQueue { () -> CGImage? in
            do { try context.ensureOpen() } catch {
                EngineLog.emit("[FrameExtractor] open failed: \(error)", category: .swPlayback)
                return nil
            }
            return context.decodeFrame(at: 0, mode: .snapshot, targetWidth: 0, maxSize: maxSize,
                                       afterFirstFrame: offset, isCancelled: { false })
        }
        scheduleIdleClose()
        return image
    }

    /// A still for a scrub preview over a local file, with the contract of `scrubPreviewFrame`: the
    /// caller's `isCancelled` is polled through the decode, the decode stops at the same 750 ms /
    /// 900 packet bound a resident one does, and the time of the frame actually decoded comes back
    /// (nil when the source stamps none) so the caller can label the picture rather than the request.
    /// Uncached, because a cache hit would not carry that time. `refined` decodes to the target;
    /// otherwise the first frame after the seek is returned, at `maxWidth`.
    func boundedLocalStill(at seconds: Double, refined: Bool, maxWidth: Int,
                           isCancelled: @escaping @Sendable () -> Bool) async -> (image: CGImage, decodedSeconds: Double?)? {
        guard !isShutDown, seconds.isFinite, seconds >= 0 else { return nil }
        currentToken?.cancel()
        let token = CancelToken()
        currentToken = token
        let context = self.context
        let mode: FrameMode = refined ? .snapshot : .thumbnail
        let size = CGSize(width: maxWidth, height: maxWidth)
        let result = await runOnQueue { () -> (image: CGImage, decodedSeconds: Double?)? in
            if token.isCancelled || isCancelled() { return nil }
            do { try context.ensureOpen() } catch {
                EngineLog.emit("[FrameExtractor] open failed: \(error)", category: .swPlayback)
                return nil
            }
            var decoded: Double?
            guard let image = context.decodeFrame(
                at: seconds, mode: mode, targetWidth: maxWidth, maxSize: refined ? size : nil,
                isCancelled: { token.isCancelled || isCancelled() },
                reportDecodedTime: { decoded = $0 }, bounded: true),
                !token.isCancelled, !isCancelled() else { return nil }
            return (image, decoded)
        }
        scheduleIdleClose()
        return result
    }

    /// Disposable source-backed preview with one budget spanning open, stream
    /// analysis, seek and decode. The controlled reader counts every input byte,
    /// the monotonic deadline interrupts I/O, and a late result is discarded.
    /// Unlike snapshot(), this never uses a previously opened or cached context.
    // SVPlayer modification (2026-11-21): Allow callers to request downscaled .preview mode in boundedSnapshot.
    public func boundedSnapshot(at seconds: Double, maxSize: CGSize,
                                limits: ProbeLimits, cancellation: ProbeCancellation,
                                mode: FrameMode = .snapshot) async -> BoundedStillFrame? {
        guard !isShutDown, seconds.isFinite, !Task.isCancelled, !cancellation.isCancelled,
              let control = try? ProbeControl(limits: limits, cancellation: cancellation) else { return nil }
        currentToken?.cancel()
        boundedCancellation?.cancel()
        boundedCancellation = cancellation
        let token = CancelToken(); currentToken = token
        let context = self.context
        // SVPlayer modification (2026-11-21): Honour .preview targetWidth so 4K scrub refinement
        // avoids full-frame bicubic/loop-filter passes and oversized intermediate buffers.
        let targetWidth = mode.usesTargetWidth ? max(1, Int(maxSize.width.rounded(.down))) : 0
        let result = await withTaskCancellationHandler {
            await runOnQueue { () -> BoundedStillFrame? in
                // A previously opened demuxer was outside this budget. Reject
                // it instead of letting its teardown extend this one-shot work.
                guard !context.isOpen else { control.finish(); return nil }
                defer { context.close(); control.finish() }
                guard !token.isCancelled, !cancellation.isCancelled else { return nil }
                do { try context.ensureOpen(control: control) } catch { return nil }
                var actual: Double?
                // SVPlayer modification (2026-11-21): Forward caller FrameMode and bounded targetWidth to decodeFrame.
                guard let image = context.decodeFrame(at: seconds, mode: mode,
                    targetWidth: targetWidth, maxSize: maxSize,
                    isCancelled: { token.isCancelled || cancellation.isCancelled || control.isStopped },
                    reportDecodedTime: { actual = $0 }),
                    !token.isCancelled, !cancellation.isCancelled else { return nil }
                do { try control.complete() } catch { return nil }
                return BoundedStillFrame(image: image, actualSeconds: actual)
            }
        } onCancel: {
            token.cancel()
            cancellation.cancel()
        }
        if boundedCancellation === cancellation { boundedCancellation = nil }
        return !Task.isCancelled && !cancellation.isCancelled && !token.isCancelled ? result : nil
    }

    // SVPlayer modification (2026-11-25): smart keyframe seek offset strategy for
    // directory video thumbnails — prefers ~10% or 60–120s over 0.0s to avoid opening
    // black fade-ins / broken open-GOP leading frames, falling back to 0.0s.
    public nonisolated static func candidateThumbnailOffsets(durationSeconds: Double?) -> [Double] {
        guard let duration = durationSeconds, duration.isFinite, duration > 0 else {
            return [10.0, 0.0]
        }
        if duration >= 600.0 {
            let primary = min(120.0, max(60.0, (duration * 0.10).rounded()))
            let secondary = min(30.0, max(10.0, (duration * 0.05).rounded()))
            return deduplicatedOffsets([primary, secondary, 0.0])
        }
        if duration >= 20.0 {
            let primary = max(2.0, min(60.0, (duration * 0.10).rounded()))
            return deduplicatedOffsets([primary, 0.0])
        }
        if duration >= 2.0 {
            let primary = min(max(1.0, duration * 0.15), max(0.5, duration - 0.5))
            return deduplicatedOffsets([primary, 0.0])
        }
        return [0.0]
    }

    private nonisolated static func deduplicatedOffsets(_ raw: [Double]) -> [Double] {
        var result: [Double] = []
        for value in raw where value.isFinite && value >= 0 {
            if !result.contains(where: { abs($0 - value) < 0.25 }) {
                result.append(value)
            }
        }
        return result.isEmpty ? [0.0] : result
    }

    // SVPlayer modification (2026-11-25): directory-thumbnail extraction with a single
    // open demuxer/decoder, LAN-friendly 512 KiB HTTP chunking + configurable chunk timeout,
    // smart multi-target seeking (skipping opening black frames), DV P5 IPT-PQ -> SDR
    // fallback, and full redacted diagnostics.
    public func extractThumbnailWithDiagnostics(
        candidateOffsets: [Double]? = nil,
        maxSize: CGSize,
        limits: ProbeLimits,
        cancellation: ProbeCancellation,
        chunkSize: Int = 512 * 1024,
        chunkRequestTimeout: TimeInterval = 6.0
    ) async -> ThumbnailExtractionOutcome {
        guard !isShutDown else {
            return ThumbnailExtractionOutcome(
                image: nil,
                diagnostics: ThumbnailExtractionDiagnostics(failureStage: "extractor_shutdown")
            )
        }
        guard !Task.isCancelled, !cancellation.isCancelled else {
            return ThumbnailExtractionOutcome(
                image: nil,
                diagnostics: ThumbnailExtractionDiagnostics(failureStage: "cancelled")
            )
        }
        guard let control = try? ProbeControl(limits: limits, cancellation: cancellation) else {
            return ThumbnailExtractionOutcome(
                image: nil,
                diagnostics: ThumbnailExtractionDiagnostics(failureStage: "invalid_limits")
            )
        }

        currentToken?.cancel()
        boundedCancellation?.cancel()
        boundedCancellation = cancellation
        let token = CancelToken()
        currentToken = token
        let context = self.context
        let targetWidth = max(64, Int(maxSize.width.rounded(.down)))

        let outcome: ThumbnailExtractionOutcome = await withTaskCancellationHandler {
            await runOnQueue { () -> ThumbnailExtractionOutcome in
                guard !context.isOpen else {
                    control.finish()
                    return ThumbnailExtractionOutcome(
                        image: nil,
                        diagnostics: ThumbnailExtractionDiagnostics(failureStage: "context_already_open")
                    )
                }
                defer {
                    context.close()
                    control.finish()
                }
                guard !token.isCancelled, !cancellation.isCancelled else {
                    return ThumbnailExtractionOutcome(
                        image: nil,
                        diagnostics: ThumbnailExtractionDiagnostics(failureStage: "cancelled")
                    )
                }

                func makeDiagnostics(
                    seekSeconds: Double,
                    actualSeconds: Double?,
                    failureStage: String?,
                    detail: String? = nil
                ) -> ThumbnailExtractionDiagnostics {
                    var resolvedStage = failureStage
                    let resolvedDetail = detail
                    if let stopError = control.recordedFailure {
                        switch stopError {
                        case is CancellationError:
                            resolvedStage = "cancelled"
                        case ProbeError.timedOut:
                            resolvedStage = "budget_timeout"
                        case ProbeError.inputLimit:
                            resolvedStage = "budget_input_limit"
                        case ProbeError.packetLimit:
                            resolvedStage = "budget_packet_limit"
                        case ProbeError.packetSizeLimit:
                            resolvedStage = "budget_packet_size"
                        default:
                            if resolvedStage == nil { resolvedStage = "probe_stopped" }
                        }
                    }
                    return ThumbnailExtractionDiagnostics(
                        container: context.containerName,
                        codec: context.codecName,
                        profile: context.profileName,
                        bitDepth: context.bitDepth,
                        hdrType: context.hdrType,
                        dvProfile: context.dvProfile,
                        durationSeconds: context.openDurationSeconds,
                        seekSeconds: seekSeconds,
                        actualSeconds: actualSeconds,
                        bytesRead: max(control.consumedInputBytes, context.bytesFetched),
                        packetsRead: control.consumedPacketCount,
                        colorPath: context.lastColorPath,
                        failureStage: resolvedStage,
                        ffmpegErrorCode: context.lastFFmpegErrorCode,
                        detail: resolvedDetail
                    )
                }

                do {
                    try context.ensureOpen(
                        control: control,
                        chunkSize: chunkSize,
                        chunkRequestTimeout: chunkRequestTimeout,
                        chunkMaxRetries: 2,
                        boundedWindowBytes: chunkSize
                    )
                } catch {
                    let stage = context.lastDecodeFailureStage ?? "open_failed"
                    return ThumbnailExtractionOutcome(
                        image: nil,
                        diagnostics: makeDiagnostics(
                            seekSeconds: 0,
                            actualSeconds: nil,
                            failureStage: stage,
                            detail: String(describing: type(of: error))
                        )
                    )
                }

                // SVPlayer modification (2026-11-25): do not decode or color-convert
                // Dolby Vision Profile 5/20/10.0 (no base layer) when the optional
                // DolbyVisionStillReshaping trait is disabled; report dv_p5_unsupported
                // immediately so directory cards fall back to official thumbnails or placeholder.
                if !FrameDecodeContext.yieldsStill(dolbyVisionNoBaseLayer: context.isDolbyVisionNoBaseLayer) {
                    return ThumbnailExtractionOutcome(
                        image: nil,
                        diagnostics: makeDiagnostics(
                            seekSeconds: 0,
                            actualSeconds: nil,
                            failureStage: "dv_p5_unsupported"
                        )
                    )
                }

                let duration = context.openDurationSeconds
                let origin = context.openStartSeconds
                var offsets = candidateOffsets ?? Self.candidateThumbnailOffsets(durationSeconds: duration)
                if offsets.isEmpty { offsets = [0.0] }

                var triedOffsets: [Double] = []
                var bestBlackFallback: (image: CGImage, seekSeconds: Double, actualSeconds: Double?)?
                var lastSeekAttempted: Double = offsets[0]

                func isStopped() -> Bool {
                    token.isCancelled || cancellation.isCancelled || control.isStopped
                }

                var index = 0
                while index < offsets.count {
                    guard !isStopped() else { break }
                    let relativeOffset = offsets[index]
                    index += 1
                    if triedOffsets.contains(where: { abs($0 - relativeOffset) < 0.25 }) {
                        continue
                    }
                    triedOffsets.append(relativeOffset)
                    lastSeekAttempted = relativeOffset
                    let absoluteTarget = origin + relativeOffset

                    var decodedTime: Double?
                    if let image = context.decodeFrame(
                        at: absoluteTarget,
                        mode: .thumbnail,
                        targetWidth: targetWidth,
                        maxSize: maxSize,
                        isCancelled: isStopped,
                        reportDecodedTime: { decodedTime = $0 }
                    ) {
                        let actualRelative = decodedTime.map { max(0, $0 - origin) }
                        if !FrameDecodeContext.isMostlyBlack(image) {
                            let diag = makeDiagnostics(
                                seekSeconds: relativeOffset,
                                actualSeconds: actualRelative,
                                failureStage: nil
                            )
                            return ThumbnailExtractionOutcome(image: image, diagnostics: diag)
                        }
                        if bestBlackFallback == nil {
                            bestBlackFallback = (image, relativeOffset, actualRelative)
                        }
                        // If we landed on a black frame and still have budget, try one further
                        // point deeper into the video before settling for a black frame.
                        if let duration, (control.remainingTime ?? 0) > 1.8 {
                            let deeper: Double
                            if duration >= 120 {
                                deeper = min(duration * 0.25, relativeOffset + 60.0)
                            } else if duration >= 10 {
                                deeper = min(duration * 0.50, max(5.0, relativeOffset + duration * 0.25))
                            } else {
                                deeper = min(max(0.5, duration * 0.50), max(0.5, duration - 0.5))
                            }
                            if !triedOffsets.contains(where: { abs($0 - deeper) < 0.5 }) {
                                offsets.insert(deeper, at: index)
                            }
                        }
                    }
                }

                // Final non-seeking decode attempt for indexless/unseekable TS or AVI streams.
                if bestBlackFallback == nil && !isStopped() {
                    var decodedTime: Double?
                    if let image = context.decodeFrame(
                        at: origin,
                        mode: .thumbnail,
                        targetWidth: targetWidth,
                        maxSize: maxSize,
                        isCancelled: isStopped,
                        reportDecodedTime: { decodedTime = $0 },
                        skipSeek: true
                    ) {
                        let actualRelative = decodedTime.map { max(0, $0 - origin) }
                        return ThumbnailExtractionOutcome(
                            image: image,
                            diagnostics: makeDiagnostics(
                                seekSeconds: 0,
                                actualSeconds: actualRelative,
                                failureStage: nil,
                                detail: "no_seek_fallback"
                            )
                        )
                    }
                }

                if let fallback = bestBlackFallback, !token.isCancelled, !cancellation.isCancelled {
                    return ThumbnailExtractionOutcome(
                        image: fallback.image,
                        diagnostics: makeDiagnostics(
                            seekSeconds: fallback.seekSeconds,
                            actualSeconds: fallback.actualSeconds,
                            failureStage: nil,
                            detail: "dark_frame_fallback"
                        )
                    )
                }

                let stage = context.lastDecodeFailureStage ?? "decode_frame"
                return ThumbnailExtractionOutcome(
                    image: nil,
                    diagnostics: makeDiagnostics(
                        seekSeconds: lastSeekAttempted,
                        actualSeconds: nil,
                        failureStage: stage
                    )
                )
            }
        } onCancel: {
            token.cancel()
            cancellation.cancel()
        }

        if boundedCancellation === cancellation { boundedCancellation = nil }
        if Task.isCancelled || cancellation.isCancelled || token.isCancelled {
            return ThumbnailExtractionOutcome(
                image: nil,
                diagnostics: ThumbnailExtractionDiagnostics(
                    container: outcome.diagnostics.container,
                    codec: outcome.diagnostics.codec,
                    profile: outcome.diagnostics.profile,
                    bitDepth: outcome.diagnostics.bitDepth,
                    hdrType: outcome.diagnostics.hdrType,
                    dvProfile: outcome.diagnostics.dvProfile,
                    durationSeconds: outcome.diagnostics.durationSeconds,
                    seekSeconds: outcome.diagnostics.seekSeconds,
                    actualSeconds: outcome.diagnostics.actualSeconds,
                    bytesRead: outcome.diagnostics.bytesRead,
                    packetsRead: outcome.diagnostics.packetsRead,
                    colorPath: outcome.diagnostics.colorPath,
                    failureStage: "cancelled"
                )
            )
        }
        return outcome
    }

    /// Open the decode context ahead of the first request to hide cold-start latency
    /// (e.g. at the start of a scrub gesture).
    public func prewarm() async {
        guard !isShutDown else { return }
        let context = self.context
        await runOnQueue { try? context.ensureOpen() }
        scheduleIdleClose()
    }

    /// Permanently tear down the decode context and clear the cache. Awaits teardown on
    /// the decode queue, so on return the FFmpeg demuxer/codec/sws are fully released.
    /// After shutdown() the extractor is dead: thumbnail/preview/snapshot/prewarm return nil/no-op
    /// and do NOT reopen; create a new FrameExtractor to extract again.
    public func shutdown() async {
        idleTask?.cancel()
        isShutDown = true
        currentToken?.cancel()
        boundedCancellation?.cancel()
        boundedCancellation = nil
        cache.clear()
        residentApproximation = nil
        let context = self.context
        await runOnQueue { context.close() }
    }

    // MARK: - Core

    private func produce(at seconds: Double, mode: FrameMode, targetWidth: Int, maxSize: CGSize?) async -> CGImage? {
        // Audit BIT-105: a 0/0 scrub fraction or `CMTime.indefinite.seconds` is a host bug, not a position.
        guard !isShutDown, !Task.isCancelled, seconds.isFinite, seconds >= 0 else { return nil }
        // A valid request owns the scrub intent even when its image is already cached or it
        // yields to playback. Retire the preceding decode before either early return.
        currentToken?.cancel()
        boundedCancellation?.cancel()
        let token = CancelToken()
        currentToken = token
        // Every admitted outcome owns idle cleanup, including cache hits, yields and caller
        // cancellation. A late completion cannot extend the newer request's idle lifetime.
        defer {
            if !isShutDown, currentToken === token { scheduleIdleClose() }
        }
        if let hit = cache.get(mode: mode, seconds: seconds, targetWidth: targetWidth, maxSize: maxSize) {
            return hit
        }
        // Elective thumbnails/previews yield to a starved playback pipeline (snapshots are deliberate
        // one-shot user actions and stay ungated). Checked after the cache: hits are free.
        if mode.isElective, yieldWhile?() == true {
            EngineLog.emit("[FrameExtractor] \(mode) yielded: playback pipeline starved",
                           category: .swPlayback, level: .verbose)
            return nil
        }
        let context = self.context
        let result = await withTaskCancellationHandler {
            await runOnQueue { () -> FrameResult in
                if token.isCancelled { return FrameResult(image: nil) }
                let start = DispatchTime.now()
                let wasOpen = context.isOpen
                let bytesBefore = context.bytesFetched
                do {
                    try context.ensureOpen()
                } catch {
                    EngineLog.emit("[FrameExtractor] open failed: \(error)", category: .swPlayback)
                    return FrameResult(image: nil)
                }
                let image = context.decodeFrame(
                    at: seconds, mode: mode,
                    targetWidth: targetWidth, maxSize: maxSize,
                    isCancelled: { token.isCancelled }
                )
                // Per-miss cost line: correlates extraction bursts with playback stutter
                // (#93 post-recovery lag diagnosis). bytes = link bandwidth this miss consumed.
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                let bytes = context.bytesFetched - bytesBefore
                EngineLog.emit(
                    "[FrameExtractor] miss mode=\(mode) t=\(String(format: "%.2f", seconds))s "
                    + "took=\(String(format: "%.0f", ms))ms bytes=\(bytes) "
                    + "reopened=\(wasOpen ? "n" : "y") image=\(image == nil ? "nil" : "ok") "
                    + "cancelled=\(token.isCancelled ? "y" : "n")",
                    category: .swPlayback, level: .verbose
                )
                return FrameResult(image: image)
            }
        } onCancel: {
            token.cancel()
        }
        // Cancellation can win after the decode's last check, or while its result waits to
        // reenter this actor. Never publish/cache that result or reset a newer request's idle timer.
        guard !isShutDown, !Task.isCancelled, !token.isCancelled else { return nil }
        if let image = result.image {
            cache.set(image, mode: mode, seconds: seconds, targetWidth: targetWidth, maxSize: maxSize)
        }
        return result.image
    }

    /// Run blocking work on the serial queue, awaiting the result without blocking the actor's executor.
    private func runOnQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let context = self.context
        let stamp = queueStamp
        queueJobsInFlight += 1
        let (result, area, order) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(T, Int, Int), Never>) in
            decodeQueue.async {
                let result = work()
                stamp.value += 1
                continuation.resume(returning: (result, context.openDecoderPixelArea, stamp.value))
            }
        }
        queueJobsInFlight -= 1
        noteDecoderArea(area, order: order)
        return result
    }

    private func noteDecoderArea(_ area: Int, order: Int) {
        if area > 0 { knownDecoderPixelArea = area }
        guard order > lastReportedStamp else { return }
        lastReportedStamp = order
        openDecoderPixelArea = area
    }

    /// Tests that wait for the idle close shorten it, so a starved runner does not spend the
    /// suite's time limit on a fixed ten-second sleep.
    func setIdleIntervalForTesting(_ interval: Duration) {
        idleInterval = interval
    }

    /// Restart the idle countdown (called after every request). After `idleInterval`
    /// idle the context closes and cache clears; the next request reopens lazily.
    private func scheduleIdleClose() {
        idleTask?.cancel()
        idleTask = Task { [weak self, idleInterval] in
            do {
                try await Task.sleep(for: idleInterval)
                await self?.idleClose()
            } catch {
                // Cancelled before the interval elapsed: nothing to do.
            }
        }
    }

    /// Transient teardown after idle: closes the context and drops the cache. Unlike
    /// shutdown() this does NOT set `isShutDown`, so the next request lazily reopens.
    private func idleClose() {
        cache.clear()
        residentApproximation = nil
        openDecoderPixelArea = 0
        let context = self.context
        let stamp = queueStamp
        // Fire-and-forget: best-effort, no caller awaits it; runOnQueue would block the actor for nothing.
        // The stamp moves so an earlier job's late report cannot mark the closed decoder open again.
        decodeQueue.async { context.close(); stamp.value += 1 }
    }
}

/// Wrapper so CGImage? crosses the `runOnQueue` Sendable boundary under Swift 6.
/// CGImage is immutable and already passed across domains here (see SubtitleImage).
private struct FrameResult: @unchecked Sendable {
    let image: CGImage?
}

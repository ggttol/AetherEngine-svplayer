import Foundation
import CoreGraphics

extension AetherEngine {

    /// The 2026-09-02 Whole Title trace opened 30 software decoders in 20 seconds while
    /// scrubbing three resident 100 MB segments and back. Six keeps that small working set
    /// warm; each extractor maps its segment file (audit SEG-2), so the entries hold clean
    /// file-backed pages rather than heap copies, and the bound remains fixed.
    nonisolated static let scrubThumbnailExtractorLimit = 6

    /// How much decoded picture the open still decoders may cover between them, in coded pixels.
    /// Six 1920x1088 decoders fit, so a 1080p source keeps its whole LRU warm. A 4K decoder holds
    /// 100 to 160 MB of reference frames, and AE#1059 measured six of them at 750 MB on an Apple TV
    /// 4K, so a 4K source keeps one open and the others close down to their cached stills.
    nonisolated static let scrubDecoderPixelBudget = 6 * 1920 * 1088

    public func clearResidentPreviewFrames() {
        for entry in scrubThumbnailExtractors {
            Task { await entry.extractor.clearResidentPreviewCache() }
        }
    }

    /// Closes every scrub-still decoder now and returns once they are closed. Call it when the
    /// scrub ends. The extractors and their cached stills stay, so the next request answers from
    /// the cache or reopens its decoder. Playback is untouched (AE#1059).
    public func releaseScrubPreviewDecoders() async {
        let extractors = scrubThumbnailExtractors.map(\.extractor)
        await withTaskGroup(of: Void.self) { group in
            for extractor in extractors {
                group.addTask { await extractor.releaseDecoder() }
            }
        }
    }

    /// Keeps the open decoders inside `scrubDecoderPixelBudget` before `incoming` decodes. The
    /// newest entries keep theirs; `incoming` counts at the size it last decoded at, or at the
    /// largest size any entry knows when it never opened, so the budget holds before the open
    /// rather than after it. Closing waits for the decode queue of each released extractor.
    func enforceScrubDecoderBudget(before incoming: FrameExtractor) async {
        let entries = scrubThumbnailExtractors.map(\.extractor)
        var largest = 0
        var states: [(extractor: FrameExtractor, open: Int)] = []
        for extractor in entries {
            largest = max(largest, await extractor.knownDecoderPixelArea)
            // A first open still in flight knows no area yet; count it at the largest one known.
            let budgeted = await extractor.budgetedDecoderPixelArea
            let mayBeOpen = await extractor.decoderMayBeOpen
            let open = budgeted == 0 && mayBeOpen ? -1 : budgeted
            states.append((extractor, open))
        }
        let incomingKnown = await incoming.knownDecoderPixelArea
        let released = Self.scrubDecodersToRelease(
            newestLast: states.map { $0.extractor === incoming ? 0 : ($0.open < 0 ? max(largest, 1) : $0.open) },
            incomingArea: incomingKnown > 0 ? incomingKnown : largest)
        guard !released.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for index in released {
                let extractor = states[index].extractor
                group.addTask { await extractor.releaseDecoder() }
            }
        }
    }

    /// Indices into `newestLast` (open decoder areas, oldest first, 0 for a closed one) whose
    /// decoders close so they fit the budget next to `incomingArea`. Newest first wins.
    nonisolated static func scrubDecodersToRelease(newestLast areas: [Int], incomingArea: Int,
                                                   budget: Int = scrubDecoderPixelBudget) -> [Int] {
        var used = incomingArea
        var released: [Int] = []
        for index in areas.indices.reversed() where areas[index] > 0 {
            if used + areas[index] > budget { released.append(index) } else { used += areas[index] }
        }
        return released
    }

    /// SVPlayer modification: synchronous lookup of the nearest decoded picture on the
    /// display timeline. The rung is stamped on the playlist axis by the ladder worker.
    public func readyScrubPreviewFrame(atSeconds seconds: Double) -> ScrubFrame? {
        guard seconds.isFinite, !isLive, supportsCacheBackedStills else { return nil }
        let recent = recentScrubFrames.nearest(to: seconds).flatMap {
            abs($0.actualSeconds - seconds) <= KeyframeStillLadder.maximumAnswerDistanceSeconds ? $0 : nil
        }
        guard let session = nativeVideoSession else { return recent }
        let shift = session.firstKeyframeSeconds - sourcePresentationOrigin
        guard let rung = session.readyLadderFrame(at: seconds - shift)?.shifted(by: shift),
              abs(rung.actualSeconds - seconds) <= KeyframeStillLadder.maximumAnswerDistanceSeconds else { return recent }
        guard let recent else { return rung }
        return abs(recent.actualSeconds - seconds) <= abs(rung.actualSeconds - seconds) ? recent : rung
    }

    public func updateScrubPreviewTarget(atSeconds seconds: Double?) {
        guard !isLive, let session = nativeVideoSession, session.yieldsStills else { return }
        let shift = session.firstKeyframeSeconds - sourcePresentationOrigin
        session.updateScrubFinger(seconds.map { $0 - shift }, playhead: nativeHost?.renderedTime)
    }

    /// Existing clients only decode resident data. An interactive refinement may opt into a
    /// separately budgeted, cancellable read of an ordinary seekable VOD when its link is idle.
    public func scrubPreviewFrame(atSeconds seconds: Double, refined: Bool, maxWidth: Int = 320,
                                  sourceRefinement: ProbeCancellation? = nil,
                                  isCancelled: @escaping @Sendable () -> Bool) async -> ScrubFrame? {
        let generation = loadGeneration
        let allowsRead = refined && sourceRefinement != nil
        if allowsRead, !isLive, maxWidth == 320, let precise = recentScrubFrames.nearest(to: seconds),
           precise.isRefined(at: seconds), !Task.isCancelled, !isCancelled() { return precise }
        var frame = await cacheBackedScrubPreviewFrame(atSeconds: seconds, refined: refined, maxWidth: maxWidth,
                                                       includesLadder: !allowsRead, isCancelled: isCancelled)
        guard generation == loadGeneration, !Task.isCancelled, !isCancelled() else { return nil }
        if allowsRead, let cancellation = sourceRefinement, frame?.isRefined(at: seconds) != true {
            frame = await sourceScrubRefinement(atSeconds: seconds, maxWidth: maxWidth, cancellation: cancellation)
        }
        guard generation == loadGeneration, !Task.isCancelled, !isCancelled() else { return nil }
        if let frame, !isLive, maxWidth <= 320 { recentScrubFrames.insert(frame) }
        return frame
    }

    private func cacheBackedScrubPreviewFrame(atSeconds seconds: Double, refined: Bool, maxWidth: Int,
                                              includesLadder: Bool,
                                              isCancelled: @escaping @Sendable () -> Bool) async -> ScrubFrame? {
        guard seconds.isFinite, !Task.isCancelled, !isCancelled() else { return nil }
        let gen = loadGeneration
        guard let session = nativeVideoSession else {
            guard let host = softwareHost, host.videoYieldsStills else { return nil }
            if softwareStillsFromLocalFile {
                let result = await localSoftwareStill(atSessionSeconds: seconds, refined: refined,
                                                      maxWidth: maxWidth, isCancelled: isCancelled)
                return gen == loadGeneration && !Task.isCancelled && !isCancelled() ? result : nil
            }
            let result = await host.scrubPreviewFrame(atSessionSeconds: seconds, refined: refined,
                                                     maxWidth: maxWidth, isCancelled: isCancelled)
            return gen == loadGeneration && !Task.isCancelled && !isCancelled() ? result : nil
        }
        guard session.yieldsStills else { return nil }
        // Freeze both axes. VOD segment indices use the plan's keyframe origin;
        // the segment's bytes retain their own epoch normalization after restart.
        let origin = sourcePresentationOrigin
        let live = isLive
        // Live: the same stable session-to-output shift `liveScrubThumbnail` uses (#712), frozen
        // here so the request and its result convert on one axis even if the shift moves meanwhile.
        let liveShift = liveSessionShiftSeconds
        let sourceTarget = PresentationAxis.source(displayTime: seconds, origin: origin)
        let planOrigin = session.firstKeyframeSeconds - origin
        let output = live ? seconds - liveShift : seconds - planOrigin
        let source = await BlockingWork.detached(priority: .utility) { [session] in
            session.scrubThumbnailSource(atSeconds: output)
        }.value
        guard gen == loadGeneration, !Task.isCancelled, !isCancelled() else { return nil }
        guard let source else {
            guard !live, includesLadder else { return nil }
            return await ladderPreviewFrame(session: session, outputSeconds: output, planOrigin: planOrigin,
                                            maxWidth: maxWidth, generation: gen, prioritizeFinger: !refined,
                                            isCancelled: isCancelled)
        }
        guard let carried = source.carriedOffset else { return nil }
        guard let extractor = scrubExtractor(key: source.segmentIndex, identity: source.identity, make: {
            source.makeReader().map {
                FrameExtractor(residentReader: $0, formatHint: "mp4", identity: source.identity)
            }
        }) else { return nil }
        let rawTarget = live ? output : sourceTarget - carried
        guard let frame = await decodeScrubStill(
            on: extractor, generation: gen, stillWanted: { !Task.isCancelled && !isCancelled() }, {
                await extractor.residentPreview(rawTarget: rawTarget, refined: refined, maxWidth: maxWidth,
                                                isCancelled: isCancelled)
            }) else { return nil }
        let stillOwned = await BlockingWork.detached(priority: .utility) { [session] in
            guard let current = session.scrubThumbnailSource(atSeconds: output) else { return false }
            return current.identity == source.identity && current.carriedOffset == source.carriedOffset
        }.value
        guard stillOwned, gen == loadGeneration, !Task.isCancelled, !isCancelled() else { return nil }
        guard let actual = live ? Optional(frame.actualSeconds + liveShift)
            : ScrubSegmentTime.displayTime(rawPTS: frame.actualSeconds, carriedOffset: carried, displayOrigin: origin)
        else { return nil }
        let rangeStart = live ? source.startSeconds + liveShift : source.startSeconds + planOrigin
        return ScrubFrame(image: frame.image, actualSeconds: actual, refined: frame.refined,
                         validRange: rangeStart..<(rangeStart + source.durationSeconds))
    }

    /// SVPlayer modification: a native VOD reuses the foreground rung's serial AVIO reader.
    /// Remote software playback uses its resident packet cache. Local files can seek directly.
    private func sourceScrubRefinement(atSeconds seconds: Double, maxWidth: Int,
                                       cancellation: ProbeCancellation) async -> ScrubFrame? {
        guard seconds.isFinite, seconds >= 0, maxWidth > 0, maxWidth <= 320,
              !isLive, supportsCacheBackedStills, !scrubPreviewDrawsInView,
              !isSeeking, !isBuffering, !loadedOptions.sequentialOrigin, !loadedOptions.heldSourceConnection,
              isSourceSeekable == true, activeDiscTitleID == nil, !isCustomSource,
              let url = loadedURL, !Task.isCancelled, !cancellation.isCancelled else { return nil }
        if let session = nativeVideoSession {
            let shift = session.firstKeyframeSeconds - sourcePresentationOrigin
            let still = await BlockingWork.detached(priority: .utility) {
                session.refineScrubFinger(at: seconds - shift, maxWidth: maxWidth, cancellation: cancellation)
            }.value
            return still?.shifted(by: shift)
        }
        guard url.isFileURL, let host = softwareHost, let extractor = makeFrameExtractor() else { return nil }
        let origin = host.sourceSeconds(forSession: 0)
        let limit = ProbeLimits(maxInputBytes: 8 * 1024 * 1024, maxPackets: 900,
                                maxPacketBytes: 4 * 1024 * 1024, timeBudget: 2)
        let size = CGSize(width: CGFloat(maxWidth), height: CGFloat(maxWidth))
        let still = await extractor.boundedSnapshot(at: seconds + origin, maxSize: size,
                                                    limits: limit, cancellation: cancellation)
        await extractor.shutdown()
        guard let still, let actual = still.actualSeconds, actual.isFinite,
              abs(actual - origin - seconds) < 2 else { return nil }
        return ScrubFrame(image: still.image, actualSeconds: actual - origin, refined: true, source: .sourceRead)
    }

    /// The selected segment's own coarse image takes priority. Other callers only consult cached rungs.
    private func ladderPreviewFrame(session: HLSVideoEngine, outputSeconds: Double, planOrigin: Double,
                                    maxWidth: Int, generation gen: UInt64, prioritizeFinger: Bool,
                                    isCancelled: @escaping @Sendable () -> Bool) async -> ScrubFrame? {
        let answer = await BlockingWork.detached(priority: .utility) { [session] () -> HLSVideoEngine.LadderPreview? in
            if prioritizeFinger, maxWidth == 320,
               let frame = session.fingerLadderFrame(at: outputSeconds, isCancelled: isCancelled) {
                return HLSVideoEngine.LadderPreview.ready(frame)
            }
            return session.stillLadderFrame(atSeconds: outputSeconds, maxWidth: maxWidth)
        }.value
        guard let answer, gen == loadGeneration, !Task.isCancelled, !isCancelled() else { return nil }
        let rung: HLSVideoEngine.StillLadderFrame
        switch answer {
        case .ready(let frame): return frame.shifted(by: planOrigin)
        case .compressed(let payload): rung = payload
        }
        guard let extractor = scrubExtractor(key: Self.ladderStillKey(segmentIndex: rung.segmentIndex), make: {
            FrameExtractor(residentReader: rung.makeReader(), formatHint: "mp4",
                           identity: "ladder:\(rung.segmentIndex)")
        }) else { return nil }
        guard let frame = await decodeScrubStill(
            on: extractor, generation: gen, stillWanted: { !Task.isCancelled && !isCancelled() }, {
                await extractor.residentPreview(rawTarget: 0, refined: false, maxWidth: maxWidth,
                                                isCancelled: isCancelled)
            }) else { return nil }
        let start = rung.startSeconds + planOrigin
        return ScrubFrame(image: frame.image, actualSeconds: start, refined: false,
                          validRange: start..<(start + rung.durationSeconds), source: .ladder)
    }

    /// Ladder stills share the extractor LRU with resident segments under keys no segment carries
    /// (below `localSoftwareStillKey`).
    nonisolated static func ladderStillKey(segmentIndex: Int) -> Int { -2 - segmentIndex }

    /// Engine half of the ladder's 1 Hz tick: the session decides, this hands it the playhead and
    /// the contiguous buffer ahead of it. Skipped while a seek is pending, when both point at a
    /// position the picture has not reached.
    func tickKeyframeStillLadder() {
        guard !isLive, pendingRecoverySeekClockTarget == nil,
              let session = nativeVideoSession, let host = nativeHost else { return }
        let playhead = host.renderedTime
        let ahead = session.contiguousForwardReadAheadSeconds(playlistSeconds: playhead)
        session.stillLadderTick(playheadPlaylistSeconds: playhead, forwardBufferSeconds: ahead)
    }

    /// Cache-backed scrub still for the active native session (live or VOD). Decodes from
    /// already-produced SegmentCache bytes, so it never opens a second connection and works
    /// on single-connection sources (debrid/torrent HTTP links, #106) where the
    /// FrameExtractor's second demuxer is refused. Returns nil when there is no native
    /// session, the segment is not resident (not yet produced far ahead of the playhead, or
    /// evicted past the retention budget), or decode fails; a nil is the correct
    /// "not available yet" and hosts show time-only. `seconds` is session-timeline
    /// (seekableLiveRange axis) for live, playlist/output seconds for VOD.
    public func scrubThumbnail(atSeconds seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        if isLive {
            return await liveScrubThumbnail(atSessionSeconds: seconds, maxWidth: maxWidth)
        }
        return await vodScrubThumbnail(atSeconds: seconds, maxWidth: maxWidth)
    }

    /// VOD arm of `scrubThumbnail`. `!isLive` guards direct callers: `nativeVideoSession` is
    /// non-nil for live too, and `scrubThumbnailSource` no longer self-gates on isLiveSession,
    /// so a VOD decode must not run against a live session (whose seam-shift axis differs).
    /// Hands the extractor exactly one segment (init + the seg containing `seconds`) and seeks
    /// to 0: thumbnail mode returns the first frame after the seek, so 0 lands on that segment's
    /// first keyframe whether its fMP4 tfdt is absolute or zero-based (post-restart). This makes
    /// the decode axis-independent and correct by construction. Per-segment granularity.
    ///
    /// A software session (AE#605) has no segments; it decodes the still out of the packet cache
    /// its seeks already land in, keyframe to target, on the same session axis `seek(to:)` takes.
    /// One that plays a local file keeps no cache and reads the file instead (see
    /// `softwareStillsFromLocalFile`). Either way the picture is the base layer, so a Dolby Vision
    /// Profile 7 title needs no enhancement layer to show a still.
    public func vodScrubThumbnail(atSeconds seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        guard !isLive else { return nil }
        guard let session = nativeVideoSession else {
            guard let host = softwareHost else { return nil }
            let gen = loadGeneration
            if softwareStillsFromLocalFile {
                let frame = await localSoftwareStill(atSessionSeconds: seconds, refined: false,
                                                     maxWidth: maxWidth, isCancelled: { false })
                return loadGeneration == gen ? frame?.image : nil
            }
            let image = await host.vodScrubStill(atSessionSeconds: seconds, maxWidth: maxWidth)
            return loadGeneration == gen ? image : nil
        }
        guard session.yieldsStills else { return nil }
        let gen = loadGeneration
        let source = await BlockingWork.detached(priority: .userInitiated) { [session] in
            session.scrubThumbnailSource(atSeconds: seconds)
        }.value
        // Guard against zap/stop clearing the LRU: a stale extractor's segment indices
        // collide with the next source's.
        guard let source, loadGeneration == gen else { return nil }
        guard let extractor = scrubExtractor(key: source.segmentIndex, make: {
            source.makeReader().map { FrameExtractor(reader: $0, formatHint: "mp4") }
        }) else { return nil }
        return await decodeScrubStill(on: extractor, generation: gen) {
            await extractor.thumbnail(at: 0, maxWidth: maxWidth)
        }
    }

    /// The one lookup into the still LRU (audit LOAD-R201). A hit moves to the newest end. A hit whose
    /// resident `identity` no longer matches the bytes behind its key is shut down and replaced; nil
    /// `identity` takes any extractor under the key. A miss is made by `make` and the list trimmed.
    func scrubExtractor(key: Int, identity: String? = nil,
                        make: () -> FrameExtractor?) -> FrameExtractor? {
        if let index = scrubThumbnailExtractors.firstIndex(where: { $0.segmentIndex == key }) {
            let hit = scrubThumbnailExtractors.remove(at: index)
            if identity == nil || hit.extractor.residentIdentity == identity {
                scrubThumbnailExtractors.append(hit)
                return hit.extractor
            }
            Task { await hit.extractor.shutdown() }
        }
        guard let made = make() else { return nil }
        scrubThumbnailExtractors.append((key, made))
        trimScrubThumbnailExtractors()
        return made
    }

    /// One still decode inside the AE#1059 decoder budget, for the session `generation` names. nil
    /// when that session ended before or during the decode, or `stillWanted` says the caller gave up:
    /// a zap in between would hand the new item the old one's picture (audit LOAD-205).
    func decodeScrubStill<Still>(on extractor: FrameExtractor, generation: UInt64,
                                 stillWanted: () -> Bool = { true },
                                 _ decode: () async -> Still?) async -> Still? {
        await extractor.reserveDecode()
        await enforceScrubDecoderBudget(before: extractor)
        guard generation == loadGeneration, stillWanted() else {
            await extractor.endDecodeReservation()
            return nil
        }
        let still = await decode()
        await extractor.endDecodeReservation()
        return generation == loadGeneration && stillWanted() ? still : nil
    }

    /// Enforce the cache-backed still LRU after a miss. Kept internal so the exact six-entry
    /// eviction boundary can be pinned without opening a playback session.
    func trimScrubThumbnailExtractors() {
        while scrubThumbnailExtractors.count > Self.scrubThumbnailExtractorLimit {
            let evicted = scrubThumbnailExtractors.removeFirst()
            Task { await evicted.extractor.shutdown() }
        }
    }

    /// A key no segment carries, for the one extractor a local-file software session keeps in
    /// `scrubThumbnailExtractors` (teardown and the stale-generation clear already cover that list).
    nonisolated static let localSoftwareStillKey = -1

    /// True when a software VOD session plays a local file whose frames can become stills. Such a
    /// session keeps no packet cache, because re-reading the file is a page-cache hit, so its stills
    /// are decoded from the file by a `FrameExtractor`. That opens no connection to any origin, which
    /// is what the cache exists to avoid. False for a Dolby Vision Profile 5 / 10.0 file without the
    /// `DolbyVisionStillReshaping` trait, which `FrameDecodeContext` refuses every still of.
    var softwareStillsFromLocalFile: Bool {
        guard let softwareHost, !isLive, !isCustomSource, loadedURL?.isFileURL == true,
              softwareHost.videoYieldsStills else { return false }
        return !softwareHost.servesPacketCacheStills
    }

    /// The still for a local-file software session. `refined` asks for the frame at the target, not
    /// the keyframe before it. The extractor takes the source axis, which `seek(to:)` also lands on
    /// after its session-to-source shift. It decodes the base layer, the same picture the host's
    /// own decoder shows for a dual-layer Dolby Vision title.
    func localSoftwareStill(atSessionSeconds seconds: Double, refined: Bool, maxWidth: Int,
                            isCancelled: @escaping @Sendable () -> Bool) async -> ScrubFrame? {
        guard let host = softwareHost, softwareStillsFromLocalFile, seconds.isFinite, seconds >= 0 else { return nil }
        let gen = loadGeneration
        guard let extractor = scrubExtractor(key: Self.localSoftwareStillKey, make: { makeFrameExtractor() }) else {
            return nil
        }
        let source = host.sourceSeconds(forSession: seconds)
        guard let still = await decodeScrubStill(
            on: extractor, generation: gen, stillWanted: { !Task.isCancelled && !isCancelled() }, {
                await extractor.boundedLocalStill(at: source, refined: refined, maxWidth: maxWidth,
                                                  isCancelled: isCancelled)
            }) else { return nil }
        // Only a measured timestamp can label a preview on the session axis.
        let zero = host.sourceSeconds(forSession: 0)
        guard let measured = still.decodedSeconds, measured.isFinite else { return nil }
        let actual = max(0, measured - zero)
        return ScrubFrame(image: still.image, actualSeconds: actual, refined: refined)
    }

    /// True when the active session can serve cache-backed stills from `scrubThumbnail` with no
    /// second connection: any native session (live or VOD, SegmentCache), a software live session
    /// (DVR packet ring, #544), a software VOD session reading a remote source (packet cache,
    /// AE#605) and one playing a local file (decoded from the file, no connection at all). False
    /// before load. Hosts on a single-connection source should gate the
    /// scrub-preview affordance on this: true means use `scrubThumbnail`; false means hide
    /// the preview rather than show blank frames from a refused second-connection
    /// FrameExtractor (#106). It reports capability, not per-frame availability: transient
    /// nils from `scrubThumbnail` while a segment is still being produced are expected. False as well
    /// on a Dolby Vision Profile 5 / 10.0 session in a build without the `DolbyVisionStillReshaping`
    /// trait, where no frame can become a correct still; `scrubPreviewDrawsInView` covers that source.
    public var supportsCacheBackedStills: Bool {
        if let session = nativeVideoSession { return session.yieldsStills }
        guard let softwareHost, softwareHost.videoYieldsStills else { return false }
        return isLive || softwareHost.servesPacketCacheStills || softwareStillsFromLocalFile
    }
}

// Modified by SVPlayer on 2026-11-20.
import Foundation
import AVFAudio

/// SVPlayer modification. Measure sustained lead deficit across packet arrivals.
struct AudioTapRefill {
    private var lowSince: TimeInterval?
    private var active = false

    mutating func needsLookahead(lead: Double, now: TimeInterval) -> Bool {
        if lead >= AudioTapDefaults.leadSeconds {
            lowSince = nil
            active = false
        } else if lead < AudioTapDefaults.refillLeadSeconds {
            lowSince = lowSince ?? now
            if let lowSince, now - lowSince >= 0.35 { active = true }
        } else {
            lowSince = nil
        }
        return active
    }
}

/// SVPlayer modification. Keep the decoder's sample boundaries independent of delivery stamp rounding.
struct AudioTapOutputClock {
    private var sampleEnd: Double?
    private(set) var deliveredEnd: Double?

    mutating func accept(_ chunk: AudioTapChunk, landing: Double, discontinuity: Bool) -> AudioTapBuffer? {
        let floor = max(landing, sampleEnd ?? landing)
        guard let clipped = AudioPacketTap.clip(chunk, to: floor) else { return nil }
        let start = max(clipped.sourceTime, deliveredEnd ?? clipped.sourceTime)
        let gap = deliveredEnd.map { start - $0 > 0.25 } ?? false
        sampleEnd = chunk.ptsSeconds + Double(chunk.buffer.frameLength) / AudioTapDefaults.sampleRate
        deliveredEnd = start + Double(clipped.buffer.frameLength) / AudioTapDefaults.sampleRate
        return clipped.restamped(sourceTime: start, discontinuity: discontinuity || gap)
    }
}

// SVPlayer modification (2026-11-23): Event-driven serial queue scheduling replaces blocking
// NSCondition.wait on a higher-QoS global queue, eliminating Darwin QoS priority inversion
// warnings while keeping zero-poll idle sleeping and immediate wakeups on packet/playhead/stop updates.

/// SVPlayer modification. One decoder per installed tap. The playback demux always has priority.
/// A cancellable AVIO reader can fill a missing interval on seekable VOD after a short grace period.
final class AudioPacketTap: @unchecked Sendable {
    private let packets: AudioPacketWindow
    private let channels: AudioTapChannels
    private let start: Double
    private let playhead: AtomicDouble
    private let source: AudioPacketLookahead.Source?
    private let yield: @Sendable (AudioTapBuffer) -> Void
    private let finish: @Sendable () -> Void
    private let lock = NSLock()
    // SVPlayer modification (2026-11-23): Default-QoS serial queue inherits caller QoS (including stop())
    // without parking a higher-QoS worker thread on a lower-QoS signaller.
    private let workerQueue = DispatchQueue(label: "aether.audiotap.worker")
    private var primaryObserverID: UUID?
    private var sideObserverID: UUID?
    private var started = false
    private var scheduled = false
    private var stopped = false
    private var lookahead: AudioPacketLookahead?
    private var preparedEnd: Double?
    private var linkRestricted = false

    // Worker-queue-only state.
    private var finished = false
    private var wakeTimer: DispatchSourceTimer?
    private var decoder: AudioTapDecoder
    private var primaryCursor = AudioPacketWindow.Cursor()
    private var sideCursor = AudioPacketWindow.Cursor()
    private var lastInput: Double?
    private var output = AudioTapOutputClock()
    private var lastUsedSide = false
    private var landing: Double
    private var formatVersion: UInt64?
    private var refill = AudioTapRefill()
    private var discontinuity = true

    var progress: AudioTapProgress {
        let (end, reader, restricted) = lock.withLock { (preparedEnd, lookahead, linkRestricted) }
        return AudioTapProgress(primarySourceEnd: packets.latestSourceEnd, preparedSourceEnd: end,
                                lookaheadSourceEnd: reader?.packets.latestSourceEnd,
                                lookaheadState: reader?.status ?? (restricted ? "originLimited" : source == nil ? "unavailable" : "primary"),
                                targetLeadSeconds: AudioTapDefaults.leadSeconds)
    }

    init(packets: AudioPacketWindow, channels: AudioTapChannels, start: Double,
         playhead: AtomicDouble, source: AudioPacketLookahead.Source?,
         yield: @escaping @Sendable (AudioTapBuffer) -> Void, finish: @escaping @Sendable () -> Void) {
        self.packets = packets
        self.channels = channels
        self.start = start
        self.landing = start
        self.decoder = AudioTapDecoder(channels: channels)
        self.playhead = playhead
        self.source = source
        self.yield = yield
        self.finish = finish
    }

    func begin() {
        // SVPlayer modification (2026-11-23): Register wake hooks before scheduling event-driven decode steps.
        let observerID = packets.addMutationObserver { [weak self] in self?.scheduleStep() }
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            primaryObserverID = observerID
            return true
        }
        guard shouldStart else {
            packets.removeMutationObserver(observerID)
            return
        }
        playhead.setOnChange { [weak self] in self?.scheduleStep() }
        scheduleStep()
    }

    func notifyWake() {
        scheduleStep()
    }

    func stop() {
        let (reader, primaryID, sideID, shouldSchedule) = lock.withLock {
            stopped = true
            let primaryID = primaryObserverID
            let sideID = sideObserverID
            primaryObserverID = nil
            sideObserverID = nil
            let shouldSchedule = started && !scheduled
            if shouldSchedule { scheduled = true }
            return (lookahead, primaryID, sideID, shouldSchedule)
        }
        if let primaryID { packets.removeMutationObserver(primaryID) }
        if let sideID { reader?.packets.removeMutationObserver(sideID) }
        playhead.setOnChange(nil)
        reader?.stop()
        if shouldSchedule {
            workerQueue.async { [self] in step() }
        }
    }

    private func scheduleStep() {
        let shouldDispatch = lock.withLock { () -> Bool in
            guard started, !scheduled else { return false }
            scheduled = true
            return true
        }
        guard shouldDispatch else { return }
        workerQueue.async { [self] in step() }
    }

    private func sideReader(for format: AudioPacketWindow.Format) -> AudioPacketLookahead? {
        guard let source else { return nil }
        let limited = OriginRequestBudget.shared.isPaced(source.url)
            || OriginRequestBudget.shared.requiresSerialRequests(source.url)
        return lock.withLock {
            linkRestricted = limited
            guard !stopped, !limited else { return nil }
            if lookahead == nil {
                let created = AudioPacketLookahead(source: source, format: format, sourceOffset: packets.sourceOffset)
                sideObserverID = created.packets.addMutationObserver { [weak self] in self?.scheduleStep() }
                lookahead = created
            }
            return lookahead
        }
    }

    private func cancelTimer() {
        wakeTimer?.cancel()
        wakeTimer = nil
    }

    private func armTimer(after delay: TimeInterval) {
        cancelTimer()
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now() + max(0.005, delay), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.cancelTimer()
            self?.step()
        }
        wakeTimer = timer
        timer.resume()
    }

    private func deliver(_ chunks: [AudioTapChunk]) {
        for chunk in chunks {
            discontinuity = discontinuity || chunk.discontinuity
            guard let current = output.accept(chunk, landing: landing, discontinuity: discontinuity) else { continue }
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            preparedEnd = output.deliveredEnd
            yield(current)
            lock.unlock()
            discontinuity = false
        }
    }

    private func finalize() {
        guard !finished else { return }
        finished = true
        cancelTimer()
        let (primaryID, reader, sideID) = lock.withLock {
            stopped = true
            let primaryID = primaryObserverID
            let sideID = sideObserverID
            primaryObserverID = nil
            sideObserverID = nil
            return (primaryID, lookahead, sideID)
        }
        if let primaryID { packets.removeMutationObserver(primaryID) }
        if let sideID { reader?.packets.removeMutationObserver(sideID) }
        playhead.setOnChange(nil)
        decoder.close()
        finish()
    }

    private func step() {
        cancelTimer()
        guard !finished else { return }
        while true {
            let isStopped = lock.withLock { () -> Bool in
                scheduled = false
                return stopped
            }
            if isStopped {
                finalize()
                return
            }
            guard let format = packets.format else {
                finalize()
                return
            }
            if formatVersion != format.version {
                let (old, oldSideID) = lock.withLock {
                    let old = lookahead
                    let oldSideID = sideObserverID
                    lookahead = nil
                    sideObserverID = nil
                    preparedEnd = nil
                    return (old, oldSideID)
                }
                if let oldSideID { old?.packets.removeMutationObserver(oldSideID) }
                old?.stop()
                decoder.close()
                decoder = AudioTapDecoder(channels: channels)
                do { try decoder.open(parameters: format.parameters.ptr, timeBase: format.timeBase) }
                catch {
                    EngineLog.emit("[AudioTap] decoder unavailable stream=\(format.streamIndex) error=\(error)", category: .engine)
                    finalize()
                    return
                }
                formatVersion = format.version
                primaryCursor = .init()
                sideCursor = .init()
                refill = .init()
                if lastInput != nil {
                    landing = playhead.get()
                    output = .init()
                }
                lastInput = nil
                discontinuity = true
            }
            let head = playhead.get()
            let frontier = max(landing, output.deliveredEnd ?? landing, lastInput ?? landing)
            let refillNeeded = refill.needsLookahead(lead: frontier - head, now: ProcessInfo.processInfo.systemUptime)
            let atEnd = packets.hasEnded(at: frontier)
                || lock.withLock({ lookahead })?.packets.hasEnded(at: frontier) == true
            if frontier >= head + AudioTapDefaults.leadSeconds, !atEnd {
                armTimer(after: 2.0)
                return
            }
            let floor = max(landing - 0.25, lastInput ?? landing - 0.25)
            // Reject old-position packets even if their producer finishes after seek. A genuine
            // timestamp gap becomes eligible as the picture clock reaches its far side.
            let ceiling = max(frontier, head) + 0.75
            var usingSide = false
            var packet = packets.next(cursor: &primaryCursor, from: floor, through: ceiling,
                                      version: format.version)
            if packet == nil {
                let side: AudioPacketLookahead?
                if refillNeeded, !atEnd, let allowed = sideReader(for: format) {
                    allowed.request(from: max(landing, lastInput ?? landing),
                                    through: head + AudioTapDefaults.leadSeconds)
                    side = allowed
                } else {
                    side = lock.withLock { lookahead }
                }
                if let side {
                    if let sideFormat = side.packets.format {
                        packet = side.packets.next(cursor: &sideCursor, from: floor,
                                                   through: ceiling, version: sideFormat.version)
                        usingSide = packet != nil
                    }
                }
            }
            guard let packet else {
                if atEnd {
                    deliver(decoder.drain())
                    finalize()
                    return
                }
                armTimer(after: 0.20)
                return
            }
            if let lastInput, packet.start < lastInput - 0.000_001
                || (usingSide != lastUsedSide && packet.start <= lastInput + 0.000_001) { continue }
            lastInput = packet.start
            lastUsedSide = usingSide
            deliver(decoder.decode(packet: packet.pointer))
        }
    }

    static func clip(_ chunk: AudioTapChunk, to floor: Double) -> AudioTapBuffer? {
        let length = Int(chunk.buffer.frameLength)
        let dropped = (floor - chunk.ptsSeconds) * AudioTapDefaults.sampleRate
        guard length > 0, dropped.isFinite, dropped < Double(length) else { return nil }
        // SVPlayer modification. Snap only representational noise at whole-sample boundaries.
        // A genuine fractional seek still starts with the first sample at or after the landing.
        let tolerance = min(0.25, max(floor.ulp, chunk.ptsSeconds.ulp) * AudioTapDefaults.sampleRate * 4)
        let nearest = dropped.rounded()
        let frames = Int(max(0, abs(dropped - nearest) <= tolerance ? nearest : dropped.rounded(.up)))
        guard frames < length else { return nil }
        let pcm: AVAudioPCMBuffer
        if frames > 0 {
            guard let clipped = AudioTapMonotonicFilter.trimmedBuffer(chunk.buffer, dropFrames: frames) else { return nil }
            pcm = clipped
        } else {
            pcm = chunk.buffer
        }
        let sampleTime = chunk.ptsSeconds + Double(frames) / AudioTapDefaults.sampleRate
        return AudioTapBuffer(buffer: pcm, sourceTime: max(floor, sampleTime), discontinuity: false,
                              channels: chunk.channels)
    }
}

import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// SVPlayer modification. Fill only a short missing interval when the playback demux has not
/// supplied enough packets. All origin IO goes through the engine's normal Demuxer/AVIOReader.
final class AudioPacketLookahead: @unchecked Sendable {
    struct Source: Sendable {
        let url: URL
        let reader: IOReader?
        let formatHint: String?
        let headers: [String: String]
        let headerStore: RequestHeaderStore
        let probeSize: Int64?
        let analyzeDuration: Int64?
        let discTitleID: Int?
    }

    let packets = AudioPacketWindow()
    private let source: Source
    private let format: AudioPacketWindow.Format
    private let sourceOffset: Int64
    private let lock = NSCondition()
    private var stopped = false
    private var running = false
    private var requestedStart = -Double.infinity
    private var requestedEnd = -Double.infinity
    private var demuxer: Demuxer?
    private var openingCustomReader: IOReader?
    private var terminal = false
    private var phase = "idle"

    var status: String { lock.withLock { phase } }

    init(source: Source, format: AudioPacketWindow.Format, sourceOffset: Int64) {
        self.source = source
        self.format = format
        self.sourceOffset = sourceOffset
    }

    func request(from sourceTime: Double, through target: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, !terminal else { return }
        requestedStart = max(requestedStart, sourceTime)
        requestedEnd = max(requestedEnd, target)
        lock.signal()
        if !running {
            running = true
            phase = "opening"
            DispatchQueue.global(qos: .utility).async { [self] in run(start: sourceTime) }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let active = demuxer
        let openingReader = openingCustomReader
        lock.broadcast()
        lock.unlock()
        active?.markClosed()
        openingReader?.cancel()
    }

    private func run(start: Double) {
        let demux = Demuxer()
        var ownedReader: IOReader?
        var outcome = "unavailable"
        lock.lock()
        if stopped { lock.unlock(); return }
        demuxer = demux
        lock.unlock()
        defer {
            lock.withLock { openingCustomReader = nil }
            demux.close()
            ownedReader?.close()
            lock.lock()
            demuxer = nil
            terminal = true
            phase = stopped ? "stopped" : outcome
            lock.unlock()
        }
        let profile = DemuxerOpenProfile.subtitleSideDemuxer(callerProbesize: source.probeSize,
            callerMaxAnalyzeDuration: source.analyzeDuration).withReaderLabel("speech-lookahead")
            .withRequestHeaders(source.headerStore)
        do {
            if let reader = source.reader {
                guard let clone = reader.makeIndependentReader() else { return }
                // SVPlayer modification. The AVIO bridge borrows the clone during a read or seek.
                ownedReader = clone
                let mayOpen = lock.withLock {
                    guard !stopped else { return false }
                    openingCustomReader = clone
                    return true
                }
                guard mayOpen else { return }
                try demux.open(reader: clone, formatHint: source.formatHint, profile: profile,
                               selectTitleID: source.discTitleID)
                lock.withLock { openingCustomReader = nil }
            } else {
                try demux.open(url: source.url, extraHeaders: source.headers, profile: profile,
                               selectTitleID: source.discTitleID)
            }
            let index = format.streamIndex
            guard demux.isSourceSeekable, let stream = demux.stream(at: index),
                  stream.pointee.codecpar?.pointee.codec_id == format.parameters.ptr.pointee.codec_id,
                  stream.pointee.time_base.num == format.timeBase.num,
                  stream.pointee.time_base.den == format.timeBase.den else { return }
            packets.configure(stream: stream, epoch: 0)
            demux.discardAllStreamsExcept([index])
            let scale = Double(format.timeBase.num) / Double(format.timeBase.den)
            let offset = Double(sourceOffset) * scale
            let seekIndex = demux.videoStreamIndex >= 0 ? demux.videoStreamIndex : index
            guard demux.seekBounded(to: start - offset, anchorStreamIndex: seekIndex, timeout: 3) else {
                outcome = "seekFailed"
                EngineLog.emit("[AudioTap] lookahead seek unavailable source=\(start)", category: .engine)
                return
            }
            lock.withLock { phase = "reading" }
            EngineLog.emit("[AudioTap] lookahead started source=\(start) stream=\(index)", category: .engine)
            var frontier = start
            var validateLanding: Double? = start
            var landingBudgetArmed = false
            defer {
                if landingBudgetArmed { demux.endReadDeadline(); demux.endInputByteBudget() }
            }
            while let demand = waitForDemand(frontier: frontier) {
                // If primary data carried recognition ahead while this source slept, seek the
                // missing interval. Never scan the intervening video to catch up.
                if demand - frontier > 3, validateLanding == nil {
                    guard demux.seekBounded(to: demand - offset, anchorStreamIndex: seekIndex, timeout: 3) else {
                        outcome = "seekFailed"
                        return
                    }
                    frontier = demand
                    validateLanding = demand
                }
                if validateLanding != nil, !landingBudgetArmed {
                    demux.beginInputByteBudget(8 * 1024 * 1024)
                    demux.beginReadDeadline(secondsFromNow: 3)
                    landingBudgetArmed = true
                }
                guard let read = try demux.readPacket() else {
                    outcome = landingBudgetArmed ? "landingFailed" : "eof"
                    if !landingBudgetArmed { packets.finish() }
                    return
                }
                var packet: UnsafeMutablePointer<AVPacket>? = read
                defer { trackedPacketFree(&packet) }
                guard read.pointee.stream_index == index else { continue }
                let pts = read.pointee.pts != Int64.min ? read.pointee.pts : read.pointee.dts
                if let expected = validateLanding {
                    guard pts != Int64.min else { continue }
                    let actual = Double(pts) * scale + offset
                    // Some incomplete indices claim success and land back at byte zero. Give the
                    // decoder a short preroll, but never scan a feature-length remux to reach a seek.
                    guard actual >= expected - 20, actual <= expected + 4 else {
                        outcome = "landingRejected"
                        EngineLog.emit("[AudioTap] lookahead landing rejected target=\(expected) source=\(actual)", category: .engine)
                        return
                    }
                    if actual < expected - 0.25 { continue }
                    validateLanding = nil
                    demux.endReadDeadline()
                    demux.endInputByteBudget()
                    landingBudgetArmed = false
                }
                if pts != Int64.min { frontier = max(frontier, Double(pts) * scale + offset) }
                packets.append(read, offset: sourceOffset)
            }
        } catch {
            outcome = "readFailed"
            EngineLog.emit("[AudioTap] lookahead stopped code=\((error as NSError).code)", category: .engine)
        }
    }

    private func waitForDemand(frontier: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        while !stopped, frontier >= requestedEnd {
            phase = "atTarget"
            lock.wait()
        }
        if !stopped { phase = "reading" }
        return stopped ? nil : requestedStart
    }
}

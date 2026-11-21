import AVFAudio
import XCTest
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

final class AudioPacketTapTests: XCTestCase {
    private final class BlockingCloneReader: IOReader, @unchecked Sendable {
        let child: BlockingCloneReader?
        let reading = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        private let releaseRead = DispatchSemaphore(value: 0)
        var discImageProbeEnabled: Bool { false }

        init(child: BlockingCloneReader? = nil) { self.child = child }
        func makeIndependentReader() -> IOReader? { child }
        func seek(offset: Int64, whence: Int32) -> Int64 { whence == 65536 ? 10_000 : offset }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            reading.signal()
            _ = releaseRead.wait(timeout: .now() + 3)
            return -1
        }
        func cancel() { releaseRead.signal() }
        func close() { closed.signal() }
    }

    @MainActor
    func testSeekDropsQueuedPCMAndEOFDeliversTheTail() async throws {
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat, frameCapacity: 160))
        pcm.frameLength = 160
        let buffer = AudioTapBuffer(buffer: pcm, sourceTime: 80, discontinuity: true)

        let departing = AudioTapController()
        var discarded = departing.makeStream { stop in stop {} }.makeAsyncIterator()
        departing.makeYield()?(buffer)
        departing.teardown()
        let old = await discarded.next()
        XCTAssertNil(old)

        let current = AudioTapController()
        var finishing = current.makeStream { stop in stop {} }.makeAsyncIterator()
        current.makeYield()?(buffer.restamped(sourceTime: 12, discontinuity: true))
        current.finishInput()
        let tail = await finishing.next()
        let end = await finishing.next()
        XCTAssertEqual(tail?.sourceTime, 12)
        XCTAssertNil(end)
    }

    private func withStream(_ run: (UnsafeMutablePointer<AVStream>) throws -> Void) throws {
        let context = try XCTUnwrap(avformat_alloc_context())
        defer { avformat_free_context(context) }
        let stream = try XCTUnwrap(avformat_new_stream(context, nil))
        stream.pointee.time_base = AVRational(num: 1, den: 16_000)
        let params = try XCTUnwrap(stream.pointee.codecpar)
        params.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        params.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
        params.pointee.sample_rate = 16_000
        av_channel_layout_default(&params.pointee.ch_layout, 1)
        try run(stream)
    }

    private func append(_ window: AudioPacketWindow, seconds: Double, index: Int32 = 0,
                        offset: Int64 = 0, epoch: UInt64 = 1, replay: Bool = false) throws {
        let packet = try XCTUnwrap(av_packet_alloc())
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&owned) }
        XCTAssertGreaterThanOrEqual(av_new_packet(packet, 3_200), 0)
        memset(packet.pointee.data, 0, 3_200)
        packet.pointee.stream_index = index
        packet.pointee.pts = Int64((seconds * 16_000).rounded())
        packet.pointee.dts = packet.pointee.pts
        packet.pointee.duration = 1_600
        window.append(packet, offset: offset, epoch: epoch, replay: replay)
    }

    func testEvictedPacketCanReplayWithNonzeroOffset() throws {
        try withStream { stream in
            let window = AudioPacketWindow(deduplicatesReplay: true)
            window.configure(stream: stream, epoch: 1)
            try append(window, seconds: 1, offset: 16_000)
            try append(window, seconds: 130, offset: 16_000)
            try append(window, seconds: 1, offset: 16_000, replay: true)
            let version = try XCTUnwrap(window.format?.version)
            var cursor = AudioPacketWindow.Cursor()
            XCTAssertEqual(window.next(cursor: &cursor, from: 1.9, through: 2.2, version: version)?.start, 2)
        }
    }

    func testSeekRetiresProducerAndFindsEarlierPacketsBehindItsForwardTail() throws {
        try withStream { stream in
            let window = AudioPacketWindow()
            window.configure(stream: stream, epoch: 1)
            try append(window, seconds: 1)
            try append(window, seconds: 80)
            let version = try XCTUnwrap(window.format?.version)
            var forward = AudioPacketWindow.Cursor()
            XCTAssertEqual(window.next(cursor: &forward, from: 79.9, through: 80.5, version: version)?.start, 80)

            window.configure(stream: stream, epoch: 2)
            var backward = AudioPacketWindow.Cursor()
            XCTAssertNil(window.next(cursor: &backward, from: 11.75, through: 12.75, version: version))
            try append(window, seconds: 12.1, epoch: 1)
            XCTAssertNil(window.next(cursor: &backward, from: 11.75, through: 12.75, version: version))
            try append(window, seconds: 12, epoch: 2)
            XCTAssertEqual(window.next(cursor: &backward, from: 11.75, through: 12.75, version: version)?.start, 12)
        }
    }

    func testEOFAfterEmptyOrShortAudioTrackAndSeekBackFromEnd() throws {
        try withStream { stream in
            let window = AudioPacketWindow()
            window.configure(stream: stream, epoch: 1)
            window.finish(epoch: 1)
            XCTAssertTrue(window.hasEnded(at: 90))
            try append(window, seconds: 10)
            window.finish(epoch: 1)
            XCTAssertFalse(window.hasEnded(at: 0))
            XCTAssertTrue(window.hasEnded(at: 10))
            XCTAssertTrue(window.hasEnded(at: 90))
            window.setPlaybackEnded(true)
            XCTAssertTrue(window.hasEnded(at: 0))
            window.setPlaybackEnded(false)
            XCTAssertFalse(window.hasEnded(at: 0))
        }
    }

    func testSteadyLowLeadRequestsRefillAndStopsAtHighWater() {
        var refill = AudioTapRefill()
        for tick in 0..<7 {
            XCTAssertFalse(refill.needsLookahead(lead: 0.107, now: Double(tick) * 0.05))
        }
        XCTAssertTrue(refill.needsLookahead(lead: 0.107, now: 0.36))
        XCTAssertTrue(refill.needsLookahead(lead: 34, now: 0.5))
        XCTAssertFalse(refill.needsLookahead(lead: 45.01, now: 0.7))
        XCTAssertFalse(refill.needsLookahead(lead: 33, now: 12.7))
    }

    func testSeekCancellationInterruptsAndClosesOnlyTheSideReaderClone() throws {
        let clone = BlockingCloneReader()
        let original = BlockingCloneReader(child: clone)
        try withStream { stream in
            let window = AudioPacketWindow()
            window.configure(stream: stream, epoch: 1)
            let source = AudioPacketLookahead.Source(url: URL(fileURLWithPath: "/test.wav"),
                                                     reader: original, formatHint: "wav", headers: [:],
                                                     headerStore: RequestHeaderStore([:]), probeSize: nil,
                                                     analyzeDuration: nil, discTitleID: nil)
            let side = AudioPacketLookahead(source: source, format: try XCTUnwrap(window.format), sourceOffset: 0)
            side.request(from: 10, through: 55)
            XCTAssertEqual(clone.reading.wait(timeout: .now() + 2), .success)
            side.stop()
            XCTAssertEqual(clone.closed.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(original.closed.wait(timeout: .now()), .timedOut)
        }
    }

    func testIndependentReaderBuildsLeadWhilePlaybackSuppliesRealtimePackets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeWave(at: url)
        let demux = Demuxer()
        defer { demux.close() }
        try demux.open(url: url)
        let index = demux.audioStreamIndex
        let stream = try XCTUnwrap(demux.stream(at: index))
        let timeBase = stream.pointee.time_base
        let scale = Double(timeBase.num) / Double(timeBase.den)
        let shift = Int64((590 / scale).rounded())
        let packets = AudioPacketWindow()
        packets.configure(stream: stream, epoch: 1)
        XCTAssertTrue(demux.seekBounded(to: 9.956, anchorStreamIndex: index, timeout: 3))
        func feedNextPacket() throws {
            var packet = try demux.readPacket()
            defer { trackedPacketFree(&packet) }
            packets.append(try XCTUnwrap(packet), offset: shift, epoch: 1)
        }
        try feedNextPacket()
        let anchor = 599.956
        let head = AtomicDouble(anchor)
        let deliveredEnd = AtomicDouble(anchor)
        let source = AudioPacketLookahead.Source(url: url, reader: nil, formatHint: nil, headers: [:],
                                                 headerStore: RequestHeaderStore([:]), probeSize: nil,
                                                 analyzeDuration: nil, discTitleID: nil)
        let tap = AudioPacketTap(packets: packets, channels: .downmix, start: anchor, playhead: head, source: source,
                                 yield: { buffer in
            deliveredEnd.set(buffer.sourceTime + Double(buffer.buffer.frameLength) / buffer.buffer.format.sampleRate)
        }, finish: {})
        tap.begin()
        defer { tap.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - started < 5 {
            let playhead = anchor + ProcessInfo.processInfo.systemUptime - started
            head.set(playhead)
            if (packets.latestSourceEnd ?? anchor) <= playhead + 0.03 { try feedNextPacket() }
            if deliveredEnd.get() - playhead >= 44.5 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let metrics = tap.progress
        XCTAssertLessThan(try XCTUnwrap(metrics.primarySourceEnd) - head.get(), 0.5)
        XCTAssertGreaterThan(deliveredEnd.get() - head.get(), 44, "lookahead state \(metrics.lookaheadState)")
        XCTAssertLessThan(deliveredEnd.get() - head.get(), metrics.targetLeadSeconds + 0.3)
        XCTAssertGreaterThan(try XCTUnwrap(metrics.lookaheadSourceEnd) - head.get(), 44)
    }

    private func makeWave(at url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                 channels: 1, interleaved: true))
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        memset(try XCTUnwrap(buffer.int16ChannelData)[0], 0, 32_000)
        for _ in 0..<75 { try file.write(from: buffer) }
    }

    func testTrackSwitchRejectsOldDescriptorsAndForeignPackets() throws {
        try withStream { stream in
            let window = AudioPacketWindow()
            window.configure(stream: stream, epoch: 1)
            try append(window, seconds: 4)
            let original = try XCTUnwrap(window.format)
            stream.pointee.index = 1
            window.configure(stream: stream, epoch: 2)
            let current = try XCTUnwrap(window.format)
            XCTAssertNotEqual(original.version, current.version)
            var cursor = AudioPacketWindow.Cursor()
            try append(window, seconds: 4.1, epoch: 2)
            XCTAssertNil(window.next(cursor: &cursor, from: 3.9, through: 4.5, version: current.version))
            try append(window, seconds: 4.2, index: 1, epoch: 2)
            XCTAssertNil(window.next(cursor: &cursor, from: 3.9, through: 4.5, version: original.version))
            XCTAssertEqual(window.next(cursor: &cursor, from: 3.9, through: 4.5, version: current.version)?.start, 4.2)
        }
    }

    func testSourceOffsetMapsToDecodedPCMAndSeekFloorClipsToSample() throws {
        try withStream { stream in
            let window = AudioPacketWindow()
            window.configure(stream: stream, epoch: 1)
            try append(window, seconds: 11, offset: 16_000)
            let format = try XCTUnwrap(window.format)
            var cursor = AudioPacketWindow.Cursor()
            let packet = try XCTUnwrap(window.next(cursor: &cursor, from: 11.99, through: 12.5,
                                                   version: format.version))
            XCTAssertEqual(packet.pointer.pointee.pts, 192_000)
            let decoder = AudioTapDecoder()
            try decoder.open(parameters: format.parameters.ptr, timeBase: format.timeBase)
            let chunk = try XCTUnwrap((decoder.decode(packet: packet.pointer) + decoder.drain()).first)
            XCTAssertEqual(chunk.ptsSeconds, 12, accuracy: 1 / 16_000)
            let clipped = try XCTUnwrap(AudioPacketTap.clip(chunk, to: 12.0625))
            XCTAssertEqual(clipped.sourceTime, 12.0625, accuracy: 1 / 16_000)
            XCTAssertEqual(clipped.buffer.format.sampleRate, 16_000)
            XCTAssertEqual(clipped.buffer.format.channelCount, 1)
            XCTAssertEqual(clipped.buffer.frameLength, 600)
            XCTAssertNil(AudioPacketTap.clip(chunk, to: 13))
        }
    }

    func testSourceRoundingKeepsAdjacentSamplesAndTrimsRealOverlap() throws {
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat, frameCapacity: 1_600))
        pcm.frameLength = 1_600
        let chunk = AudioTapChunk(buffer: pcm, ptsSeconds: 599.956)
        let adjacent = try XCTUnwrap(AudioPacketTap.clip(chunk, to: chunk.ptsSeconds.nextUp))
        XCTAssertEqual(adjacent.buffer.frameLength, 1_600)
        XCTAssertEqual(adjacent.sourceTime, chunk.ptsSeconds.nextUp)
        let overlap = chunk.ptsSeconds + 700.0 / 16_000
        let trimmed = try XCTUnwrap(AudioPacketTap.clip(chunk, to: overlap.nextUp))
        XCTAssertEqual(trimmed.buffer.frameLength, 900)
        XCTAssertEqual(trimmed.sourceTime, overlap.nextUp)
        let fractional = try XCTUnwrap(AudioPacketTap.clip(chunk, to: chunk.ptsSeconds + 700.1 / 16_000))
        XCTAssertEqual(fractional.buffer.frameLength, 899)
        XCTAssertEqual(fractional.sourceTime, chunk.ptsSeconds + 701.0 / 16_000)
    }

    func testManyAdjacentChunksAtNonzeroOriginPreserveEverySample() throws {
        let origin = 599.956
        let frames = 1_711
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat,
                                                  frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = pcm.frameCapacity
        var clock = AudioTapOutputClock()
        for index in 0..<25_000 {
            let start = origin + Double(index * frames) / 16_000
            let previous = clock.deliveredEnd ?? origin
            let chunk = AudioTapChunk(buffer: pcm, ptsSeconds: start)
            let current = try XCTUnwrap(clock.accept(chunk, landing: origin, discontinuity: index == 0))
            guard current.buffer.frameLength == frames, current.sourceTime >= previous else {
                return XCTFail("lost samples or overlapping timestamps at chunk \(index)")
            }
        }
        XCTAssertEqual(try XCTUnwrap(clock.deliveredEnd), origin + Double(25_000 * frames) / 16_000,
                       accuracy: 0.5 / 16_000)
    }

    func testMalformedPacketPreservesTailAndReanchorsAtNextGoodFrame() throws {
        try withStream { stream in
            let decoder = AudioTapDecoder()
            try decoder.open(stream: stream)
            func decode(at pts: Int64, bytes: Int32) throws -> [AudioTapChunk] {
                let packet = try XCTUnwrap(av_packet_alloc())
                var owned: UnsafeMutablePointer<AVPacket>? = packet
                defer { av_packet_free(&owned) }
                XCTAssertGreaterThanOrEqual(av_new_packet(packet, bytes), 0)
                memset(packet.pointee.data, 0, Int(bytes))
                packet.pointee.pts = pts
                packet.pointee.dts = pts
                return decoder.decode(packet: packet)
            }
            let origin: Int64 = 9_600_000
            XCTAssertTrue(try decode(at: origin, bytes: 1_600).isEmpty)
            let tail = try XCTUnwrap(try decode(at: origin + 800, bytes: 1).first)
            XCTAssertEqual(tail.buffer.frameLength, 800)
            XCTAssertFalse(tail.discontinuity)
            let resumed = try XCTUnwrap(try decode(at: origin + 1_312, bytes: 3_200).first)
            XCTAssertEqual(resumed.ptsSeconds, Double(origin + 1_312) / 16_000, accuracy: 1e-9)
            XCTAssertTrue(resumed.discontinuity)
            let next = try XCTUnwrap(try decode(at: origin + 2_912, bytes: 3_200).first)
            XCTAssertFalse(next.discontinuity)
        }
    }

    // SVPlayer modification (2026-11-21): Regression tests for backward-seek head eviction (N-17)
    // and condition-signaled paused AudioPacketTap wakeups (M-12).
    func testBackwardSeekEvictsFarFutureHeadPacketsAndAllowsReplay() throws {
        try withStream { stream in
            let window = AudioPacketWindow(deduplicatesReplay: true)
            window.configure(stream: stream, epoch: 1, sameSourceAcrossEpochs: true)
            try append(window, seconds: 500, offset: 0, epoch: 1)
            let version = try XCTUnwrap(window.format?.version)

            // Backward seek to 10s on the same source (epoch 2): oldest packet at 500s (>120s ahead) must be evicted.
            window.configure(stream: stream, epoch: 2, sameSourceAcrossEpochs: true)
            try append(window, seconds: 10, offset: 0, epoch: 2)
            var backCursor = AudioPacketWindow.Cursor()
            XCTAssertEqual(window.next(cursor: &backCursor, from: 9.9, through: 10.5, version: version)?.start, 10)
            XCTAssertNil(window.next(cursor: &backCursor, from: 499.9, through: 500.5, version: version))

            // Forward seek back to 500s (epoch 3): evicted 500s packet can be replayed cleanly.
            window.configure(stream: stream, epoch: 3, sameSourceAcrossEpochs: true)
            try append(window, seconds: 500, offset: 0, epoch: 3, replay: true)
            var forwardCursor = AudioPacketWindow.Cursor()
            XCTAssertEqual(window.next(cursor: &forwardCursor, from: 499.9, through: 500.5, version: version)?.start, 500)
        }
    }

    func testPausedTapSleepsOnWakeSignalAndWakesImmediatelyOnPlayheadAdvanceOrStop() throws {
        try withStream { stream in
            let packets = AudioPacketWindow(deduplicatesReplay: true)
            packets.configure(stream: stream, epoch: 1, sameSourceAcrossEpochs: true)
            for tenth in 0..<700 {
                try append(packets, seconds: Double(tenth) * 0.1, epoch: 1)
            }
            let head = AtomicDouble(0)
            let deliveredEnd = AtomicDouble(0)
            // SVPlayer modification (2026-11-21): Await worker thread exit via finish semaphore when timing stop().
            let finished = DispatchSemaphore(value: 0)
            let tap = AudioPacketTap(
                packets: packets,
                channels: .downmix,
                start: 0,
                playhead: head,
                source: nil,
                yield: { buffer in
                    deliveredEnd.set(buffer.sourceTime + Double(buffer.buffer.frameLength) / buffer.buffer.format.sampleRate)
                },
                // SVPlayer modification (2026-11-21): Signal semaphore when AudioPacketTap worker thread exits.
                finish: {
                    finished.signal()
                }
            )
            tap.begin()
            defer { tap.stop() }

            let fillDeadline = ProcessInfo.processInfo.systemUptime + 3.0
            while deliveredEnd.get() < 44.8 && ProcessInfo.processInfo.systemUptime < fillDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertGreaterThanOrEqual(deliveredEnd.get(), 44.8)

            // Let worker park on AudioTapWakeSignal (which sleeps up to 2.0s unless signaled).
            Thread.sleep(forTimeInterval: 0.05)

            let wakeStart = ProcessInfo.processInfo.systemUptime
            head.set(15.0)
            while deliveredEnd.get() < 59.5 && ProcessInfo.processInfo.systemUptime - wakeStart < 1.5 {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let wakeElapsed = ProcessInfo.processInfo.systemUptime - wakeStart
            XCTAssertGreaterThanOrEqual(deliveredEnd.get(), 59.5)
            XCTAssertLessThan(wakeElapsed, 0.5, "Playhead change must wake paused tap without waiting out idle sleep")

            Thread.sleep(forTimeInterval: 0.05)
            // SVPlayer modification (2026-11-21): Measure actual worker exit via finish callback rather than non-blocking stop() return.
            let stopStart = ProcessInfo.processInfo.systemUptime
            tap.stop()
            let waitResult = finished.wait(timeout: .now() + 0.5)
            let stopElapsed = ProcessInfo.processInfo.systemUptime - stopStart
            XCTAssertEqual(waitResult, .success, "AudioPacketTap worker thread must invoke finish promptly on stop()")
            XCTAssertLessThan(stopElapsed, 0.25, "stop() must wake parked AudioPacketTap worker and exit immediately")
        }
    }
}

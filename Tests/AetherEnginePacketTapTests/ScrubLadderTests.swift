import CoreGraphics
import Foundation
import XCTest
@testable import AetherEngine

final class ScrubLadderTests: XCTestCase {
    func testDecodedRungIsReadyWithoutIOAndUsesItsOwnTime() throws {
        let rung = try whiteRung()
        XCTAssertNil(rung.decodedThumbnail(isCancelled: { true }))
        let frame = try XCTUnwrap(rung.decodedThumbnail(isCancelled: { false }))
        XCTAssertEqual(frame.image.width, 32)
        XCTAssertEqual(frame.image.height, 18)
        XCTAssertGreaterThan(try intensity(of: frame.image), 230)
        XCTAssertEqual(frame.source, .ladder)
        XCTAssertEqual(frame.actualSeconds, 1738)
        XCTAssertEqual(frame.validRange, 1738..<1742)
        XCTAssertFalse(frame.isRefined(at: 1738))
        let cache = ReadyScrubFrames(byteLimit: 1024 * 1024)
        cache.insert(frame)
        let ready = try XCTUnwrap(cache.nearest(to: 1700))
        XCTAssertIdentical(frame.image, ready.image)
        let displayed = ready.shifted(by: 604 - 600)
        XCTAssertEqual(displayed.actualSeconds, 1742)
        XCTAssertEqual(displayed.validRange, 1742..<1746)
    }

    func testNearestInEitherDirectionAndDecodedByteBudget() throws {
        let frame = try XCTUnwrap(try whiteRung().decodedThumbnail(isCancelled: { false }))
        let cache = ReadyScrubFrames(byteLimit: 2 * frame.image.height * frame.image.bytesPerRow)
        cache.insert(frame)
        cache.insert(frame.shifted(by: 30))
        XCTAssertEqual(cache.nearest(to: 1760)?.actualSeconds, 1768)
        XCTAssertEqual(cache.nearest(to: 1753)?.actualSeconds, 1738)
        XCTAssertNil(cache.nearest(to: .nan))
        cache.insert(frame.shifted(by: 60))
        XCTAssertEqual(cache.nearest(to: 1738)?.actualSeconds, 1768)
        XCTAssertEqual(KeyframeStillLadder.answeringRung(for: 1760, segmentStarts: [1738, 1768], cached: [0, 1]), 1)
        let precise = ScrubFrame(image: frame.image, actualSeconds: 1738.05, refined: true, validRange: 1738..<1742)
        XCTAssertTrue(precise.isRefined(at: 1738))
        XCTAssertTrue(precise.isRefined(at: precise.actualSeconds - 1.99))
        XCTAssertFalse(precise.isRefined(at: precise.actualSeconds - 2))
        XCTAssertFalse(precise.isRefined(at: 1741))
        XCTAssertNil(KeyframeStillLadder.answeringRung(for: 1707.99, segmentStarts: [1738], cached: [0]))
        XCTAssertEqual(KeyframeStillLadder.answeringRung(for: 1708, segmentStarts: [1738], cached: [0]), 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payloads = IFramePayloadCache(directory: directory, byteLimit: 8)
        defer { payloads.removeAll() }
        payloads.store(Data(repeating: 1, count: 9), for: 0)
        XCTAssertNil(payloads.payload(for: 0))
        payloads.store(Data(repeating: 1, count: 6), for: 1)
        payloads.store(Data(repeating: 2, count: 6), for: 2)
        XCTAssertNil(payloads.payload(for: 1))
        XCTAssertEqual(payloads.payload(for: 2), Data(repeating: 2, count: 6))
    }

    func testPrefetchOnlyUsesNearbyGridWithoutScanningTheTitle() {
        let starts = (0..<1440).map { Double($0 * 5) }
        for playhead in [0.0, 600, 617.25, 1800, 7199.9] {
            let rungs = KeyframeStillLadder.nearbyRungs(segmentStarts: starts, totalSeconds: 7200, playheadSeconds: playhead)
            let times = rungs.map { starts[$0] }
            XCTAssertFalse(rungs.isEmpty)
            XCTAssertLessThanOrEqual(rungs.count, 10)
            XCTAssertEqual(Set(rungs).count, rungs.count)
            XCTAssertTrue(times.allSatisfy { abs($0 - playhead) <= 120 })
            XCTAssertEqual(times.map { abs($0 - playhead) }, times.map { abs($0 - playhead) }.sorted())
            if playhead == 600 { XCTAssertEqual(times.sorted(), Array(stride(from: 500.0, through: 700.0, by: 25))) }
        }
        let sparse = KeyframeStillLadder.nearbyRungs(segmentStarts: [0, 591, 934], totalSeconds: 1000, playheadSeconds: 600)
        XCTAssertEqual(sparse, [1])
    }

    func testFingerReadsOnlyItsChosenIndexAndRefinementPreemptsTheSameReader() throws {
        let plan = (0..<20).map { (index: Int) -> HLSVideoEngine.Segment in
            let start = Int64(index) * 4000
            return .init(startPts: start, endPts: start + 4000, startSeconds: Double(index) * 4, durationSeconds: 4)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let entered = DispatchSemaphore(value: 0)
        let interrupted = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let trace = ScrubReadTrace()
        let rendition = IFrameRendition(entries: plan.map {
            .init(startPts: $0.startPts, startSeconds: $0.startSeconds, durationSeconds: $0.durationSeconds)
        }, cache: IFramePayloadCache(directory: directory), readPayload: { entry, token in
            trace.enter("rung:\(entry.startPts)")
            defer { trace.leave() }
            if entry.startPts == 40_000, let token {
                token.withInterruption({ interrupted.signal() }) {
                    entered.signal()
                    _ = interrupted.wait(timeout: .now() + 2)
                }
                return nil
            }
            return Data([UInt8(entry.startPts / 4000)])
        }, refine: { seconds, _, _ in
            trace.enter("refined:\(seconds)")
            trace.leave()
            return nil
        }, buildFragment: { _, _, _ in nil })
        defer { rendition.shutdown() }
        var finger = ScrubLadderFinger()
        let first = ProbeCancellation()
        XCTAssertTrue(finger.move(to: 41.25, in: plan).isEmpty)
        let index = try XCTUnwrap(finger.beginRung(at: 41.25, using: first))
        XCTAssertEqual(index, 10)
        DispatchQueue.global().async {
            _ = rendition.keyframePayload(at: index, cancellation: first)
            completed.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(finger.move(to: 43.99, in: plan).isEmpty)
        XCTAssertNil(finger.beginRung(at: 43.99, using: ProbeCancellation()))
        let precise = ProbeCancellation()
        let (accepted, obsolete) = finger.beginRefinement(at: 43.99, using: precise)
        XCTAssertTrue(accepted)
        XCTAssertIdentical(obsolete, first)
        DispatchQueue.global().async {
            _ = rendition.refinedFrame(at: 43.99, maxWidth: 320, cancellation: precise)
            completed.signal()
        }
        obsolete?.cancel()
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        finger.finish(precise)
        XCTAssertTrue(finger.move(to: 66.5, in: plan).isEmpty)
        let next = ProbeCancellation()
        let nextIndex = try XCTUnwrap(finger.beginRung(at: 66.5, using: next))
        XCTAssertEqual(nextIndex, 16)
        XCTAssertEqual(rendition.keyframePayload(at: nextIndex, cancellation: next), Data([16]))
        XCTAssertEqual(rendition.keyframePayload(at: nextIndex, cancellation: next), Data([16]))
        let old = finger.move(to: 31, in: plan)
        XCTAssertIdentical(old.first, next)
        old.forEach { $0.cancel() }
        XCTAssertTrue(next.isCancelled)
        XCTAssertEqual(trace.events, ["rung:40000", "refined:43.99", "rung:64000"])
        XCTAssertEqual(trace.maximumConcurrentReads, 1)
    }

    func testRealSourceRefinementDecodesNonKeyframeAndReusesTheRungReader() throws {
        let fixture = try whiteRung()
        let trace = ScrubReadTrace()
        let reader = IFrameSideReader(open: { dem in
            trace.enter("open")
            defer { trace.leave() }
            try dem.open(reader: fixture.makeReader(), formatHint: "mp4", profile: .iFrameSideDemuxer)
        })
        defer { reader.close() }
        let cancelled = ProbeCancellation()
        cancelled.cancel()
        XCTAssertNil(reader.refinedFrame(at: 0.95, maxWidth: 32, cancellation: cancelled))
        XCTAssertTrue(trace.events.isEmpty)
        XCTAssertNotNil(reader.payload(startPts: 0))
        let refined = try XCTUnwrap(reader.refinedFrame(at: 0.95, maxWidth: 32, cancellation: ProbeCancellation()))
        XCTAssertEqual(refined.source, .sourceRead)
        XCTAssertEqual(refined.actualSeconds, 1, accuracy: 0.001)
        XCTAssertTrue(refined.isRefined(at: 0.95))
        XCTAssertLessThan(try intensity(of: refined.image), 25)
        let earlier = try XCTUnwrap(reader.refinedFrame(at: 0.25, maxWidth: 32, cancellation: ProbeCancellation()))
        XCTAssertEqual(earlier.actualSeconds, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(try intensity(of: earlier.image), 230)
        XCTAssertEqual(trace.events, ["open"])
    }

    private func intensity(of image: CGImage) throws -> UInt8 {
        var pixel: UInt8 = 0
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel
    }

    private func whiteRung() throws -> HLSVideoEngine.StillLadderFrame {
        // White I-frame at zero, then a white P-frame at 0.5 and black P-frames at 1.0 and 1.5.
        let fixture = try XCTUnwrap(Data(base64Encoded: """
        AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAAAvdtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAAAABAAABAAAAAAAAAAAA
        AAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACHnRyYWsAAABc
        dGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAA
        AAAAIAAAABIAAAAAAbptZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAAEAAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAA
        AAAAAFZpZGVvSGFuZGxlcgAAAAFlbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAA
        AAABAAABJXN0YmwAAADZc3RzZAAAAAAAAAABAAAAyW1wNHYAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAIAASAEgAAABIAAAAAAAAAAEK
        TGF2YyBtcGVnNAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAY//8AAABPZXNkcwAAAAADgICAPgABAASAgIAwIBEAAAAAAw1AAAMNQAWAgIAe
        AAABsAEAAAG1iRMAAAEAAAABIADEjYgAFQEEAlRjBoCAgAECAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAADDUAAAw1AAAAAEHN0
        dHMAAAAAAAAAAAAAABBzdHNjAAAAAAAAAAAAAAAUc3RzegAAAAAAAAAAAAAAAAAAABBzdGNvAAAAAAAAAAAAAAAobXZleAAAACB0cmV4
        AAAAAAAAAAEAAAABAAAAAAAAAAAAAAAAAAAAPXVkdGEAAAA1bWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAA
        AAAIaWxzdAAAAHhtb29mAAAAEG1maGQAAAAAAAAAAQAAAGB0cmFmAAAAHHRmaGQAAgA4AAAAAQAAIAAAAAAaAQEAAAAAABR0ZmR0AQAA
        AAAAAAAAAAAAAAAAKHRydW4AAAIFAAAABAAAAIACAAAAAAAAGgAAAAcAAAAWAAAABwAAAEZtZGF0AAABswAQBwAAAbYWBRg6238bbfxt
        t/G2378AAAG2XwI+AAABtmsBEMYI9t+GNtvwxtt+GNtv3wAAAbZfAj4=
        """, options: .ignoreUnknownCharacters))
        let moof = try XCTUnwrap(fixture.range(of: Data("moof".utf8))).lowerBound - 4
        return .init(segmentIndex: 434, startSeconds: 1738, durationSeconds: 4,
                     initData: fixture.prefix(moof), fragment: fixture.suffix(from: moof))
    }
}

private final class ScrubReadTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private var recorded = [String]()

    func enter(_ event: String) {
        lock.withLock {
            active += 1
            maximum = max(maximum, active)
            recorded.append(event)
        }
    }

    func leave() { lock.withLock { active -= 1 } }
    var events: [String] { lock.withLock { recorded } }
    var maximumConcurrentReads: Int { lock.withLock { maximum } }
}

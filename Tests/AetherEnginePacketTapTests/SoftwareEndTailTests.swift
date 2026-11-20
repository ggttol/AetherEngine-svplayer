import XCTest
@testable import AetherEngine

final class SoftwareEndTailTests: XCTestCase {
    func testIPadResumeFinishesAtTheLastQueuedSample() throws {
        var tail = try XCTUnwrap(SoftwareEndOfMediaClock.PendingTail(clock: 11.203, audioEnd: 12,
                                                                    videoPTS: 11.958, now: 0))
        XCTAssertEqual(tail.target, 12, accuracy: 0.001)
        XCTAssertFalse(tail.shouldFinish(clock: 11.203, playing: true, now: 0.01))
        XCTAssertFalse(tail.shouldFinish(clock: 11.6, playing: true, now: 1.5))
        XCTAssertTrue(tail.shouldFinish(clock: 12.01, playing: true, now: 2.3))
    }

    func testPausedTailWaitsForPlaybackAcrossLongPause() throws {
        var tail = try XCTUnwrap(SoftwareEndOfMediaClock.PendingTail(clock: 11.203, audioEnd: 11.8,
                                                                    videoPTS: 11.958, now: 0))
        XCTAssertEqual(tail.target, 11.958, accuracy: 0.001)
        XCTAssertFalse(tail.shouldFinish(clock: 11.4, playing: false, now: 90))
        tail.resumed(now: 90)
        XCTAssertFalse(tail.shouldFinish(clock: 11.4, playing: true, now: 90.25))
        XCTAssertTrue(tail.shouldFinish(clock: 11.96, playing: true, now: 90.81))
    }

    func testVideoOnlyTailAndDamagedTimestampAreBounded() throws {
        var tail = try XCTUnwrap(SoftwareEndOfMediaClock.PendingTail(clock: 11.203, audioEnd: .nan,
                                                                    videoPTS: 900_000, now: 0))
        XCTAssertEqual(tail.target, 11.203 + SoftwareEndOfMediaClock.maxTailPlayoutSeconds, accuracy: 0.001)
        XCTAssertFalse(tail.shouldFinish(clock: 11.203, playing: true, now: 0.5))
        XCTAssertTrue(tail.shouldFinish(clock: 11.203, playing: true, now: 5.5))
    }

    func testAlreadyPlayedOrMissingTimestampsFinishImmediately() {
        XCTAssertNil(SoftwareEndOfMediaClock.PendingTail(clock: 12, audioEnd: 12, videoPTS: 11.958, now: 0))
        XCTAssertNil(SoftwareEndOfMediaClock.PendingTail(clock: 0, audioEnd: .nan, videoPTS: nil, now: 0))
    }
}

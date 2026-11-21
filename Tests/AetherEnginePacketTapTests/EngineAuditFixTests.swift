// SVPlayer modification (2026-11-21): Regression tests for foreground restore rollback/autoplay (C-01/N-01),
// wireless AirPlay & PiP background video keepalive (N-02), and DeinterlaceMode.off (D-03).
import XCTest
import AetherLibavutil
@testable import AetherEngine

final class EngineAuditFixTests: XCTestCase {
    func testWirelessAirPlayAndPiPKeepVideoAliveWhenBackgroundAudioDisabled() {
        XCTAssertTrue(
            AetherEngine.shouldKeepVideoAlive(
                enabled: false,
                pipActive: false,
                externalPlaybackActive: true,
                state: .playing
            )
        )
        XCTAssertTrue(
            AetherEngine.shouldKeepVideoAlive(
                enabled: false,
                pipActive: false,
                externalPlaybackActive: true,
                state: .paused
            )
        )
        XCTAssertTrue(
            AetherEngine.shouldKeepVideoAlive(
                enabled: false,
                pipActive: true,
                externalPlaybackActive: false,
                state: .playing
            )
        )
        XCTAssertFalse(
            AetherEngine.shouldKeepVideoAlive(
                enabled: false,
                pipActive: false,
                externalPlaybackActive: false,
                state: .playing
            )
        )
        XCTAssertTrue(AetherEngine.shouldKeepVideoAliveTV(enabled: false, pipActive: true))
        XCTAssertFalse(AetherEngine.shouldKeepVideoAliveTV(enabled: false, pipActive: false))
    }

    @MainActor
    func testForegroundReloadRollsBackSelectionOnFailureAndRespectsExplicitAutoplay() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }

        engine.loadedURL = URL(fileURLWithPath: "/nonexistent/restore-fail-\(UUID().uuidString).mkv")
        engine.setLoadedAutoplay(true)
        engine.restoreReloadSelection(
            BackgroundTeardownSelection(
                audioTrackIndex: 3,
                discTitleID: nil,
                requiresDeinterlaceWarmup: false
            )
        )
        engine.noteDidEnterBackground()
        XCTAssertTrue(engine.isBackgrounded)
        XCTAssertTrue(engine.needsForegroundVideoRestore)

        do {
            try await engine.reloadAtCurrentPosition(autoplay: false)
            XCTFail("Expected reload of nonexistent local file to throw")
        } catch {
            // Expected failure
        }

        XCTAssertFalse(engine.isBackgrounded, "reloadAtCurrentPosition must clear stale background state synchronously")
        XCTAssertFalse(engine.backgroundActionOwed)
        XCTAssertFalse(engine.loadedOptions.autoplay, "Explicit autoplay=false must override initial loadedOptions.autoplay=true")
        XCTAssertTrue(engine.needsForegroundVideoRestore, "Failed foreground reload must preserve needsForegroundVideoRestore for retry")
        XCTAssertEqual(engine.consumeReloadSelection().audioTrackIndex, 3)
    }

    // SVPlayer modification (2026-11-21): Regression test for NEW-03 ensuring parameterless and option-applying
    // reloadAtCurrentPosition calls preserve loadedOptions.autoplay on a background-torn-down session.
    @MainActor
    func testParameterlessAndApplyingReloadPreserveTornDownAutoplayContract() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }

        engine.loadedURL = URL(fileURLWithPath: "/nonexistent/torn-down-autoplay-\(UUID().uuidString).mkv")
        engine.setLoadedAutoplay(true)
        engine.restoreReloadSelection(
            BackgroundTeardownSelection(
                audioTrackIndex: 2,
                discTitleID: nil,
                requiresDeinterlaceWarmup: false
            )
        )

        do {
            try await engine.reloadAtCurrentPosition()
            XCTFail("Expected parameterless reload of nonexistent file to throw")
        } catch {
            // Expected failure
        }

        XCTAssertTrue(
            engine.loadedOptions.autoplay,
            "Parameterless reloadAtCurrentPosition() on a torn-down session must preserve loadedOptions.autoplay == true"
        )
        XCTAssertTrue(engine.needsForegroundVideoRestore)

        engine.setLoadedAutoplay(false)
        do {
            _ = try await engine.reloadAtCurrentPosition { options in
                options.autoplay = true
            }
            XCTFail("Expected reloadAtCurrentPosition(applying:) of nonexistent file to throw")
        } catch {
            // Expected failure
        }

        XCTAssertTrue(
            engine.loadedOptions.autoplay,
            "reloadAtCurrentPosition(applying: { $0.autoplay = true }) on a torn-down session must not overwrite autoplay back to false"
        )
        XCTAssertTrue(engine.needsForegroundVideoRestore)
    }

    func testDeinterlaceModeOffBypassesFilterGraphConstruction() throws {
        let frame = try XCTUnwrap(av_frame_alloc())
        var owned: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_frame_free(&owned) }

        frame.pointee.width = 64
        frame.pointee.height = 64
        frame.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        frame.pointee.pts = 0
        frame.pointee.flags |= (1 << 3)
        frame.pointee.sample_aspect_ratio = AVRational(num: 1, den: 1)
        XCTAssertGreaterThanOrEqual(av_frame_get_buffer(frame, 0), 0)

        let filter = DeinterlaceFilter()
        filter.config = DeinterlaceConfig(mode: .off, fieldRate: .field)
        defer { filter.teardown() }

        XCTAssertFalse(filter.ensureGraph(frame: frame, timeBase: AVRational(num: 1, den: 30)))
        XCTAssertFalse(filter.isActive)
    }
}

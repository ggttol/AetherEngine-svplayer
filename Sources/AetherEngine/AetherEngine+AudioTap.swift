import Foundation
import Combine

extension AetherEngine {
    var speechPacketHistory: AudioPacketWindow? {
        nativeVideoSession?.speechPackets ?? softwareHost?.speechPackets ?? audioHost?.speechPackets
    }

    /// SVPlayer modification. Source PTS for display time zero on the active playback timeline.
    @MainActor
    public var audioTapSourceOrigin: Double {
        sourceTimeAtPresentationZero
    }

    @MainActor
    var sourceTimeAtPresentationZero: Double {
        if let softwareHost { return softwareHost.sourceSeconds(forSession: 0) }
        if let audioHost { return audioHost.sourceSeconds(forSession: 0) }
        return displayAxisIsItemAxis ? 0 : sourcePresentationOrigin
    }

    /// SVPlayer modification. Decode the selected compressed demux track to Float32 mono 16 kHz.
    /// A seek begins by finishing this stream. Install again on the landed seek ticket using the
    /// new source position. Loading, stopping and replacing a track also finish the old stream.
    @MainActor
    public func installAudioTap(channels: AudioTapChannels = .downmix,
                                startingAtSourceTime anchor: Double? = nil) -> AsyncStream<AudioTapBuffer> {
        removeAudioTap()
        let controller = AudioTapController()
        audioTapController = controller
        let history = speechPacketHistory
        let start = anchor.flatMap { $0.isFinite ? $0 : nil } ?? (currentTime + audioTapSourceOrigin)
        let playhead = AtomicDouble(start)
        let stream = controller.makeStream { onStop in
            guard let history, history.format != nil, start.isFinite, let yield = controller.makeYield() else { return }
            var awaitingLandingClock = true
            let selection = clock.$sourceTime.dropFirst().sink { sourceTime in
                guard sourceTime.isFinite else { return }
                if awaitingLandingClock {
                    guard abs(sourceTime - start) <= 4 else { return }
                    awaitingLandingClock = false
                }
                playhead.set(sourceTime)
            }
            let tap = AudioPacketTap(packets: history, channels: channels, start: start, playhead: playhead,
                                     source: audioLookaheadSource(), yield: yield) { [weak controller] in
                Task { @MainActor in controller?.finishInput() }
            }
            controller.readProgress = { tap.progress }
            tap.begin()
            onStop {
                selection.cancel()
                tap.stop()
            }
        }
        if !controller.hasDeliverySource { controller.teardown() }
        EngineLog.emit("[AudioTap] installed route=\(playbackBackend.rawValue) source=\(start) "
            + "active=\(controller.hasDeliverySource) targetLead=\(AudioTapDefaults.leadSeconds)", category: .engine)
        return stream
    }

    @MainActor
    public func removeAudioTap() {
        audioTapController?.teardown()
        audioTapController = nil
    }

    @MainActor
    public var audioTapHasDeliverySource: Bool {
        audioTapController?.hasDeliverySource ?? false
    }

    @MainActor
    public var audioTapProgress: AudioTapProgress? {
        audioTapController?.readProgress?()
    }

    @MainActor
    private func audioLookaheadSource() -> AudioPacketLookahead.Source? {
        guard !isLive, !displayAxisIsItemAxis, !loadedOptions.sequentialOrigin, isSourceSeekable == true,
              nativeVideoSession?.sideAudioDemuxer == nil, let url = loadedURL,
              customReader != nil || url.isFileURL || ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        return .init(url: url, reader: customReader, formatHint: customFormatHint,
                     headers: loadedOptions.httpHeaders, headerStore: sessionRequestHeaders,
                     probeSize: loadedOptions.probesize, analyzeDuration: loadedOptions.maxAnalyzeDuration,
                     discTitleID: activeDiscTitleID)
    }
}

// Modified by SVPlayer on 2026-11-20.
import Foundation
import AVFAudio

/// Which part of the source's channels the tap folds into its mono output (#908).
public enum AudioTapChannels: Sendable, Equatable {
    /// Every channel summed to mono.
    case downmix
    /// The front-centre channel alone, where a multichannel mix carries its dialogue. A source
    /// without one (mono, stereo, 2.1, an unlabelled layout) is delivered as `.downmix`, and each
    /// buffer's `channels` says which it got. A mono track's only channel is not a centre.
    case dialogue
}

/// One decoded tap buffer (#95). Handed to exactly one consumer via `AsyncStream`; the engine
/// never touches `buffer` after yielding it, which is the invariant behind `@unchecked Sendable`.
public struct AudioTapBuffer: @unchecked Sendable {
    /// Mono Float32 16 kHz PCM (see `AetherEngine.audioTapFormat`).
    public let buffer: AVAudioPCMBuffer
    /// Source-PTS seconds of the first sample, same axis as `AetherEngine.sourceTime`.
    public let sourceTime: Double
    /// True when this buffer does not abut the previous one (seek, gap, drop, track switch).
    /// Non-discontinuity buffers are guaranteed strictly increasing and non-overlapping on
    /// `sourceTime` (AudioTapMonotonicFilter trims sub-`overlapTrimThreshold` seam overlaps),
    /// which SpeechAnalyzer's input timeline requires.
    public let discontinuity: Bool
    /// What this buffer actually carries (#908). Always `.downmix` on a `.downmix` install; on a
    /// `.dialogue` install, `.downmix` for a source with no centre channel. Can change between
    /// buffers of one stream when the source's layout changes (a live program boundary).
    public let channels: AudioTapChannels

    init(buffer: AVAudioPCMBuffer, sourceTime: Double, discontinuity: Bool,
         channels: AudioTapChannels = .downmix) {
        self.buffer = buffer
        self.sourceTime = sourceTime
        self.discontinuity = discontinuity
        self.channels = channels
    }

    /// The same audio with a new stamp, keeping `channels`.
    func restamped(buffer: AVAudioPCMBuffer? = nil, sourceTime: Double? = nil,
                   discontinuity: Bool) -> AudioTapBuffer {
        AudioTapBuffer(buffer: buffer ?? self.buffer, sourceTime: sourceTime ?? self.sourceTime,
                       discontinuity: discontinuity, channels: channels)
    }
}

public extension AetherEngine {
    /// The fixed output format of the audio tap. Computed per call because `AVAudioFormat`
    /// is not Sendable and cannot be a stored static under strict concurrency.
    nonisolated static var audioTapFormat: AVAudioFormat {
        // SVPlayer modification: SpeechAnalyzer/SFSpeechRecognizer consume the
        // tap directly, so the engine owns the final 16 kHz conversion.
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }
}

/// SVPlayer modification. Positions are source PTS seconds for the currently installed tap.
public struct AudioTapProgress: Sendable {
    public let primarySourceEnd: Double?
    public let preparedSourceEnd: Double?
    public let lookaheadSourceEnd: Double?
    public let lookaheadState: String
    public let targetLeadSeconds: Double
}

enum AudioTapDefaults {
    // SVPlayer modification: consume existing demuxed audio up to this lead before waiting.
    static let leadSeconds: Double = 45
    static let refillLeadSeconds: Double = 30
    // SVPlayer modification: keep every tap backend on the recognizer's native
    // mono 16 kHz timeline. PTS remains on the source axis.
    static let minSamplesPerChunk = 1600   // 100 ms at 16 kHz
    static let sampleRate: Double = 16_000
    /// Max backward PTS overlap (seconds) the monotonic gate trims silently. Segment-seam
    /// decoder priming is tens of ms; a larger backward jump is a real seek and is passed
    /// through as a discontinuity instead.
    static let overlapTrimThreshold: Double = 0.25
}


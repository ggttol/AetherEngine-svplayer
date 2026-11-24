// Modified by SVPlayer on 2026-11-20.
import Foundation
import CoreGraphics

/// A resident still's measured timestamp, on the caller's timeline. Refinement
/// means target-directed decoding succeeded, not that requested and actual PTS coincide.
// CGImage is immutable; all other stored properties are immutable Sendable values.
public struct ScrubFrame: @unchecked Sendable {
    public enum Source: Sendable { case resident, ladder, sourceRead }
    public let image: CGImage
    public let actualSeconds: Double
    public let refined: Bool
    public let validRange: Range<Double>?
    public let source: Source
    public init(image: CGImage, actualSeconds: Double, refined: Bool, validRange: Range<Double>? = nil,
                source: Source = .resident) {
        self.image = image; self.actualSeconds = actualSeconds; self.refined = refined
        self.validRange = validRange
        self.source = source
    }

    public func isRefined(at seconds: Double) -> Bool {
        refined && abs(actualSeconds - seconds) < 2
    }

    func shifted(by offset: Double) -> ScrubFrame {
        let range = validRange.map { ($0.lowerBound + offset)..<($0.upperBound + offset) }
        return ScrubFrame(image: image, actualSeconds: actualSeconds + offset, refined: refined,
                          validRange: range, source: source)
    }
}

/// SVPlayer modification: only decoded thumbnail-sized pixels enter this cache. A gesture
/// can synchronously choose the closest timestamp without file access or opening a decoder.
final class ReadyScrubFrames: @unchecked Sendable {
    private let lock = NSLock()
    private let byteLimit: Int
    private var entries: [(frame: ScrubFrame, bytes: Int)] = []
    private var bytes = 0

    init(byteLimit: Int) { self.byteLimit = byteLimit }

    func insert(_ frame: ScrubFrame) {
        let (cost, overflow) = frame.image.bytesPerRow.multipliedReportingOverflow(by: frame.image.height)
        guard frame.actualSeconds.isFinite, !overflow, cost > 0, cost <= byteLimit else { return }
        lock.withLock {
            if let index = entries.firstIndex(where: { $0.frame.actualSeconds == frame.actualSeconds }) {
                bytes -= entries.remove(at: index).bytes
            }
            while !entries.isEmpty && (bytes > byteLimit - cost || entries.count >= 256) {
                bytes -= entries.removeFirst().bytes
            }
            entries.append((frame, cost))
            bytes += cost
        }
    }

    func nearest(to seconds: Double) -> ScrubFrame? {
        guard seconds.isFinite else { return nil }
        return lock.withLock {
            entries.min {
                let lhs = abs($0.frame.actualSeconds - seconds)
                let rhs = abs($1.frame.actualSeconds - seconds)
                return lhs == rhs ? $0.frame.actualSeconds < $1.frame.actualSeconds : lhs < rhs
            }?.frame
        }
    }
}

/// Raw PTS is restored with the normalization recorded for the bytes' epoch,
/// then folded through the same source origin as the published playhead.
enum ScrubSegmentTime {
    static func displayTime(rawPTS: Double, carriedOffset: Double, displayOrigin: Double) -> Double? {
        guard rawPTS.isFinite, carriedOffset.isFinite, displayOrigin.isFinite else { return nil }
        return rawPTS + carriedOffset - displayOrigin
    }
}

/// Which extraction mode produced (or is requested for) a frame.
///
/// - `thumbnail`: nearest keyframe, no forward decode, downscaled. Cheap; posters/Recents.
/// - `preview`: frame-accurate forward decode, downscaled. Interactive scrub previews.
/// - `snapshot`: frame-accurate (decode forward to exact PTS), full/requested res; stills.
public enum FrameMode: Sendable, Hashable {
    case thumbnail
    case preview
    case snapshot

    var isFrameAccurate: Bool { self != .thumbnail }
    var usesTargetWidth: Bool { self != .snapshot }
    var isElective: Bool { self != .snapshot }

    func accepts(framePTS: Int64, targetPTS: Int64) -> Bool {
        !isFrameAccurate || framePTS == Int64.min || framePTS >= targetPTS
    }
}

// SVPlayer modification (2026-11-25): structured redacted telemetry and outcome
// types for directory video thumbnail extraction across SDR/HDR/DV/MKV/TS/SMB.
public struct ThumbnailExtractionDiagnostics: Sendable, Equatable {
    public let container: String
    public let codec: String
    public let profile: String
    public let bitDepth: Int
    public let hdrType: String
    public let dvProfile: Int?
    public let durationSeconds: Double?
    public let seekSeconds: Double
    public let actualSeconds: Double?
    public let bytesRead: Int64
    public let packetsRead: Int
    public let colorPath: String
    public let failureStage: String?
    public let ffmpegErrorCode: Int32?
    public let detail: String?

    public init(
        container: String = "unknown",
        codec: String = "unknown",
        profile: String = "unknown",
        bitDepth: Int = 0,
        hdrType: String = "unknown",
        dvProfile: Int? = nil,
        durationSeconds: Double? = nil,
        seekSeconds: Double = 0,
        actualSeconds: Double? = nil,
        bytesRead: Int64 = 0,
        packetsRead: Int = 0,
        colorPath: String = "none",
        failureStage: String? = nil,
        ffmpegErrorCode: Int32? = nil,
        detail: String? = nil
    ) {
        self.container = container
        self.codec = codec
        self.profile = profile
        self.bitDepth = bitDepth
        self.hdrType = hdrType
        self.dvProfile = dvProfile
        self.durationSeconds = durationSeconds
        self.seekSeconds = seekSeconds
        self.actualSeconds = actualSeconds
        self.bytesRead = bytesRead
        self.packetsRead = packetsRead
        self.colorPath = colorPath
        self.failureStage = failureStage
        self.ffmpegErrorCode = ffmpegErrorCode
        self.detail = detail
    }
}

public struct ThumbnailExtractionOutcome: @unchecked Sendable {
    public let image: CGImage?
    public let diagnostics: ThumbnailExtractionDiagnostics

    public init(image: CGImage?, diagnostics: ThumbnailExtractionDiagnostics) {
        self.image = image
        self.diagnostics = diagnostics
    }
}

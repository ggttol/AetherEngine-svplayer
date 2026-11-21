// Modified by SVPlayer on 2026-11-20.
// Sources/AetherEngine/Video/KeyframeStillLadder.swift
import Foundation

/// Sparse scrub stills for the parts of a VOD title nothing resident covers (StreamX, 7.48.0). While
/// the link is idle, one keyframe per rung is read off the source, on the same per-origin request
/// budget the pump uses. A one-request origin gets no ladder (AE#937). A scrub miss
/// then answers with the nearest rung instead of nothing.
///
/// Pure: the session owns the reader and the cache, this decides which rung comes next and whether
/// the link may be touched at all.
enum KeyframeStillLadder {
    /// How far from a rung a scrub target may sit and still be answered by it.
    static let maximumAnswerDistanceSeconds: Double = 30
    static let payloadByteLimit = 16 * 1024 * 1024
    static let radius: Double = 120
    static let spacing: Double = 25

    /// SVPlayer modification: anchor the 25-second grid to the title so adjacent playhead
    /// ticks reuse the same rungs. Only actual segment starts inside the local window qualify.
    static func nearbyRungs(segmentStarts: [Double], totalSeconds: Double, playheadSeconds: Double) -> [Int] {
        guard !segmentStarts.isEmpty, totalSeconds.isFinite, totalSeconds > 0, playheadSeconds.isFinite else { return [] }
        let center = max(0, min(playheadSeconds, totalSeconds))
        let start = (max(0, center - radius) / spacing).rounded(.up) * spacing
        let end = min(totalSeconds, center + radius)
        guard start <= end else { return [] }
        var seen = Set<Int>()
        return stride(from: start, through: end, by: spacing).compactMap { time in
            guard let index = nearestPlanIndex(to: time, in: segmentStarts),
                  abs(segmentStarts[index] - center) <= radius, seen.insert(index).inserted else { return nil }
            return index
        }.sorted {
            let lhs = abs(segmentStarts[$0] - center)
            let rhs = abs(segmentStarts[$1] - center)
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
    }

    static func nearestPlanIndex(to seconds: Double, in starts: [Double]) -> Int? {
        guard seconds.isFinite, let before = planIndex(atOrBefore: seconds, in: starts) else { return nil }
        let after = before + 1
        return starts.indices.contains(after) && abs(starts[after] - seconds) < abs(starts[before] - seconds) ? after : before
    }

    /// SVPlayer modification: both directions compete by actual distance. Ties use the earlier frame.
    static func answeringRung(for seconds: Double, segmentStarts: [Double], cached: [Int]) -> Int? {
        guard seconds.isFinite else { return nil }
        return cached.filter { segmentStarts.indices.contains($0) && abs(segmentStarts[$0] - seconds) <= maximumAnswerDistanceSeconds }
            .min {
                let lhs = abs(segmentStarts[$0] - seconds)
                let rhs = abs(segmentStarts[$1] - seconds)
                return lhs == rhs ? segmentStarts[$0] < segmentStarts[$1] : lhs < rhs
            }
    }

    struct LinkState: Equatable {
        var restartInFlight: Bool
        var seeking: Bool
        /// Contiguous seconds the consumer can play without another fetch.
        var forwardBufferSeconds: Double
        var originInflight: Int
        var originWaiting: Int
        var originPaced: Bool
        /// The origin's limit was declared or learned to be one request (AE#937).
        var originSerial: Bool
        var secondsSinceOriginRefusal: Double?
        var secondsSinceSessionStart: Double
        var secondsSinceLastRung: Double?
    }

    /// Below this the pump may need the link any moment, and a rung read could be the request it waits on.
    static let minimumForwardBufferSeconds: Double = 30
    /// Startup belongs to the pump: the first segments, the probe and AVPlayer's own requests.
    static let startupGraceSeconds: Double = 3
    /// An origin that refused anything recently is metering; the ladder is elective and stays away.
    static let refusalQuietSeconds: Double = 120
    /// At most one rung read per this many seconds, however idle the link looks.
    static let rungSpacingSeconds: Double = 2

    /// True when one rung read may go out now. It requires the origin to have NOTHING in flight and
    /// nobody queued, not merely a free slot, so on an origin whose limit nobody has learned yet the
    /// ladder is never the second concurrent request. A one-request origin is never read at all
    /// (AE#937): the gap between two pump ranges does not hold a side reader's open plus its ranges,
    /// and a panel guarding one slot blocked the client's address over them.
    static func linkIsIdle(_ s: LinkState) -> Bool {
        guard !s.originSerial else { return false }
        guard !s.restartInFlight, !s.seeking else { return false }
        guard s.forwardBufferSeconds >= minimumForwardBufferSeconds else { return false }
        guard s.secondsSinceSessionStart >= startupGraceSeconds else { return false }
        guard s.originInflight == 0, s.originWaiting == 0, !s.originPaced else { return false }
        if let refusal = s.secondsSinceOriginRefusal, refusal < refusalQuietSeconds { return false }
        if let last = s.secondsSinceLastRung, last < rungSpacingSeconds { return false }
        return true
    }

    /// The last segment starting at or before `seconds`.
    static func planIndex(atOrBefore seconds: Double, in starts: [Double]) -> Int? {
        guard let first = starts.first else { return nil }
        if seconds < first { return 0 }
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= seconds { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// SVPlayer modification: movement within one segment can reuse the same keyframe read.
/// Movement across segments and a settled refinement each interrupt the superseded Range.
struct ScrubLadderFinger {
    private(set) var seconds: Double?
    private(set) var index: Int?
    private(set) var rung: ProbeCancellation?
    private(set) var refinement: ProbeCancellation?

    mutating func move(to target: Double?, in plan: [HLSVideoEngine.Segment]) -> [ProbeCancellation] {
        let next = target.flatMap { HLSVideoEngine.planIndex(containing: $0, in: plan) }
        guard target != seconds || index != next else { return [] }
        var obsolete = [ProbeCancellation]()
        if let refinement { obsolete.append(refinement); self.refinement = nil }
        if index != next || target == nil, let rung { obsolete.append(rung); self.rung = nil }
        seconds = target
        index = next
        return obsolete
    }

    mutating func beginRung(at target: Double, using token: ProbeCancellation) -> Int? {
        guard seconds == target, let index, rung == nil, refinement == nil else { return nil }
        rung = token
        return index
    }

    mutating func beginRefinement(at target: Double, using token: ProbeCancellation) -> (Bool, ProbeCancellation?) {
        guard seconds == target, index != nil, refinement == nil else { return (false, nil) }
        refinement = token
        defer { rung = nil }
        return (true, rung)
    }

    mutating func finish(_ token: ProbeCancellation) {
        if rung === token { rung = nil }
        if refinement === token { refinement = nil }
    }
}

import Foundation

/// Disk bound for an opt-in whole-source prefetch (#207).
///
/// `SegmentCache.pruneOutsideWindow` never evicts the hard window, so the retention budget bounds only
/// what lives outside it. That is correct for the historical windows (10 segments ~ 100 MB, the 150
/// ceiling ~ 1.5 GB), which fit under the budget by construction. A host that opts into buffering a
/// whole film (`LoadOptions.forwardBufferSegments`) makes the window itself the dominant footprint, and
/// nothing would stop it from filling the volume: a failed segment write degrades to a cache miss and
/// stalls playback, which is the exact failure the option exists to prevent.
///
/// So the producer parks once the window's own bytes reach the budget. Eviction of the extras behind
/// the playhead frees room as playback advances, which releases the park, so the prefetch tracks the
/// budget instead of the source length. Sessions that never opt in never reach the condition.
enum PrefetchDiskBudget {

    /// Segments the producer may always run ahead of the consumer, budget or not. Bounding disk closer
    /// than the historical forward window would starve AVPlayer's own ~5-7-segment prefetch, i.e. trade
    /// a full volume for a stall. A pathologically small budget therefore loses to playback, by design.
    static let minAheadSegments = 10

    // SVPlayer modification (2026-11-24): Seconds-based forward buffer floor and 70% park/resume hysteresis.
    /// Default Wi-Fi minimum forward duration (seconds) before disk-budget parking engages.
    static let defaultMinAheadSeconds: Double = 60.0
    /// Minimum playback safety cushion (seconds) enforced even when a hard disk cap is hit.
    static let safetyFloorSeconds: Double = 20.0
    /// Default hysteresis resume ratio: once parked at 100% of target, resume prefetching when
    /// buffered bytes or buffered seconds fall to or below 70% of target rather than draining near empty.
    static let defaultHysteresisResumeRatio: Double = 0.70

    /// - Parameters:
    ///   - forwardBytes: on-disk bytes at or above the consumer's target (`SegmentCache.forwardBytes`),
    ///     i.e. what the producer's race-ahead owns. History behind the playhead is excluded: the
    ///     extras eviction already bounds it, and counting it would throttle a standard session.
    ///   - budgetBytes: the session retention budget; 0 (live) never parks.
    ///   - head: segment index the producer is about to write.
    ///   - consumerTarget: the consumer's last declared fetch index (`SegmentCache.targetIndex`).
    static func shouldPark(forwardBytes: Int,
                           budgetBytes: Int,
                           head: Int,
                           consumerTarget: Int,
                           minAheadSegments: Int = minAheadSegments) -> Bool {
        guard budgetBytes > 0, forwardBytes >= budgetBytes else { return false }
        return head - consumerTarget >= minAheadSegments
    }

    // SVPlayer modification (2026-11-24): Seconds-based disk-budget park with park/resume hysteresis.
    /// Evaluates whether the producer should park on the on-disk forward byte budget using real buffered
    /// duration (`aheadSeconds`) instead of a fixed segment count, with hysteresis (`resumeRatio`).
    static func shouldPark(forwardBytes: Int,
                           budgetBytes: Int,
                           aheadSeconds: Double,
                           minAheadSeconds: Double = defaultMinAheadSeconds,
                           currentlyParked: Bool,
                           resumeRatio: Double = defaultHysteresisResumeRatio,
                           hardCeilingBytes: Int? = nil) -> Bool {
        guard budgetBytes > 0 else { return false }
        let effectiveBudget = hardCeilingBytes.map { min(budgetBytes, $0) } ?? budgetBytes
        guard effectiveBudget > 0 else { return false }
        let clampedRatio = min(0.95, max(0.30, resumeRatio))
        let resumeBudget = Int(Double(effectiveBudget) * clampedRatio)
        let effectiveMinAhead: Double = {
            if let hardCeilingBytes, forwardBytes >= hardCeilingBytes {
                return min(minAheadSeconds, safetyFloorSeconds)
            }
            return minAheadSeconds
        }()
        let resumeAheadSeconds = effectiveMinAhead * clampedRatio

        if currentlyParked {
            if aheadSeconds <= resumeAheadSeconds { return false }
            return forwardBytes > resumeBudget
        } else {
            return forwardBytes >= effectiveBudget && aheadSeconds >= effectiveMinAhead
        }
    }

    // SVPlayer modification (2026-11-24): Seconds-based forward window park with 70% hysteresis.
    /// Evaluates whether the producer should park on the forward time/segment window, staying parked
    /// after hitting 100% until buffered headroom drains to `resumeRatio` (default 70%) so prefetch
    /// refills in smooth contiguous bursts rather than waking on every single segment boundary.
    static func shouldParkWindow(aheadSeconds: Double,
                                 targetSeconds: Double,
                                 aheadSegments: Int,
                                 windowSegments: Int,
                                 currentlyParked: Bool,
                                 resumeRatio: Double = defaultHysteresisResumeRatio) -> Bool {
        let clampedRatio = min(0.95, max(0.30, resumeRatio))
        if targetSeconds > 0 {
            let resumeSeconds = targetSeconds * clampedRatio
            if currentlyParked {
                return aheadSeconds > resumeSeconds
            } else {
                return aheadSeconds >= targetSeconds
            }
        }
        let resumeSegments = max(4, Int(floor(Double(windowSegments) * clampedRatio)))
        if currentlyParked {
            return aheadSegments > resumeSegments
        } else {
            return aheadSegments >= windowSegments
        }
    }
}

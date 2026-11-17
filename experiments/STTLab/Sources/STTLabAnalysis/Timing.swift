import Foundation

/// Timing comparison statistics for matched word pairs between two engines.
public struct TimingStats: Codable, Sendable, Equatable {
    /// Number of matched word pairs with valid times.
    public var pairs: Int
    /// Median of the absolute time differences.
    public var medianAbs: Double?
    /// 90th percentile of the absolute time differences.
    public var p90Abs: Double?
    /// Maximum absolute time difference.
    public var maxAbs: Double?
    /// Median of the signed time differences (Y - X).
    public var medianSigned: Double?

    public init(pairs: Int, medianAbs: Double? = nil, p90Abs: Double? = nil,
                maxAbs: Double? = nil, medianSigned: Double? = nil) {
        self.pairs = pairs
        self.medianAbs = medianAbs
        self.p90Abs = p90Abs
        self.maxAbs = maxAbs
        self.medianSigned = medianSigned
    }
}

/// Timing result for one engine pair.
public struct TimingResult: Codable, Sendable, Equatable {
    public var engineX: EngineID
    public var engineY: EngineID
    public var startStats: TimingStats
    public var endStats: TimingStats

    public init(engineX: EngineID, engineY: EngineID, startStats: TimingStats,
                endStats: TimingStats) {
        self.engineX = engineX
        self.engineY = engineY
        self.startStats = startStats
        self.endStats = endStats
    }
}

/// Computes word-timing comparison metrics between engine pairs.
public enum Timing {

    /// Compute timing stats for a pair of engines.
    ///
    /// Takes the alignment ops between the two normalized token sequences, and
    /// maps matched tokens back to source words for timing.
    ///
    /// - Parameters:
    ///   - opsXY: Alignment ops where X is "a" and Y is "b".
    ///   - xTokens: Normalized tokens for engine X.
    ///   - yTokens: Normalized tokens for engine Y.
    ///   - xWords: Source engine words for X.
    ///   - yWords: Source engine words for Y.
    /// - Returns: Start and end timing stats.
    public static func compute(
        opsXY: [EditOp],
        xTokens: [NormToken], yTokens: [NormToken],
        xWords: [EngineWord], yWords: [EngineWord]
    ) -> (startStats: TimingStats, endStats: TimingStats) {

        // Collect matched word pairs (by sourceIndex), keep unique pairs.
        var seen = Set<String>()
        var startDeltas: [Double] = []
        var endDeltas: [Double] = []

        for op in opsXY {
            guard case .match(let xi, let yi) = op else { continue }
            let xSrc = xTokens[xi].sourceIndex
            let ySrc = yTokens[yi].sourceIndex
            let key = "\(xSrc)-\(ySrc)"
            guard seen.insert(key).inserted else { continue }

            let xw = xWords[xSrc]
            let yw = yWords[ySrc]

            if let xs = xw.start, let ys = yw.start {
                startDeltas.append(ys - xs)
            }
            if let xe = xw.end, let ye = yw.end {
                endDeltas.append(ye - xe)
            }
        }

        return (computeStats(startDeltas), computeStats(endDeltas))
    }

    /// Compute TimingStats from a list of signed deltas.
    public static func computeStats(_ deltas: [Double]) -> TimingStats {
        guard !deltas.isEmpty else { return TimingStats(pairs: 0) }

        let absSorted = deltas.map { abs($0) }.sorted()
        let signedSorted = deltas.sorted()

        return TimingStats(
            pairs: deltas.count,
            medianAbs: percentile(absSorted, p: 50),
            p90Abs: percentile(absSorted, p: 90),
            maxAbs: absSorted.last,
            medianSigned: percentile(signedSorted, p: 50)
        )
    }

    /// Nearest-rank percentile on a pre-sorted array.
    static func percentile(_ sorted: [Double], p: Int) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = max(1, Int(ceil(Double(p) / 100.0 * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}

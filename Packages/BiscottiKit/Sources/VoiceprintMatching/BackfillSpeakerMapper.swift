import Foundation

/// A speaker's time span from a diarization run.
public struct SpeakerSpan: Sendable, Equatable {
    public let speakerID: Int
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speakerID: Int, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// Maps fresh diarization speaker IDs to stored transcript speaker IDs
/// by comparing their time ranges.
public enum BackfillSpeakerMapper {
    /// The mapping result: which fresh IDs matched stored IDs, and which did not.
    public struct Result: Sendable, Equatable {
        /// Fresh speaker ID -> stored speaker ID.
        public let mapping: [Int: Int]
        /// Fresh IDs that could not be mapped, sorted ascending.
        public let unmapped: [Int]

        public init(mapping: [Int: Int], unmapped: [Int]) {
            self.mapping = mapping
            self.unmapped = unmapped
        }
    }

    /// Maps each fresh speaker to a stored speaker by time overlap.
    ///
    /// - Parameters:
    ///   - fresh: Time spans from the new diarization run.
    ///   - stored: Time spans from the existing transcript segments.
    ///   - minOverlapFraction: Minimum overlap as a fraction of the fresh speaker's total time.
    /// - Returns: The one-to-one mapping and any unmapped fresh speakers.
    public static func map(
        fresh: [SpeakerSpan],
        stored: [SpeakerSpan],
        minOverlapFraction: Double = 0.5
    ) -> Result {
        // Collect distinct speaker IDs
        let freshIDs = Set(fresh.map(\.speakerID)).sorted()
        let storedIDs = Set(stored.map(\.speakerID)).sorted()

        // Group spans by speaker
        let freshSpans = Dictionary(grouping: fresh, by: \.speakerID)
        let storedSpans = Dictionary(grouping: stored, by: \.speakerID)

        // Compute total seconds per fresh speaker
        var freshTotal: [Int: Double] = [:]
        for fid in freshIDs {
            freshTotal[fid] = (freshSpans[fid] ?? []).reduce(0) { $0 + ($1.end - $1.start) }
        }

        // Compute pairwise overlap
        struct OverlapPair: Comparable {
            let freshID: Int
            let storedID: Int
            let overlap: Double

            static func < (lhs: OverlapPair, rhs: OverlapPair) -> Bool {
                if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
                if lhs.freshID != rhs.freshID { return lhs.freshID < rhs.freshID }
                return lhs.storedID < rhs.storedID
            }
        }

        var pairs: [OverlapPair] = []
        for fid in freshIDs {
            let fSpans = freshSpans[fid] ?? []
            for sid in storedIDs {
                let sSpans = storedSpans[sid] ?? []
                let overlap = totalOverlap(fSpans, sSpans)
                if overlap > 0 {
                    pairs.append(OverlapPair(freshID: fid, storedID: sid, overlap: overlap))
                }
            }
        }

        // Sort by overlap descending (ties: lower freshID, then lower storedID)
        pairs.sort()

        // Greedy one-to-one assignment
        var usedFresh: Set<Int> = []
        var usedStored: Set<Int> = []
        var mapping: [Int: Int] = [:]

        for pair in pairs {
            guard !usedFresh.contains(pair.freshID),
                  !usedStored.contains(pair.storedID)
            else { continue }

            let total = freshTotal[pair.freshID] ?? 0
            guard total > 0, pair.overlap >= minOverlapFraction * total else { continue }

            mapping[pair.freshID] = pair.storedID
            usedFresh.insert(pair.freshID)
            usedStored.insert(pair.storedID)
        }

        let unmapped = freshIDs.filter { !usedFresh.contains($0) }
        return Result(mapping: mapping, unmapped: unmapped)
    }

    /// Total seconds of overlap between two sets of time spans.
    private static func totalOverlap(_ spanSetA: [SpeakerSpan], _ spanSetB: [SpeakerSpan]) -> Double {
        var total: Double = 0
        for spanA in spanSetA {
            for spanB in spanSetB {
                let overlapStart = max(spanA.start, spanB.start)
                let overlapEnd = min(spanA.end, spanB.end)
                if overlapEnd > overlapStart {
                    total += overlapEnd - overlapStart
                }
            }
        }
        return total
    }
}

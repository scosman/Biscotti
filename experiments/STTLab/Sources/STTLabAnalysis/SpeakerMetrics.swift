import Foundation

/// Agreement metrics for speaker alignment between two engines.
public struct SpeakerAgreement: Codable, Sendable, Equatable {
    /// Share of grid points where both engines agree on the speaker label.
    public var timeAgreement: Double?
    /// Share of audio grid points labelled by engine A.
    public var coverageA: Double?
    /// Share of audio grid points labelled by engine B.
    public var coverageB: Double?
    /// Share of matched word pairs with equal speaker.
    public var wordAgreement: Double?

    public init(timeAgreement: Double? = nil, coverageA: Double? = nil,
                coverageB: Double? = nil, wordAgreement: Double? = nil) {
        self.timeAgreement = timeAgreement
        self.coverageA = coverageA
        self.coverageB = coverageB
        self.wordAgreement = wordAgreement
    }
}

/// Statistics about aligned segments for one engine.
public struct SegmentStats: Codable, Sendable, Equatable {
    public var segmentCount: Int
    public var medianLengthSeconds: Double?
    public var p90LengthSeconds: Double?
    public var maxLengthSeconds: Double?
    public var medianWordCount: Double?
    public var p90WordCount: Double?
    public var maxWordCount: Int?
    /// Number of merged speaker turns (consecutive segments with same speaker).
    public var turnCount: Int
    /// Speaker changes = turns - 1.
    public var speakerChanges: Int

    public init(segmentCount: Int = 0, medianLengthSeconds: Double? = nil,
                p90LengthSeconds: Double? = nil, maxLengthSeconds: Double? = nil,
                medianWordCount: Double? = nil, p90WordCount: Double? = nil,
                maxWordCount: Int? = nil, turnCount: Int = 0, speakerChanges: Int = 0) {
        self.segmentCount = segmentCount
        self.medianLengthSeconds = medianLengthSeconds
        self.p90LengthSeconds = p90LengthSeconds
        self.maxLengthSeconds = maxLengthSeconds
        self.medianWordCount = medianWordCount
        self.p90WordCount = p90WordCount
        self.maxWordCount = maxWordCount
        self.turnCount = turnCount
        self.speakerChanges = speakerChanges
    }
}

/// A speaker disagreement between two engines over matched word pairs.
public struct SpeakerDisagreementRun: Codable, Sendable, Equatable {
    public var timeStart: Double?
    public var timeEnd: Double?
    public var words: String
    public var speakerA: Int?
    public var speakerB: Int?
    public var nearestDiarizationBoundary: Double?
    public var wordCount: Int

    public init(timeStart: Double? = nil, timeEnd: Double? = nil,
                words: String = "", speakerA: Int? = nil, speakerB: Int? = nil,
                nearestDiarizationBoundary: Double? = nil, wordCount: Int = 0) {
        self.timeStart = timeStart
        self.timeEnd = timeEnd
        self.words = words
        self.speakerA = speakerA
        self.speakerB = speakerB
        self.nearestDiarizationBoundary = nearestDiarizationBoundary
        self.wordCount = wordCount
    }
}

/// Computes speaker metrics between two aligned transcripts.
public enum SpeakerMetrics {

    // MARK: - Time agreement

    /// Compute time-based speaker agreement on a 10 ms grid.
    public static func timeAgreement(
        a: AlignedTranscript,
        b: AlignedTranscript,
        audioDuration: Double
    ) -> (agreement: Double?, coverageA: Double?, coverageB: Double?) {
        let gridStep = 0.01  // 10 ms
        let gridCount = max(0, Int(audioDuration / gridStep))
        guard gridCount > 0 else { return (nil, nil, nil) }

        // Build segment lookups sorted by start for binary search.
        let aSegs = a.segments.sorted { $0.start < $1.start }
        let bSegs = b.segments.sorted { $0.start < $1.start }

        var bothLabelled = 0
        var equal = 0
        var labelledA = 0
        var labelledB = 0

        for i in 0..<gridCount {
            let t = Double(i) * gridStep
            let spkA = speakerAt(t, segments: aSegs)
            let spkB = speakerAt(t, segments: bSegs)

            if spkA != nil { labelledA += 1 }
            if spkB != nil { labelledB += 1 }

            if let sa = spkA, let sb = spkB {
                bothLabelled += 1
                if sa == sb { equal += 1 }
            }
        }

        let agreement = bothLabelled > 0 ? Double(equal) / Double(bothLabelled) : nil
        let covA = Double(labelledA) / Double(gridCount)
        let covB = Double(labelledB) / Double(gridCount)

        return (agreement, covA, covB)
    }

    /// Find the speaker label at time t using a linear scan (segments are short lists).
    static func speakerAt(_ t: Double, segments: [AlignedSegment]) -> Int? {
        for seg in segments {
            if t >= seg.start && t < seg.end {
                return seg.speaker
            }
        }
        return nil
    }

    // MARK: - Word agreement

    /// Compute word-based speaker agreement over matched alignment ops.
    ///
    /// `opsAB` aligns normalized tokens where A is "a" and B is "b".
    /// For each match op, look up the source words' speakers.
    public static func wordAgreement(
        opsAB: [EditOp],
        aTokens: [NormToken], bTokens: [NormToken],
        aWords: [AlignedWord], bWords: [AlignedWord]
    ) -> Double? {
        var total = 0
        var equal = 0
        var seen = Set<String>()

        for op in opsAB {
            guard case .match(let ai, let bi) = op else { continue }
            let aSrc = aTokens[ai].sourceIndex
            let bSrc = bTokens[bi].sourceIndex
            let key = "\(aSrc)-\(bSrc)"
            guard seen.insert(key).inserted else { continue }

            let spkA = aWords[aSrc].speaker
            let spkB = bWords[bSrc].speaker
            guard spkA != nil, spkB != nil else { continue }

            total += 1
            if spkA == spkB { equal += 1 }
        }

        return total > 0 ? Double(equal) / Double(total) : nil
    }

    // MARK: - Segment stats

    /// Compute segment and turn statistics for one engine's aligned transcript.
    public static func segmentStats(_ t: AlignedTranscript) -> SegmentStats {
        let segs = t.segments
        guard !segs.isEmpty else {
            return SegmentStats()
        }

        let lengths = segs.map { $0.end - $0.start }
        let wordCounts = segs.map { $0.wordCount }

        // Turns: merge consecutive segments with the same speaker.
        var turnCount = 1
        for i in 1..<segs.count {
            if segs[i].speaker != segs[i - 1].speaker {
                turnCount += 1
            }
        }

        let sortedLengths = lengths.sorted()
        let sortedWordCounts = wordCounts.map(Double.init).sorted()

        return SegmentStats(
            segmentCount: segs.count,
            medianLengthSeconds: percentile(sortedLengths, p: 50),
            p90LengthSeconds: percentile(sortedLengths, p: 90),
            maxLengthSeconds: sortedLengths.last,
            medianWordCount: percentile(sortedWordCounts, p: 50),
            p90WordCount: percentile(sortedWordCounts, p: 90),
            maxWordCount: wordCounts.max(),
            turnCount: turnCount,
            speakerChanges: max(0, turnCount - 1)
        )
    }

    // MARK: - Disagreement sample

    /// Find contiguous runs of matched word pairs with different speakers.
    /// Returns up to `maxRuns` of the longest runs.
    public static func disagreementSample(
        opsAB: [EditOp],
        aTokens: [NormToken], bTokens: [NormToken],
        aWords: [AlignedWord], bWords: [AlignedWord],
        aEngine: [EngineWord], bEngine: [EngineWord],
        diarizationBoundaries: [Double],
        maxRuns: Int = 20
    ) -> [SpeakerDisagreementRun] {
        // Collect matched pairs with speakers.
        struct MatchedPair {
            var aSrc: Int
            var bSrc: Int
            var spkA: Int?
            var spkB: Int?
        }
        var pairs: [MatchedPair] = []
        var seen = Set<String>()

        for op in opsAB {
            guard case .match(let ai, let bi) = op else { continue }
            let aSrc = aTokens[ai].sourceIndex
            let bSrc = bTokens[bi].sourceIndex
            let key = "\(aSrc)-\(bSrc)"
            guard seen.insert(key).inserted else { continue }

            let spkA = aWords[aSrc].speaker
            let spkB = bWords[bSrc].speaker
            pairs.append(MatchedPair(aSrc: aSrc, bSrc: bSrc, spkA: spkA, spkB: spkB))
        }

        // Find contiguous runs where speakers differ (both present).
        var runs: [SpeakerDisagreementRun] = []
        var runStart: Int?
        var runSpkA: Int?
        var runSpkB: Int?

        func finalizeRun(endExclusive: Int) {
            guard let start = runStart else { return }
            let runPairs = pairs[start..<endExclusive]
            let wordTexts = runPairs.map { aEngine[$0.aSrc].text }

            let times = runPairs.compactMap { aEngine[$0.aSrc].start }
            let endTimes = runPairs.compactMap { aEngine[$0.aSrc].end }
            let tStart = times.min()
            let tEnd = endTimes.max()

            let nearestBoundary: Double?
            if let ts = tStart, !diarizationBoundaries.isEmpty {
                nearestBoundary = diarizationBoundaries.min(by: {
                    abs($0 - ts) < abs($1 - ts)
                })
            } else {
                nearestBoundary = nil
            }

            runs.append(SpeakerDisagreementRun(
                timeStart: tStart,
                timeEnd: tEnd,
                words: wordTexts.joined(separator: " "),
                speakerA: runSpkA,
                speakerB: runSpkB,
                nearestDiarizationBoundary: nearestBoundary,
                wordCount: runPairs.count
            ))
            runStart = nil
        }

        for (i, pair) in pairs.enumerated() {
            guard let sa = pair.spkA, let sb = pair.spkB else {
                finalizeRun(endExclusive: i)
                continue
            }

            if sa != sb {
                if runStart == nil {
                    runStart = i
                    runSpkA = sa
                    runSpkB = sb
                }
                // Continue the run.
            } else {
                finalizeRun(endExclusive: i)
            }
        }
        finalizeRun(endExclusive: pairs.count)

        // Sort by word count descending, take the largest.
        let sorted = runs.sorted { $0.wordCount > $1.wordCount }
        return Array(sorted.prefix(maxRuns))
    }

    // MARK: - Helpers

    /// Nearest-rank percentile on a pre-sorted array.
    static func percentile(_ sorted: [Double], p: Int) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = max(1, Int(ceil(Double(p) / 100.0 * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}

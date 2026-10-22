import Testing
@testable import STTLabAnalysis

@Suite("Timing")
struct TimingTests {

    func makeTokens(_ texts: [String]) -> [NormToken] {
        texts.enumerated().map { NormToken(text: $0.element, sourceIndex: $0.offset) }
    }

    func makeWords(_ count: Int, startOffset: Double = 0) -> [EngineWord] {
        (0..<count).map {
            EngineWord(text: "w\($0)",
                       start: startOffset + Double($0) * 0.5,
                       end: startOffset + Double($0) * 0.5 + 0.4,
                       segmentIndex: 0)
        }
    }

    @Test("Timing stats on known data")
    func knownData() {
        // 3 matched words. X starts at 0, 0.5, 1.0; Y starts at 0.1, 0.6, 1.1.
        // Delta start = 0.1, 0.1, 0.1.
        let tokens = makeTokens(["a", "b", "c"])
        let xWords = makeWords(3)
        let yWords = makeWords(3, startOffset: 0.1)

        let ops: [EditOp] = [.match(0, 0), .match(1, 1), .match(2, 2)]
        let (startStats, endStats) = Timing.compute(
            opsXY: ops, xTokens: tokens, yTokens: tokens,
            xWords: xWords, yWords: yWords
        )

        #expect(startStats.pairs == 3)
        #expect(startStats.medianAbs != nil)
        #expect(abs(startStats.medianAbs! - 0.1) < 0.001)
        #expect(endStats.pairs == 3)
    }

    @Test("Empty pairs returns zero-pair stats")
    func emptyPairs() {
        let stats = Timing.computeStats([])
        #expect(stats.pairs == 0)
        #expect(stats.medianAbs == nil)
        #expect(stats.p90Abs == nil)
    }

    @Test("Single pair")
    func singlePair() {
        let stats = Timing.computeStats([0.3])
        #expect(stats.pairs == 1)
        #expect(stats.medianAbs == 0.3)
        #expect(stats.p90Abs == 0.3)
        #expect(stats.maxAbs == 0.3)
        #expect(stats.medianSigned == 0.3)
    }

    @Test("Percentile: nearest rank")
    func percentileNearestRank() {
        // 10 values: sorted = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].
        let sorted = (1...10).map(Double.init)
        // p50: rank = ceil(0.5 * 10) = 5 -> index 4 -> 5.0.
        #expect(Timing.percentile(sorted, p: 50) == 5.0)
        // p90: rank = ceil(0.9 * 10) = 9 -> index 8 -> 9.0.
        #expect(Timing.percentile(sorted, p: 90) == 9.0)
    }

    @Test("Unique pairs: duplicate source indices counted once")
    func uniquePairs() {
        // Two tokens map to the same sourceIndex pair.
        let xTokens = [NormToken(text: "a", sourceIndex: 0), NormToken(text: "b", sourceIndex: 0)]
        let yTokens = [NormToken(text: "a", sourceIndex: 0), NormToken(text: "b", sourceIndex: 0)]
        let xWords = [EngineWord(text: "ab", start: 0.0, end: 0.4, segmentIndex: 0)]
        let yWords = [EngineWord(text: "ab", start: 0.1, end: 0.5, segmentIndex: 0)]

        let ops: [EditOp] = [.match(0, 0), .match(1, 1)]
        let (startStats, _) = Timing.compute(
            opsXY: ops, xTokens: xTokens, yTokens: yTokens,
            xWords: xWords, yWords: yWords
        )

        // Only 1 unique pair.
        #expect(startStats.pairs == 1)
    }
}

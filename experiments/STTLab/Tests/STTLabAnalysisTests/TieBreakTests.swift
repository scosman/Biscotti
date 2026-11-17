import Testing
@testable import STTLabAnalysis

@Suite("TieBreak")
struct TieBreakTests {

    func makeWords(_ texts: [String]) -> [EngineWord] {
        texts.enumerated().map {
            EngineWord(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5,
                       segmentIndex: 0)
        }
    }

    func makeTokens(_ texts: [String]) -> [NormToken] {
        texts.enumerated().map { NormToken(text: $0.element, sourceIndex: $0.offset) }
    }

    @Test("Apple matches reference exactly in disagreement region")
    func appleMatchesRef() {
        // Apple: the cat sat
        // Whisper: the dog sat
        // Ref: the cat sat
        let aTokens = makeTokens(["the", "cat", "sat"])
        let wTokens = makeTokens(["the", "dog", "sat"])
        let rTokens = makeTokens(["the", "cat", "sat"])
        let aWords = makeWords(["the", "cat", "sat"])
        let wWords = makeWords(["the", "dog", "sat"])
        let rWords = makeWords(["the", "cat", "sat"])

        let (regions, counts) = TieBreak.analyze(
            appleTokens: aTokens, whisperTokens: wTokens, refTokens: rTokens,
            appleWords: aWords, whisperWords: wWords, refWords: rWords
        )

        #expect(regions.count == 1)
        #expect(regions[0].classification == .appleMatches)
        #expect(counts.byRegion["appleMatches"] == 1)
    }

    @Test("Whisper matches reference exactly")
    func whisperMatchesRef() {
        let aTokens = makeTokens(["the", "dog", "sat"])
        let wTokens = makeTokens(["the", "cat", "sat"])
        let rTokens = makeTokens(["the", "cat", "sat"])
        let aWords = makeWords(["the", "dog", "sat"])
        let wWords = makeWords(["the", "cat", "sat"])
        let rWords = makeWords(["the", "cat", "sat"])

        let (regions, _) = TieBreak.analyze(
            appleTokens: aTokens, whisperTokens: wTokens, refTokens: rTokens,
            appleWords: aWords, whisperWords: wWords, refWords: rWords
        )

        #expect(regions.count == 1)
        #expect(regions[0].classification == .whisperMatches)
    }

    @Test("Neither matches reference")
    func neitherMatches() {
        let aTokens = makeTokens(["the", "dog", "sat"])
        let wTokens = makeTokens(["the", "bird", "sat"])
        let rTokens = makeTokens(["the", "fish", "sat"])
        let aWords = makeWords(["the", "dog", "sat"])
        let wWords = makeWords(["the", "bird", "sat"])
        let rWords = makeWords(["the", "fish", "sat"])

        let (regions, _) = TieBreak.analyze(
            appleTokens: aTokens, whisperTokens: wTokens, refTokens: rTokens,
            appleWords: aWords, whisperWords: wWords, refWords: rWords
        )

        #expect(regions.count == 1)
        // One sub each, no common tokens -> neither.
        #expect(regions[0].classification == .neither)
    }

    @Test("No disagreement regions when transcripts are identical")
    func noDisagreement() {
        let tokens = makeTokens(["hello", "world"])
        let words = makeWords(["hello", "world"])

        let (regions, _) = TieBreak.analyze(
            appleTokens: tokens, whisperTokens: tokens, refTokens: tokens,
            appleWords: words, whisperWords: words, refWords: words
        )

        #expect(regions.isEmpty)
    }

    @Test("Token-weighted counts reflect region size")
    func tokenWeighted() {
        // Apple: big gap in the middle.
        let aTokens = makeTokens(["a", "x", "y", "z", "b"])
        let wTokens = makeTokens(["a", "p", "q", "r", "b"])
        let rTokens = makeTokens(["a", "x", "y", "z", "b"])
        let aWords = makeWords(["a", "x", "y", "z", "b"])
        let wWords = makeWords(["a", "p", "q", "r", "b"])
        let rWords = makeWords(["a", "x", "y", "z", "b"])

        let (regions, counts) = TieBreak.analyze(
            appleTokens: aTokens, whisperTokens: wTokens, refTokens: rTokens,
            appleWords: aWords, whisperWords: wWords, refWords: rWords
        )

        #expect(regions.count == 1)
        #expect(regions[0].size == 3) // max(3 apple tokens, 3 whisper tokens)
        #expect(counts.byTokens["appleMatches"] == 3)
    }

    @Test("Region merging: single match between disagreements merges")
    func regionMerging() {
        // Whisper: a X c Y e
        // Apple:   a P c Q e
        // X/P disagree, then one match (c), then Y/Q disagree -> merged into one region.
        let aTokens = makeTokens(["a", "p", "c", "q", "e"])
        let wTokens = makeTokens(["a", "x", "c", "y", "e"])
        let rTokens = makeTokens(["a", "x", "c", "y", "e"])
        let aWords = makeWords(["a", "p", "c", "q", "e"])
        let wWords = makeWords(["a", "x", "c", "y", "e"])
        let rWords = makeWords(["a", "x", "c", "y", "e"])

        let (regions, _) = TieBreak.analyze(
            appleTokens: aTokens, whisperTokens: wTokens, refTokens: rTokens,
            appleWords: aWords, whisperWords: wWords, refWords: rWords
        )

        // Should be one merged region (spanning the x/p and y/q disagreements with c in between).
        #expect(regions.count == 1)
    }

    @Test("Sampling: returns at most 30 regions")
    func sampling() {
        // Build 50 dummy regions.
        var regions: [DisagreementRegion] = []
        for i in 0..<50 {
            regions.append(DisagreementRegion(
                whisperRange: (i, i + 1), appleRange: (i, i + 1), refRange: (i, i + 1),
                classification: .neither, appleDistance: 1, whisperDistance: 1,
                size: 50 - i, appleText: "a", whisperText: "w", refText: "r"
            ))
        }

        let sampled = TieBreak.sample(regions)
        #expect(sampled.count == 30) // 15 largest + 15 random
    }
}

import Foundation
@testable import STTLabAnalysis
import Testing

@Suite("SpeakerMetrics")
struct SpeakerMetricsTests {

    // MARK: - Time agreement

    @Test("Time agreement with perfect overlap")
    func timeAgreementPerfect() {
        // Two aligned transcripts with identical segments.
        let seg = AlignedSegment(speaker: 0, start: 0, end: 1.0, text: "hello", wordCount: 1)
        let a = AlignedTranscript(engine: .apple, segments: [seg], words: [])
        let b = AlignedTranscript(engine: .whisper, segments: [seg], words: [])

        let (agreement, covA, covB) = SpeakerMetrics.timeAgreement(a: a, b: b, audioDuration: 1.0)

        #expect(agreement == 1.0)
        #expect(covA == 1.0)
        #expect(covB == 1.0)
    }

    @Test("Time agreement with no overlap")
    func timeAgreementNoOverlap() {
        let a = AlignedTranscript(
            engine: .apple,
            segments: [AlignedSegment(speaker: 0, start: 0, end: 0.5, text: "a", wordCount: 1)],
            words: []
        )
        let b = AlignedTranscript(
            engine: .whisper,
            segments: [AlignedSegment(speaker: 1, start: 0.5, end: 1.0, text: "b", wordCount: 1)],
            words: []
        )

        let (agreement, covA, covB) = SpeakerMetrics.timeAgreement(a: a, b: b, audioDuration: 1.0)

        // No grid points where both are labelled.
        #expect(agreement == nil)
        #expect(covA! > 0)
        #expect(covB! > 0)
    }

    @Test("Time agreement with different speakers")
    func timeAgreementDifferentSpeakers() {
        // Both cover the full duration but with different speakers.
        let a = AlignedTranscript(
            engine: .apple,
            segments: [AlignedSegment(speaker: 0, start: 0, end: 1.0, text: "a", wordCount: 1)],
            words: []
        )
        let b = AlignedTranscript(
            engine: .whisper,
            segments: [AlignedSegment(speaker: 1, start: 0, end: 1.0, text: "b", wordCount: 1)],
            words: []
        )

        let (agreement, _, _) = SpeakerMetrics.timeAgreement(a: a, b: b, audioDuration: 1.0)

        #expect(agreement == 0.0)
    }

    @Test("Time agreement partial overlap")
    func timeAgreementPartial() {
        // A: speaker 0 for 0-0.5, speaker 1 for 0.5-1.0
        // B: speaker 0 for 0-1.0
        // Agreement should be 50%
        let a = AlignedTranscript(
            engine: .apple,
            segments: [
                AlignedSegment(speaker: 0, start: 0, end: 0.5, text: "a", wordCount: 1),
                AlignedSegment(speaker: 1, start: 0.5, end: 1.0, text: "b", wordCount: 1),
            ],
            words: []
        )
        let b = AlignedTranscript(
            engine: .whisper,
            segments: [AlignedSegment(speaker: 0, start: 0, end: 1.0, text: "ab", wordCount: 2)],
            words: []
        )

        let (agreement, _, _) = SpeakerMetrics.timeAgreement(a: a, b: b, audioDuration: 1.0)

        // Expect ~50% agreement.
        #expect(agreement! > 0.45)
        #expect(agreement! < 0.55)
    }

    // MARK: - Word agreement

    @Test("Word agreement perfect match")
    func wordAgreementPerfect() {
        let ops: [EditOp] = [.match(0, 0), .match(1, 1)]
        let aToks = [NormToken(text: "hello", sourceIndex: 0), NormToken(text: "world", sourceIndex: 1)]
        let bToks = [NormToken(text: "hello", sourceIndex: 0), NormToken(text: "world", sourceIndex: 1)]
        let aWords = [
            AlignedWord(word: EngineWord(text: "hello", segmentIndex: 0), speaker: 0),
            AlignedWord(word: EngineWord(text: "world", segmentIndex: 0), speaker: 0),
        ]
        let bWords = [
            AlignedWord(word: EngineWord(text: "hello", segmentIndex: 0), speaker: 0),
            AlignedWord(word: EngineWord(text: "world", segmentIndex: 0), speaker: 0),
        ]

        let result = SpeakerMetrics.wordAgreement(
            opsAB: ops, aTokens: aToks, bTokens: bToks,
            aWords: aWords, bWords: bWords
        )

        #expect(result == 1.0)
    }

    @Test("Word agreement with disagreement")
    func wordAgreementDisagreement() {
        let ops: [EditOp] = [.match(0, 0), .match(1, 1)]
        let aToks = [NormToken(text: "hello", sourceIndex: 0), NormToken(text: "world", sourceIndex: 1)]
        let bToks = [NormToken(text: "hello", sourceIndex: 0), NormToken(text: "world", sourceIndex: 1)]
        let aWords = [
            AlignedWord(word: EngineWord(text: "hello", segmentIndex: 0), speaker: 0),
            AlignedWord(word: EngineWord(text: "world", segmentIndex: 0), speaker: 1),
        ]
        let bWords = [
            AlignedWord(word: EngineWord(text: "hello", segmentIndex: 0), speaker: 0),
            AlignedWord(word: EngineWord(text: "world", segmentIndex: 0), speaker: 0),
        ]

        let result = SpeakerMetrics.wordAgreement(
            opsAB: ops, aTokens: aToks, bTokens: bToks,
            aWords: aWords, bWords: bWords
        )

        #expect(result == 0.5)
    }

    // MARK: - Segment stats

    @Test("Segment stats basic")
    func segmentStatsBasic() {
        let t = AlignedTranscript(
            engine: .apple,
            segments: [
                AlignedSegment(speaker: 0, start: 0, end: 2.0, text: "a b", wordCount: 2),
                AlignedSegment(speaker: 1, start: 2.0, end: 5.0, text: "c d e", wordCount: 3),
                AlignedSegment(speaker: 1, start: 5.0, end: 6.0, text: "f", wordCount: 1),
            ],
            words: []
        )

        let stats = SpeakerMetrics.segmentStats(t)

        #expect(stats.segmentCount == 3)
        #expect(stats.turnCount == 2)  // 0 -> 1, then stays 1
        #expect(stats.speakerChanges == 1)
        #expect(stats.maxWordCount == 3)
    }

    @Test("Segment stats empty")
    func segmentStatsEmpty() {
        let t = AlignedTranscript(engine: .apple, segments: [], words: [])
        let stats = SpeakerMetrics.segmentStats(t)

        #expect(stats.segmentCount == 0)
        #expect(stats.turnCount == 0)
    }

    // MARK: - Disagreement sample

    @Test("Disagreement sample finds runs")
    func disagreementSampleFindsRuns() {
        // 4 matched pairs: pairs 1 and 2 have different speakers.
        let ops: [EditOp] = [.match(0, 0), .match(1, 1), .match(2, 2), .match(3, 3)]
        let toks = (0..<4).map { NormToken(text: "w\($0)", sourceIndex: $0) }
        let aWords = [
            AlignedWord(word: EngineWord(text: "w0", start: 0, end: 0.5, segmentIndex: 0), speaker: 0),
            AlignedWord(word: EngineWord(text: "w1", start: 0.5, end: 1.0, segmentIndex: 0), speaker: 0),
            AlignedWord(word: EngineWord(text: "w2", start: 1.0, end: 1.5, segmentIndex: 0), speaker: 1),
            AlignedWord(word: EngineWord(text: "w3", start: 1.5, end: 2.0, segmentIndex: 0), speaker: 1),
        ]
        let bWords = [
            AlignedWord(word: EngineWord(text: "w0", start: 0, end: 0.5, segmentIndex: 0), speaker: 0),
            AlignedWord(word: EngineWord(text: "w1", start: 0.5, end: 1.0, segmentIndex: 0), speaker: 1),
            AlignedWord(word: EngineWord(text: "w2", start: 1.0, end: 1.5, segmentIndex: 0), speaker: 1),
            AlignedWord(word: EngineWord(text: "w3", start: 1.5, end: 2.0, segmentIndex: 0), speaker: 1),
        ]
        let engine = aWords.map(\.word)

        let runs = SpeakerMetrics.disagreementSample(
            opsAB: ops, aTokens: toks, bTokens: toks,
            aWords: aWords, bWords: bWords,
            aEngine: engine, bEngine: engine,
            diarizationBoundaries: [0.5, 1.0]
        )

        // Pairs 1 has speakers (0, 1) — disagreement.
        // Pair 2 has speakers (1, 1) — agreement. Breaks the run.
        // So we expect 1 run with 1 word.
        #expect(runs.count == 1)
        #expect(runs[0].wordCount == 1)
        #expect(runs[0].words == "w1")
    }
}

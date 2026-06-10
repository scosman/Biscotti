import Testing
import Transcription

// MARK: - Diarization evaluator tests

@Suite("DiarizationGroundTruth.evaluate")
struct DiarizationEvaluatorTests {
    @Test("passes with correct 3-chunk, 3-speaker, matching transcript")
    func passCase() {
        let result = makeDiarizationResult(
            speakers: [0, 1, 2],
            texts: [
                "Hello, this is a test of the system.",
                "Hello, I am person number two. I am saying something back.",
                "Hi, I'm person number three and you two are banana heads."
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(eval.passed)
        #expect(eval.chunkCount == 3)
        #expect(eval.distinctSpeakers == 3)
        #expect(eval.perChunkRatios.count == 3)
        #expect(eval.perChunkRatios.allSatisfy { $0 <= GroundTruth.chunkLevenshteinTolerance })
    }

    @Test("passes with minor text differences within tolerance")
    func passWithMinorDifferences() {
        // "systm" instead of "system" => 1 char difference in ~36 chars = ~0.028 ratio
        let result = makeDiarizationResult(
            speakers: [0, 1, 2],
            texts: [
                "Hello, this is a test of the systm.",
                "Hello, I am person number two. I am saying something back.",
                "Hi, I'm person number three and you two are banana heads."
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(eval.passed)
    }

    @Test("fails when chunk count is not 3")
    func wrongChunkCount() {
        let result = makeDiarizationResult(
            speakers: [0, 1],
            texts: ["Hello", "World"]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.chunkCount == 2)
        #expect(eval.detail.contains("Expected 3 chunks"))
    }

    @Test("fails when too many chunks")
    func tooManyChunks() {
        let result = makeDiarizationResult(
            speakers: [0, 1, 2, 3],
            texts: ["A", "B", "C", "D"]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.chunkCount == 4)
    }

    @Test("fails when speakers are not distinct (A/B/A pattern)")
    func nonDistinctSpeakers() {
        let result = makeDiarizationResult(
            speakers: [0, 1, 0],
            texts: [
                "Hello, this is a test of the system.",
                "Hello, I am person number two. I am saying something back.",
                "Hi, I'm person number three and you two are banana heads."
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.distinctSpeakers == 2)
        #expect(eval.detail.contains("Expected 3 distinct speakers"))
    }

    @Test("fails when all segments have the same speaker")
    func singleSpeaker() {
        let result = makeDiarizationResult(
            speakers: [0, 0, 0],
            texts: [
                "Hello, this is a test of the system.",
                "Hello, I am person number two. I am saying something back.",
                "Hi, I'm person number three and you two are banana heads."
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(!eval.passed)
        // Same speaker => merged into 1 chunk
        #expect(eval.chunkCount == 1)
    }

    @Test("fails when Levenshtein ratio exceeds tolerance")
    func highLevenshtein() {
        let result = makeDiarizationResult(
            speakers: [0, 1, 2],
            texts: [
                "Completely wrong transcript that does not match at all.",
                "Hello, I am person number two. I am saying something back.",
                "Hi, I'm person number three and you two are banana heads."
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.chunkCount == 3)
        #expect(eval.distinctSpeakers == 3)
        #expect(eval.perChunkRatios[0] > GroundTruth.chunkLevenshteinTolerance)
        #expect(eval.detail.contains("chunk[0]"))
        #expect(eval.detail.contains("ratio="))
    }

    @Test("reports non-zero per-chunk ratios when passing within tolerance")
    func ratiosReportedNonZero() {
        // Introduce a small typo in chunk 0 ("systm" -> missing 'e') and
        // chunk 2 ("bnana" -> missing 'a'). Both are within the 0.05 tolerance.
        let result = makeDiarizationResult(
            speakers: [0, 1, 2],
            texts: [
                "Hello, this is a test of the systm.",
                "Hello, I am person number two. I am saying something back.",
                "Hi, I'm person number three and you two are bnana heads."
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(eval.passed)
        #expect(eval.perChunkRatios.count == 3)
        // Chunk 0 and 2 should have small but non-zero ratios
        #expect(eval.perChunkRatios[0] > 0.0)
        #expect(eval.perChunkRatios[0] <= GroundTruth.chunkLevenshteinTolerance)
        // Chunk 1 is exact match
        #expect(eval.perChunkRatios[1] == 0.0)
        // Chunk 2 has a small difference
        #expect(eval.perChunkRatios[2] > 0.0)
        #expect(eval.perChunkRatios[2] <= GroundTruth.chunkLevenshteinTolerance)
    }
}

// MARK: - Vocab evaluator tests

@Suite("VocabGroundTruth.evaluate")
struct VocabEvaluatorTests {
    @Test("passes when all 10 terms are present")
    func allPresent() {
        let text = "NASA Kubernetes Postgres Qwen Mistral Llama Croissant gnocci Paella Facade"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(eval.passed)
        #expect(eval.matched.count == 10)
        #expect(eval.missed.isEmpty)
        #expect(eval.detail.contains("All 10"))
    }

    @Test("fails when some terms are missing")
    func partialMatch() {
        let text = "NASA Kubernetes Postgres Qwen"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.matched.count == 4)
        #expect(eval.missed.count == 6)
        #expect(eval.detail.contains("Missed:"))
    }

    @Test("fails when no terms are present")
    func nonePresent() {
        let text = "hello world nothing matches here"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.matched.isEmpty)
        #expect(eval.missed.count == 10)
    }

    @Test("matches are case-insensitive")
    func caseInsensitive() {
        let text = "nasa kubernetes postgres qwen mistral llama croissant gnocci paella facade"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(eval.passed)
    }

    @Test("handles terms surrounded by punctuation")
    func punctuationHandled() {
        let text = "NASA, Kubernetes; Postgres! Qwen. Mistral: Llama, Croissant, gnocci, Paella, Facade."
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(eval.passed)
    }

    @Test("concatenates all segment texts for matching")
    func multipleSegments() {
        let result = TranscriptResult(
            transcriptionMethodId: "test",
            language: "en",
            speakerCount: 1,
            segments: [
                TranscriptSegment(
                    speakerID: 0, speakerLabel: "Speaker 0",
                    startTime: 0, endTime: 1,
                    text: "NASA Kubernetes Postgres Qwen Mistral",
                    confidence: 0, noSpeechProbability: 0, words: nil
                ),
                TranscriptSegment(
                    speakerID: 0, speakerLabel: "Speaker 0",
                    startTime: 1, endTime: 2,
                    text: "Llama Croissant gnocci Paella Facade",
                    confidence: 0, noSpeechProbability: 0, words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 0
        )
        let eval = VocabGroundTruth.evaluate(result)
        #expect(eval.passed)
    }
}

// MARK: - Test helpers

/// Build a TranscriptResult with one segment per speaker, for diarization tests.
private func makeDiarizationResult(
    speakers: [Int], texts: [String]
) -> TranscriptResult {
    var segments: [TranscriptSegment] = []
    for (idx, (speaker, text)) in zip(speakers, texts).enumerated() {
        segments.append(TranscriptSegment(
            speakerID: speaker,
            speakerLabel: "Speaker \(speaker)",
            startTime: Double(idx) * 3.0,
            endTime: Double(idx) * 3.0 + 2.5,
            text: text,
            confidence: 0,
            noSpeechProbability: 0,
            words: nil
        ))
    }
    return TranscriptResult(
        transcriptionMethodId: "test",
        language: "en",
        speakerCount: Set(speakers).count,
        segments: segments,
        speakerEmbeddings: [:],
        processingDuration: 0
    )
}

/// Build a single-segment TranscriptResult for vocab tests.
private func makeVocabResult(text: String) -> TranscriptResult {
    TranscriptResult(
        transcriptionMethodId: "test",
        language: "en",
        speakerCount: 1,
        segments: [
            TranscriptSegment(
                speakerID: 0,
                speakerLabel: "Speaker 0",
                startTime: 0,
                endTime: 5,
                text: text,
                confidence: 0,
                noSpeechProbability: 0,
                words: nil
            )
        ],
        speakerEmbeddings: [:],
        processingDuration: 0
    )
}

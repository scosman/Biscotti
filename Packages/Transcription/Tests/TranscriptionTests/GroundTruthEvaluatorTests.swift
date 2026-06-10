import Testing
import Transcription

// MARK: - Diarization evaluator tests

@Suite("DiarizationGroundTruth.evaluate")
struct DiarizationEvaluatorTests {
    // The ground truth has 9 segments across 3 speakers in pattern [A,B,A,B,C]
    // (speaker sequence: 0,0,1,1,0,1,2,2,2 → after adjacency merge → 5 chunks).

    @Test("passes with correct 5-chunk, 3-speaker, interleaved transcript")
    func passCase() {
        let result = makeDiarizationResult(
            segments: [
                (speaker: 0, text: "This is a thing we actually need to do that's important."),
                (speaker: 0, text: "I'm going to talk for a second and then I'm going to hand it over to James who's going to say something regular and not in a weird voice."),
                (speaker: 1, text: "Banana,"),
                (speaker: 1, text: "banana."),
                (speaker: 0, text: "Say something for real James."),
                (speaker: 1, text: "Okay, fine my banana head."),
                (speaker: 2, text: "And what would you like me to say?"),
                (speaker: 2, text: "Anything at all."),
                (speaker: 2, text: "I would like more food please.")
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(eval.passed)
        #expect(eval.chunkCount == 5)
        #expect(eval.distinctSpeakers == 3)
        #expect(eval.perChunkRatios.count == 5)
        #expect(eval.perChunkRatios.allSatisfy { $0 <= GroundTruth.chunkLevenshteinTolerance })
    }

    @Test("passes with minor text differences within tolerance")
    func passWithMinorDifferences() {
        // "importnt" instead of "important" => 1 char difference in a long string
        let result = makeDiarizationResult(
            segments: [
                (speaker: 0, text: "This is a thing we actually need to do that's importnt."),
                (speaker: 0, text: "I'm going to talk for a second and then I'm going to hand it over to James who's going to say something regular and not in a weird voice."),
                (speaker: 1, text: "Banana,"),
                (speaker: 1, text: "banana."),
                (speaker: 0, text: "Say something for real James."),
                (speaker: 1, text: "Okay, fine my banana head."),
                (speaker: 2, text: "And what would you like me to say?"),
                (speaker: 2, text: "Anything at all."),
                (speaker: 2, text: "I would like more food please.")
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(eval.passed)
    }

    @Test("fails when chunk count is wrong (too few)")
    func wrongChunkCount() {
        let result = makeDiarizationResult(
            segments: [
                (speaker: 0, text: "Hello"),
                (speaker: 1, text: "World")
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.chunkCount == 2)
        #expect(eval.detail.contains("Expected 5 chunks"))
        // Diagnostic: chunk text and raw transcript are surfaced
        #expect(eval.detail.contains("text=\"Hello\""))
        #expect(eval.detail.contains("text=\"World\""))
        #expect(eval.detail.contains("Raw transcript:"))
    }

    @Test("fails when too many chunks")
    func tooManyChunks() {
        let result = makeDiarizationResult(
            segments: [
                (speaker: 0, text: "A"),
                (speaker: 1, text: "B"),
                (speaker: 2, text: "C"),
                (speaker: 3, text: "D"),
                (speaker: 4, text: "E"),
                (speaker: 5, text: "F")
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.chunkCount == 6)
        // Diagnostic: chunk text and raw transcript are surfaced
        #expect(eval.detail.contains("text=\"A\""))
        #expect(eval.detail.contains("Raw transcript: \"A B C D E F\""))
    }

    @Test("fails when speaker pattern does not match (wrong interleaving)")
    func wrongPattern() {
        // Pattern [A,B,C,B,C] instead of [A,B,A,B,C]
        // Canonical: [0,1,2,1,2] vs expected [0,1,0,1,2]
        let result = makeDiarizationResult(
            segments: [
                (speaker: 0, text: "This is a thing we actually need to do that's important. I'm going to talk for a second and then I'm going to hand it over to James who's going to say something regular and not in a weird voice."),
                (speaker: 1, text: "Banana, banana."),
                (speaker: 2, text: "Say something for real James."),
                (speaker: 1, text: "Okay, fine my banana head."),
                (speaker: 2, text: "And what would you like me to say? Anything at all. I would like more food please.")
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.detail.contains("Speaker pattern mismatch"))
        #expect(eval.detail.contains("[0, 1, 2, 1, 2]"))
        // Diagnostic: chunk text and raw transcript are surfaced
        #expect(eval.detail.contains("text=\"Banana, banana.\""))
        #expect(eval.detail.contains("Raw transcript:"))
    }

    @Test("fails when only 2 distinct speakers (A/B/A/B/A pattern)")
    func twoSpeakers() {
        // Pattern [A,B,A,B,A] → canonical [0,1,0,1,0] — only 2 distinct
        let result = makeDiarizationResult(
            segments: [
                (speaker: 0, text: "This is a thing we actually need to do that's important. I'm going to talk for a second and then I'm going to hand it over to James who's going to say something regular and not in a weird voice."),
                (speaker: 1, text: "Banana, banana."),
                (speaker: 0, text: "Say something for real James."),
                (speaker: 1, text: "Okay, fine my banana head."),
                (speaker: 0, text: "And what would you like me to say? Anything at all. I would like more food please.")
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.detail.contains("Speaker pattern mismatch"))
        #expect(eval.distinctSpeakers == 2)
        // Diagnostic: chunk text and raw transcript are surfaced
        #expect(eval.detail.contains("text="))
        #expect(eval.detail.contains("Raw transcript:"))
    }

    @Test("fails when all segments have the same speaker (merges to 1 chunk)")
    func singleSpeaker() {
        let result = makeDiarizationResult(
            segments: [
                (speaker: 0, text: "A"),
                (speaker: 0, text: "B"),
                (speaker: 0, text: "C")
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(!eval.passed)
        // Same speaker => merged into 1 chunk
        #expect(eval.chunkCount == 1)
        // Diagnostic: merged chunk text and raw transcript are surfaced
        #expect(eval.detail.contains("text=\"A B C\""))
        #expect(eval.detail.contains("Raw transcript: \"A B C\""))
    }

    @Test("fails when Levenshtein ratio exceeds tolerance")
    func highLevenshtein() {
        // Correct pattern but wrong text in chunk 0
        let result = makeDiarizationResult(
            segments: [
                (speaker: 0, text: "Completely wrong transcript that does not match at all and keeps going to be long enough."),
                (speaker: 0, text: "Still wrong and not matching the expected ground truth text at all."),
                (speaker: 1, text: "Banana,"),
                (speaker: 1, text: "banana."),
                (speaker: 0, text: "Say something for real James."),
                (speaker: 1, text: "Okay, fine my banana head."),
                (speaker: 2, text: "And what would you like me to say?"),
                (speaker: 2, text: "Anything at all."),
                (speaker: 2, text: "I would like more food please.")
            ]
        )
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.chunkCount == 5)
        #expect(eval.distinctSpeakers == 3)
        #expect(eval.perChunkRatios[0] > GroundTruth.chunkLevenshteinTolerance)
        #expect(eval.detail.contains("chunk[0]"))
        #expect(eval.detail.contains("ratio="))
    }

    @Test("canonical pattern helper produces first-occurrence indices")
    func canonicalPatternHelper() {
        #expect(DiarizationGroundTruth.canonicalPattern(["A", "B", "A", "B", "C"]) == [0, 1, 0, 1, 2])
        #expect(DiarizationGroundTruth.canonicalPattern([7, 3, 7, 3, 9]) == [0, 1, 0, 1, 2])
        #expect(DiarizationGroundTruth.canonicalPattern([5, 5, 5]) == [0, 0, 0])
        #expect(DiarizationGroundTruth.canonicalPattern([Int]()) == [])
    }
}

// MARK: - Vocab evaluator tests

@Suite("VocabGroundTruth.evaluate")
struct VocabEvaluatorTests {
    @Test("passes when all 3 terms are present")
    func allPresent() {
        let text = "gnocci facade qwen"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(eval.passed)
        #expect(eval.matched.count == 3)
        #expect(eval.missed.isEmpty)
        #expect(eval.detail.contains("All 3"))
    }

    @Test("fails when some terms are missing")
    func partialMatch() {
        let text = "gnocci facade"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.matched.count == 2)
        #expect(eval.missed.count == 1)
        #expect(eval.detail.contains("Missed:"))
        // Diagnostic: actual transcript text is surfaced
        #expect(eval.detail.contains("Transcript: \"gnocci facade\""))
    }

    @Test("fails when no terms are present")
    func nonePresent() {
        let text = "hello world nothing matches here"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.matched.isEmpty)
        #expect(eval.missed.count == 3)
        // Diagnostic: actual transcript text is surfaced
        #expect(eval.detail.contains("Transcript: \"hello world nothing matches here\""))
    }

    @Test("matches are case-insensitive")
    func caseInsensitive() {
        let text = "Gnocci FACADE Qwen"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(eval.passed)
    }

    @Test("handles terms surrounded by punctuation")
    func punctuationHandled() {
        let text = "gnocci, facade; qwen."
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
                    text: "gnocci facade",
                    confidence: 0, noSpeechProbability: 0, words: nil
                ),
                TranscriptSegment(
                    speakerID: 0, speakerLabel: "Speaker 0",
                    startTime: 1, endTime: 2,
                    text: "qwen",
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

/// Build a TranscriptResult from segment tuples, for diarization tests.
/// Each segment gets a unique time slot so the chunker can sort them.
private func makeDiarizationResult(
    segments segmentData: [(speaker: Int, text: String)]
) -> TranscriptResult {
    var segments: [TranscriptSegment] = []
    for (idx, seg) in segmentData.enumerated() {
        segments.append(TranscriptSegment(
            speakerID: seg.speaker,
            speakerLabel: "Speaker \(seg.speaker)",
            startTime: Double(idx) * 3.0,
            endTime: Double(idx) * 3.0 + 2.5,
            text: seg.text,
            confidence: 0,
            noSpeechProbability: 0,
            words: nil
        ))
    }
    return TranscriptResult(
        transcriptionMethodId: "test",
        language: "en",
        speakerCount: Set(segmentData.map(\.speaker)).count,
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

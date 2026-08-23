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
        // Full transcript diagnostics
        #expect(eval.detail.contains("Actual transcript:"))
        #expect(eval.detail.contains("Expected transcript:"))
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
        // Full transcript diagnostics
        #expect(eval.detail.contains("Actual transcript:"))
        #expect(eval.detail.contains("Expected transcript:"))
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
        // Full transcript diagnostics
        #expect(eval.detail.contains("Actual transcript:"))
        #expect(eval.detail.contains("Expected transcript:"))
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
        // Full transcript diagnostics
        #expect(eval.detail.contains("Actual transcript:"))
        #expect(eval.detail.contains("Expected transcript:"))
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
        // Full transcript diagnostics
        #expect(eval.detail.contains("Actual transcript:"))
        #expect(eval.detail.contains("Expected transcript:"))
    }

    @Test("canonical pattern helper produces first-occurrence indices")
    func canonicalPatternHelper() {
        #expect(DiarizationGroundTruth.canonicalPattern(["A", "B", "A", "B", "C"]) == [0, 1, 0, 1, 2])
        #expect(DiarizationGroundTruth.canonicalPattern([7, 3, 7, 3, 9]) == [0, 1, 0, 1, 2])
        #expect(DiarizationGroundTruth.canonicalPattern([5, 5, 5]) == [0, 0, 0])
        #expect(DiarizationGroundTruth.canonicalPattern([Int]()) == [])
    }
}

// MARK: - Transcript accuracy evaluator tests

@Suite("TranscriptAccuracyGroundTruth.evaluate")
struct TranscriptAccuracyEvaluatorTests {
    @Test("passes when transcript matches exactly")
    func passExact() {
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
        let eval = TranscriptAccuracyGroundTruth.evaluate(result)
        #expect(eval.passed)
        #expect(eval.ratio < 0.01) // essentially 0 for exact match
    }

    @Test("fails when transcript text is substantially wrong")
    func failWrongText() {
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
        let eval = TranscriptAccuracyGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.ratio > GroundTruth.transcriptAccuracyTolerance)
        #expect(eval.detail.contains("exceeds tolerance"))
        #expect(eval.detail.contains("Actual transcript:"))
        #expect(eval.detail.contains("Expected transcript:"))
    }

    @Test("passes when text is correct but attributed to wrong speakers")
    func passWithMisattribution() {
        // Same text in the same order, but speakers 0 and 1 are swapped.
        // Diarization checks speaker structure; transcript accuracy must pass
        // regardless of speaker assignment.
        let result = makeDiarizationResult(
            segments: [
                (speaker: 1, text: "This is a thing we actually need to do that's important."),
                (speaker: 1, text: "I'm going to talk for a second and then I'm going to hand it over to James who's going to say something regular and not in a weird voice."),
                (speaker: 0, text: "Banana,"),
                (speaker: 0, text: "banana."),
                (speaker: 1, text: "Say something for real James."),
                (speaker: 0, text: "Okay, fine my banana head."),
                (speaker: 2, text: "And what would you like me to say?"),
                (speaker: 2, text: "Anything at all."),
                (speaker: 2, text: "I would like more food please.")
            ]
        )
        let eval = TranscriptAccuracyGroundTruth.evaluate(result)
        #expect(eval.passed, "Mis-attribution should not affect transcript accuracy: \(eval.detail)")
        #expect(eval.ratio < 0.01)
    }
}

// MARK: - Vocab evaluator tests

@Suite("VocabGroundTruth.evaluate")
struct VocabEvaluatorTests {
    @Test("passes when all 10 terms are present")
    func allPresent() {
        let text = "NASA Kubernetes Postgres Qwen Mistral Llama Croissant Gnocchi Paella Facade"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(eval.passed)
        #expect(eval.matched.count == 10)
        #expect(eval.missed.isEmpty)
        #expect(eval.detail.contains("10/10"))
    }

    @Test("passes at threshold with 1 term missed (9/10)")
    func passesAtThreshold() {
        // 9 of 10 terms — meets the 90% threshold
        let text = "NASA Kubernetes Postgres Qwen Mistral Croissant Gnocchi Paella Facade"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(eval.passed)
        #expect(eval.matched.count == 9)
        #expect(eval.missed == ["Llama"])
    }

    @Test("fails when terms are wholly absent")
    func missingTermsFail() {
        let text = "Gnocchi Facade"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.matched.count == 2)
        #expect(eval.missed.count == 8)
        #expect(eval.detail.contains("Missed:"))
        // Diagnostic: actual transcript text and expected vocab are surfaced
        #expect(eval.detail.contains("Expected vocab:"))
        #expect(eval.detail.contains("Transcript: \"Gnocchi Facade\""))
    }

    @Test("fails when no terms are present")
    func nonePresent() {
        let text = "hello world nothing matches here"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(!eval.passed)
        #expect(eval.matched.isEmpty)
        #expect(eval.missed.count == 10)
        // Diagnostic: actual transcript text and expected vocab are surfaced
        #expect(eval.detail.contains("Expected vocab:"))
        #expect(eval.detail.contains("Transcript: \"hello world nothing matches here\""))
    }

    @Test("matches are case-insensitive")
    func caseInsensitive() {
        let text = "NASA KUBERNETES POSTGRES QWEN MISTRAL LLAMA CROISSANT GNOCCHI PAELLA FACADE"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        #expect(eval.passed)
    }

    @Test("handles terms surrounded by punctuation")
    func punctuationHandled() {
        let text = "nasa, kubernetes; postgres. qwen! mistral? llama: croissant, gnocchi; paella. facade!"
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
                    text: "Llama Croissant Gnocchi Paella Facade",
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

// MARK: - Regression fixtures (from on-hardware diagnostic runs)

@Suite("Vocab regression fixtures (from on-hardware diagnostic runs)")
struct VocabRegressionTests {
    /// Negative control: the actual transcript from a lowercase-vocab diagnostic
    /// run where "nasa" was systematically dropped due to a first-token decoder
    /// interaction. Asserts only that NASA is in the missed set — does not pin
    /// the full missed set or exact counts, so the fixture survives unrelated
    /// ground-truth edits.
    ///
    /// Provenance: this transcript was captured from a real `transcribe-cli` run
    /// with lowercased vocab terms. The lowercasing defect drops only the first
    /// prompt term; a future regression would produce one miss (NASA). This
    /// historical transcript also has a second miss ("gnocci" vs ground-truth
    /// "Gnocchi") because the old fixture contained a typo that the model
    /// mirrored — that typo is now fixed, so a recurrence would not repeat it.
    @Test("lowercase-vocab transcript reports NASA as missed")
    func lowercaseVocabDropsFirstTerm() {
        // Real transcript from diagnostic C (lowercase vocab, nasa first).
        // The "gnocci" misspelling is part of the historical artifact — do not
        // "fix" it; the model produced this verbatim from the old misspelled prompt.
        let text = " kubernetes,  postgres,  qwen, mistral,  llama,  croissant,  gnocci,  paella, facade."
        let (_, missed) = WordMatch.evaluate(
            transcript: text,
            expected: GroundTruth.vocabTerms
        )
        #expect(missed.contains("NASA"), "NASA should be missed, got: \(missed)")
    }

    /// Documents the exact non-determinism the threshold absorbs: in diagnostic
    /// D (5 consistency runs, proper casing), 2/5 produced "Llami" instead of
    /// "Llama". With exact matching, "Llami" is a miss — Llama lands in the
    /// missed set. The 9/10 threshold allows this, so the overall evaluation
    /// still passes.
    @Test("Llami non-determinism: Llama missed but evaluation passes on threshold")
    func llamiNonDeterminismPassesOnThreshold() {
        let text = "NASA Kubernetes Postgres Qwen Mistral Llami Croissant Gnocchi Paella Facade"
        let result = makeVocabResult(text: text)
        let eval = VocabGroundTruth.evaluate(result)
        // Llama is genuinely missed (exact matching, no fuzzy tolerance)
        #expect(eval.missed.contains("Llama"), "Llama should be missed, got: \(eval.missed)")
        // But the evaluation passes on the 9/10 threshold
        #expect(eval.passed, "9/10 should pass the threshold: \(eval.detail)")
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

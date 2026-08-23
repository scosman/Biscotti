import Foundation
import Transcription

// MARK: - Reference data

/// A single chunk of the ground-truth transcript, identified by speaker label.
struct ReferenceChunk: Equatable {
    let speakerLabel: String
    let script: String
}

/// Canonical ground truth for the AI test set reference clips.
///
/// The five speaker chunks (3 distinct speakers, interleaved) and vocabulary
/// terms are derived from confirmed transcriptions of the reference audio
/// (see functional spec section 1). Adjacent same-speaker segments are merged
/// by `TranscriptChunker`, yielding the pattern [A, B, A, B, C].
enum GroundTruth {
    /// The 3-speaker reference transcript, chunked by speaker (adjacency-merged).
    /// Pattern: [A, B, A, B, C] — 5 chunks, 3 distinct speakers.
    static let chunks: [ReferenceChunk] = [
        .init(
            speakerLabel: "A",
            script: "This is a thing we actually need to do that's important."
                + " I'm going to talk for a second and then I'm going to hand it over to James"
                + " who's going to say something regular and not in a weird voice."
        ),
        .init(speakerLabel: "B", script: "Banana, banana."),
        .init(speakerLabel: "A", script: "Say something for real James."),
        .init(speakerLabel: "B", script: "Okay, fine my banana head."),
        .init(
            speakerLabel: "C",
            script: "And what would you like me to say? Anything at all."
                + " I would like more food please."
        )
    ]

    /// Maximum normalized Levenshtein ratio for the full concatenated transcript
    /// (speaker-agnostic). A single constant so it's easy to tune after a
    /// hardware run — the AI test diagnostics print the actual ratio on failure.
    static let transcriptAccuracyTolerance = 0.05

    /// Custom vocabulary terms for the vocab-bias test clip.
    ///
    /// The full 10-term list from the reference audio, used by the
    /// `customVocabWordMatch` AI test to verify promptTokens biasing.
    /// The blanking bug that previously disabled this test was fixed in
    /// argmax-oss-swift v1.1.0 (PR #514).
    ///
    /// Terms use natural casing. The v1.0.0 blanking bug required
    /// lowercasing as a workaround; with the v1.1.0 fix, preserving
    /// case improves recognition accuracy and avoids a residual
    /// first-token interaction where lowercase "nasa" as the first
    /// prompt term was systematically dropped.
    static let vocabTerms = [
        "NASA", "Kubernetes", "Postgres", "Qwen", "Mistral",
        "Llama", "Croissant", "Gnocchi", "Paella", "Facade"
    ]
}

// MARK: - Diarization evaluator

/// Result of evaluating diarization structure against the 3-speaker ground truth.
/// Checks speaker structure only (chunk count, distinct speakers, interleaving
/// pattern) — text accuracy is checked separately by ``TranscriptAccuracyGroundTruth``.
struct DiarizationEvaluation {
    let chunkCount: Int
    let distinctSpeakers: Int
    let passed: Bool
    let detail: String
}

/// Evaluates a `TranscriptResult` against the 3-speaker diarization ground truth.
///
/// Checks structure only: (1) chunk count == 5 (adjacency-merged),
/// (2) speaker-equivalence pattern matches [A,B,A,B,C] (enforces 3 distinct
/// speakers + interleaving). Text accuracy is a separate concern — see
/// ``TranscriptAccuracyGroundTruth``.
enum DiarizationGroundTruth {
    /// The expected canonical first-occurrence pattern from the reference labels.
    /// Labels [A,B,A,B,C] → first-occurrence indices [0,1,0,1,2].
    static let expectedPattern: [Int] = canonicalPattern(
        GroundTruth.chunks.map(\.speakerLabel)
    )

    static func evaluate(_ result: TranscriptResult) -> DiarizationEvaluation {
        let chunks = TranscriptChunker.chunks(from: result)
        let chunkCount = chunks.count
        let speakerIDs = chunks.compactMap(\.speakerID)
        let distinctSpeakers = Set(speakerIDs).count
        let rawTranscript = result.segments.map(\.text).joined(separator: " ")

        let expectedCount = GroundTruth.chunks.count

        guard chunkCount == expectedCount else {
            let chunkSummary = chunkDiagnostic(chunks)
            let base = "Expected \(expectedCount) chunks, got \(chunkCount). "
                + "[\(chunkSummary)]. "
                + "Raw transcript: \"\(rawTranscript)\""
            return DiarizationEvaluation(
                chunkCount: chunkCount,
                distinctSpeakers: distinctSpeakers,
                passed: false,
                detail: appendFullTranscripts(to: base, chunks: chunks)
            )
        }

        let actualPattern = canonicalPattern(speakerIDs)

        guard actualPattern == expectedPattern else {
            let chunkSummary = chunkDiagnostic(chunks)
            let base = "Speaker pattern mismatch: expected \(expectedPattern), "
                + "got \(actualPattern). "
                + "Distinct speakers: expected 3, got \(distinctSpeakers). "
                + "[\(chunkSummary)]. "
                + "Raw transcript: \"\(rawTranscript)\""
            return DiarizationEvaluation(
                chunkCount: chunkCount,
                distinctSpeakers: distinctSpeakers,
                passed: false,
                detail: appendFullTranscripts(to: base, chunks: chunks)
            )
        }

        return DiarizationEvaluation(
            chunkCount: chunkCount,
            distinctSpeakers: distinctSpeakers,
            passed: true,
            detail: "\(chunkCount) chunks, \(distinctSpeakers) distinct speakers, "
                + "pattern \(expectedPattern)"
        )
    }

    // MARK: - Internal helpers (visible to tests)

    /// Compute a canonical first-occurrence index sequence from a list of labels.
    /// E.g. ["A","B","A","B","C"] → [0,1,0,1,2]; [7,3,7,3,9] → [0,1,0,1,2].
    static func canonicalPattern<T: Hashable>(_ ids: [T]) -> [Int] {
        var mapping: [T: Int] = [:]
        var nextIndex = 0
        return ids.map { id in
            if let existing = mapping[id] {
                return existing
            }
            let index = nextIndex
            mapping[id] = index
            nextIndex += 1
            return index
        }
    }

    // MARK: - Private helpers

    /// Full expected transcript (all ground-truth chunk scripts joined).
    static var expectedTranscript: String {
        GroundTruth.chunks.map(\.script).joined(separator: " ")
    }

    /// Full actual transcript from chunks (all chunk texts joined in order).
    static func actualTranscript(from chunks: [TranscriptChunk]) -> String {
        chunks.map(\.text).joined(separator: " ")
    }

    private static func chunkDiagnostic(_ chunks: [TranscriptChunk]) -> String {
        chunks.enumerated().map { idx, chunk in
            "chunk[\(idx)] speaker=\(chunk.speakerID.map(String.init) ?? "nil")"
                + " text=\"\(chunk.text)\""
        }.joined(separator: ", ")
    }

    /// Appends full actual + expected transcripts to a detail string for diagnostics.
    private static func appendFullTranscripts(
        to detail: String, chunks: [TranscriptChunk]
    ) -> String {
        detail
            + " Actual transcript: \"\(actualTranscript(from: chunks))\""
            + " Expected transcript: \"\(expectedTranscript)\""
    }
}

// MARK: - Transcript accuracy evaluator

/// Result of evaluating transcript text accuracy (speaker-agnostic).
struct TranscriptAccuracyEvaluation {
    let ratio: Double
    let passed: Bool
    let detail: String
}

/// Evaluates transcript text accuracy against the ground truth, ignoring
/// speaker attribution. Concatenates all segment texts in time order and
/// compares against the full expected transcript with a single Levenshtein
/// ratio. A block of text attributed to the wrong speaker does not affect
/// this check — only genuinely wrong/missing/extra text does.
enum TranscriptAccuracyGroundTruth {
    static func evaluate(_ result: TranscriptResult) -> TranscriptAccuracyEvaluation {
        let chunks = TranscriptChunker.chunks(from: result)
        let actualText = DiarizationGroundTruth.actualTranscript(from: chunks)
        let expectedText = DiarizationGroundTruth.expectedTranscript

        let normalizedActual = TextNormalize.normalize(actualText)
        let normalizedExpected = TextNormalize.normalize(expectedText)
        let ratio = Levenshtein.ratio(normalizedActual, normalizedExpected)

        let tolerance = GroundTruth.transcriptAccuracyTolerance
        let passed = ratio <= tolerance

        let detail = if passed {
            "Transcript accuracy ratio=\(String(format: "%.4f", ratio))"
                + " within tolerance \(tolerance)."
                + " Actual transcript: \"\(actualText)\""
        } else {
            "Transcript accuracy ratio=\(String(format: "%.4f", ratio))"
                + " exceeds tolerance \(tolerance)."
                + " Actual transcript: \"\(actualText)\""
                + " Expected transcript: \"\(expectedText)\""
        }

        return TranscriptAccuracyEvaluation(
            ratio: ratio, passed: passed, detail: detail
        )
    }
}

// MARK: - Vocabulary evaluator

/// Result of evaluating a `TranscriptResult` against the custom-vocabulary
/// word-match ground truth.
struct VocabEvaluation {
    let matched: [String]
    let missed: [String]
    let passed: Bool
    let detail: String
}

/// Evaluates a `TranscriptResult` against the custom-vocabulary ground truth.
///
/// Uses exact word matching (after `TextNormalize` lowercasing + punctuation
/// stripping) with a 90% match threshold (`vocabMatchMinProportion`).
///
/// **This AI test is the coarse end-to-end signal, not the regression
/// guard.** Without vocab biasing, the clip yields 4–5 recognized terms;
/// with biasing, it yields 9–10. The threshold separates those cleanly.
///
/// **This threshold does NOT guard against a lowercasing regression.**
/// The original failure scored exactly 9/10 (only "nasa" dropped). A
/// recurrence today would also score 9/10: the lowercasing defect drops
/// only the first prompt term, and the other nine — including "gnocchi",
/// now correctly spelled — all match after normalization. 9/10 meets
/// this threshold and passes.
///
/// The designed guards against a lowercasing regression are the fast
/// deterministic tests, which run at `make test` speed:
/// - `VocabularyFormatterTests.originalCasingPreserved` (plus two
///   incidental guards: `whitespaceIsTrimmed`, `emptyStringsFiltered`)
///   — fail if lowercasing is reintroduced in `VocabularyFormatter`
/// - `VocabRegressionTests.lowercaseVocabDropsFirstTerm` — asserts that
///   the real lowercase-vocab transcript reports NASA as missed
///
/// The threshold is set against 5 on-hardware diagnostic runs
/// (scores: 10, 10, 10, 9, 9 — the two 9s being "Llama" → "Llami",
/// which under exact matching is a real miss). `make test-ai` passed
/// on hardware (2026-08-23). If the test proves flaky in practice,
/// revisit the threshold with fresh data rather than pre-emptively
/// loosening it.
enum VocabGroundTruth {
    /// Minimum proportion of vocab terms that must match (exact, after
    /// normalization) for the AI test to pass. Expressed as a proportion
    /// of `vocabTerms.count` so it stays correct if terms are added or
    /// removed. At 10 terms, 0.9 requires 9 exact matches.
    static let vocabMatchMinProportion = 0.9

    static func evaluate(_ result: TranscriptResult) -> VocabEvaluation {
        let fullText = result.segments.map(\.text).joined(separator: " ")
        let (matched, missed) = WordMatch.evaluate(
            transcript: fullText,
            expected: GroundTruth.vocabTerms
        )
        let required = Int(
            (Double(GroundTruth.vocabTerms.count) * vocabMatchMinProportion).rounded(.up)
        )
        let passed = matched.count >= required
        let detail = if passed {
            "\(matched.count)/\(GroundTruth.vocabTerms.count) vocab terms matched"
                + " (required \(required))"
        } else {
            "\(matched.count)/\(GroundTruth.vocabTerms.count) matched"
                + " (required \(required)). "
                + "Missed: \(missed.joined(separator: ", ")). "
                + "Expected vocab: \(GroundTruth.vocabTerms.joined(separator: ", ")). "
                + "Transcript: \"\(fullText)\""
        }
        return VocabEvaluation(
            matched: matched, missed: missed, passed: passed, detail: detail
        )
    }
}

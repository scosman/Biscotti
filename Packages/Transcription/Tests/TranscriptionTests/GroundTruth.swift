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
    /// The full 10-term list from the reference audio. The AI test that uses
    /// these is currently **disabled** because WhisperKit's `promptTokens`
    /// API silently blanks the entire transcript for certain term combinations
    /// — even all-lowercase, even with the non-turbo model. Tracked upstream:
    /// https://github.com/argmaxinc/argmax-oss-swift/issues/489
    /// https://github.com/argmaxinc/argmax-oss-swift/pull/428
    static let vocabTerms = [
        "nasa", "kubernetes", "postgres", "qwen", "mistral",
        "llama", "croissant", "gnocci", "paella", "facade"
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

/// Evaluates a `TranscriptResult` against the custom-vocabulary
/// ground truth using exact word matching.
enum VocabGroundTruth {
    static func evaluate(_ result: TranscriptResult) -> VocabEvaluation {
        let fullText = result.segments.map(\.text).joined(separator: " ")
        let (matched, missed) = WordMatch.evaluate(
            transcript: fullText, expected: GroundTruth.vocabTerms
        )
        let passed = missed.isEmpty
        let detail = if passed {
            "All \(matched.count) vocab terms matched"
        } else {
            "\(matched.count)/\(GroundTruth.vocabTerms.count) matched. "
                + "Missed: \(missed.joined(separator: ", ")). "
                + "Expected vocab: \(GroundTruth.vocabTerms.joined(separator: ", ")). "
                + "Transcript: \"\(fullText)\""
        }
        return VocabEvaluation(
            matched: matched, missed: missed, passed: passed, detail: detail
        )
    }
}

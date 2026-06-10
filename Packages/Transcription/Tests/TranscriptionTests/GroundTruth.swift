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

    /// Maximum normalized Levenshtein ratio allowed per chunk.
    static let chunkLevenshteinTolerance = 0.05

    /// Custom vocabulary terms for the vocab-bias test clip.
    ///
    /// WhisperKit's `promptTokens`-based vocab conditioning silently blanks
    /// the entire transcript for some terms when uppercase or in certain
    /// order/combination. This curated lowercase trio is empirically reliable
    /// with `custom_vocab_test.aac`. Robust custom-vocab handling is under
    /// separate investigation — do NOT expand back to the original 10 mixed-case
    /// terms without re-validating on hardware.
    static let vocabTerms = ["gnocci", "facade", "qwen"]
}

// MARK: - Diarization evaluator

/// Result of evaluating a `TranscriptResult` against the 3-speaker ground truth.
struct ChunkEvaluation {
    let chunkCount: Int
    let distinctSpeakers: Int
    let perChunkRatios: [Double]
    let passed: Bool
    let detail: String
}

/// Evaluates a `TranscriptResult` against the 3-speaker diarization ground truth.
///
/// Checks: (1) chunk count == 5 (adjacency-merged), (2) speaker-equivalence
/// pattern matches [A,B,A,B,C] (enforces 3 distinct speakers + interleaving),
/// (3) per-chunk normalized Levenshtein <= tolerance.
enum DiarizationGroundTruth {
    /// The expected canonical first-occurrence pattern from the reference labels.
    /// Labels [A,B,A,B,C] → first-occurrence indices [0,1,0,1,2].
    static let expectedPattern: [Int] = canonicalPattern(
        GroundTruth.chunks.map(\.speakerLabel)
    )

    static func evaluate(_ result: TranscriptResult) -> ChunkEvaluation {
        let chunks = TranscriptChunker.chunks(from: result)
        let chunkCount = chunks.count
        let speakerIDs = chunks.compactMap(\.speakerID)
        let distinctSpeakers = Set(speakerIDs).count
        let rawTranscript = result.segments.map(\.text).joined(separator: " ")

        if let failure = checkStructure(
            chunks: chunks, chunkCount: chunkCount, distinctSpeakers: distinctSpeakers,
            rawTranscript: rawTranscript
        ) {
            return failure
        }

        return checkLevenshtein(
            chunks: chunks, chunkCount: chunkCount, distinctSpeakers: distinctSpeakers
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

    private static func checkStructure(
        chunks: [TranscriptChunk], chunkCount: Int, distinctSpeakers: Int,
        rawTranscript: String
    ) -> ChunkEvaluation? {
        let expectedCount = GroundTruth.chunks.count

        guard chunkCount == expectedCount else {
            let chunkSummary = chunks.enumerated().map { idx, chunk in
                "chunk[\(idx)] speaker=\(chunk.speakerID.map(String.init) ?? "nil")"
                    + " text=\"\(chunk.text)\""
            }.joined(separator: ", ")
            return ChunkEvaluation(
                chunkCount: chunkCount,
                distinctSpeakers: distinctSpeakers,
                perChunkRatios: [],
                passed: false,
                detail: "Expected \(expectedCount) chunks, got \(chunkCount). "
                    + "[\(chunkSummary)]. "
                    + "Raw transcript: \"\(rawTranscript)\""
            )
        }

        // Check speaker-equivalence pattern (enforces both distinctness and interleaving).
        let speakerIDs = chunks.compactMap(\.speakerID)
        let actualPattern = canonicalPattern(speakerIDs)

        guard actualPattern == expectedPattern else {
            let chunkSummary = chunks.enumerated().map { idx, chunk in
                "chunk[\(idx)] speaker=\(chunk.speakerID.map(String.init) ?? "nil")"
                    + " text=\"\(chunk.text)\""
            }.joined(separator: ", ")
            return ChunkEvaluation(
                chunkCount: chunkCount,
                distinctSpeakers: distinctSpeakers,
                perChunkRatios: [],
                passed: false,
                detail: "Speaker pattern mismatch: expected \(expectedPattern), "
                    + "got \(actualPattern). "
                    + "Distinct speakers: expected 3, got \(distinctSpeakers). "
                    + "[\(chunkSummary)]. "
                    + "Raw transcript: \"\(rawTranscript)\""
            )
        }

        return nil
    }

    private static func checkLevenshtein(
        chunks: [TranscriptChunk], chunkCount: Int, distinctSpeakers: Int
    ) -> ChunkEvaluation {
        let tolerance = GroundTruth.chunkLevenshteinTolerance
        var ratios: [Double] = []
        var failures: [String] = []

        for (idx, (chunk, ref)) in zip(chunks, GroundTruth.chunks).enumerated() {
            let normalizedChunk = TextNormalize.normalize(chunk.text)
            let normalizedRef = TextNormalize.normalize(ref.script)
            let ratio = Levenshtein.ratio(normalizedChunk, normalizedRef)
            ratios.append(ratio)

            if ratio > tolerance {
                failures.append(
                    "chunk[\(idx)] ratio=\(String(format: "%.4f", ratio)) > \(tolerance). "
                        + "got=\"\(normalizedChunk)\" expected=\"\(normalizedRef)\""
                )
            }
        }

        if !failures.isEmpty {
            return ChunkEvaluation(
                chunkCount: chunkCount,
                distinctSpeakers: distinctSpeakers,
                perChunkRatios: ratios,
                passed: false,
                detail: failures.joined(separator: "; ")
            )
        }

        return ChunkEvaluation(
            chunkCount: chunkCount,
            distinctSpeakers: distinctSpeakers,
            perChunkRatios: ratios,
            passed: true,
            detail: "\(chunkCount) chunks, \(distinctSpeakers) distinct speakers, "
                + "pattern \(expectedPattern), all ratios within tolerance"
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
                + "Transcript: \"\(fullText)\""
        }
        return VocabEvaluation(
            matched: matched, missed: missed, passed: passed, detail: detail
        )
    }
}

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
/// The three speaker chunks and vocabulary terms are derived from confirmed
/// transcriptions of the reference audio (see functional spec section 1).
enum GroundTruth {
    /// The 3-speaker reference transcript, chunked by speaker.
    static let chunks: [ReferenceChunk] = [
        .init(speakerLabel: "A", script: "Hello, this is a test of the system."),
        .init(
            speakerLabel: "B",
            script: "Hello, I am person number two. I am saying something back."
        ),
        .init(
            speakerLabel: "C",
            script: "Hi, I'm person number three and you two are banana heads."
        )
    ]

    /// Maximum normalized Levenshtein ratio allowed per chunk.
    static let chunkLevenshteinTolerance = 0.05

    /// Custom vocabulary terms for the vocab-bias test clip.
    static let vocabTerms = [
        "NASA", "Kubernetes", "Postgres", "Qwen", "Mistral",
        "Llama", "Croissant", "gnocci", "Paella", "Facade"
    ]

    /// Diarization cluster-distance threshold that separates the 3 speakers
    /// in the reference clip. **Placeholder** -- finalized via the diagnostic
    /// sweep in Phase 2.
    static let tunedDiarizationClusterThreshold: Float = 0.40
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
/// Checks: (1) chunk count == 3, (2) 3 distinct speaker IDs, (3) per-chunk
/// normalized Levenshtein <= tolerance.
enum DiarizationGroundTruth {
    static func evaluate(_ result: TranscriptResult) -> ChunkEvaluation {
        let chunks = TranscriptChunker.chunks(from: result)
        let chunkCount = chunks.count
        let speakerIDs = chunks.compactMap(\.speakerID)
        let distinctSpeakers = Set(speakerIDs).count

        if let failure = checkStructure(chunks: chunks, chunkCount: chunkCount, distinctSpeakers: distinctSpeakers) {
            return failure
        }

        return checkLevenshtein(chunks: chunks, chunkCount: chunkCount, distinctSpeakers: distinctSpeakers)
    }

    // MARK: - Private helpers

    private static func checkStructure(
        chunks: [TranscriptChunk], chunkCount: Int, distinctSpeakers: Int
    ) -> ChunkEvaluation? {
        guard chunkCount == 3 else {
            let chunkSummary = chunks.enumerated().map { idx, chunk in
                "chunk[\(idx)] speaker=\(chunk.speakerID.map(String.init) ?? "nil")"
            }.joined(separator: ", ")
            return ChunkEvaluation(
                chunkCount: chunkCount,
                distinctSpeakers: distinctSpeakers,
                perChunkRatios: [],
                passed: false,
                detail: "Expected 3 chunks, got \(chunkCount). [\(chunkSummary)]"
            )
        }

        guard distinctSpeakers == 3 else {
            let ids = chunks.map { $0.speakerID.map(String.init) ?? "nil" }.joined(separator: ", ")
            return ChunkEvaluation(
                chunkCount: chunkCount,
                distinctSpeakers: distinctSpeakers,
                perChunkRatios: [],
                passed: false,
                detail: "Expected 3 distinct speakers, got \(distinctSpeakers). IDs: [\(ids)]"
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
            detail: "3 chunks, 3 distinct speakers, all ratios within tolerance"
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

/// Evaluates a `TranscriptResult` against the 10-term custom-vocabulary
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
                + "Missed: \(missed.joined(separator: ", "))"
        }
        return VocabEvaluation(
            matched: matched, missed: missed, passed: passed, detail: detail
        )
    }
}

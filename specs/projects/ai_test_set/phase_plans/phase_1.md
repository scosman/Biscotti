---
status: complete
---

# Phase 1: Comparison support + unit tests (pure, gating-testable)

## Overview

Add all comparison utilities, ground truth definitions, and evaluator logic inside the `TranscriptionTests` test target. These are pure, fast functions tested on synthetic `TranscriptResult` data -- no models, no audio. Everything runs under `make test` (gating tier). This phase establishes the foundation that the AI tests (Phase 3) will consume.

## Steps

1. **Create `Tests/TranscriptionTests/TextNormalize.swift`**
   - `enum TextNormalize` with:
     - `static func normalize(_ s: String) -> String` -- lowercase, trim, collapse internal whitespace, strip `. , ! ? ' " : ;`
     - `static func words(_ s: String) -> [String]` -- split normalized string on whitespace

2. **Create `Tests/TranscriptionTests/Levenshtein.swift`**
   - `enum Levenshtein` with:
     - `static func distance(_ a: String, _ b: String) -> Int` -- character-level edit distance
     - `static func ratio(_ a: String, _ b: String) -> Double` -- `distance / max(count(a), count(b))`; 0.0 for two empties

3. **Create `Tests/TranscriptionTests/TranscriptChunker.swift`**
   - `struct TranscriptChunk: Equatable { let speakerID: Int?; let text: String; let start, end: TimeInterval }`
   - `enum TranscriptChunker` with:
     - `static func chunks(from result: TranscriptResult) -> [TranscriptChunk]` -- order segments by startTime, merge adjacent segments sharing the same speakerID into chunks (concatenate text with single space, take min start / max end)

4. **Create `Tests/TranscriptionTests/WordMatch.swift`**
   - `enum WordMatch` with:
     - `static func evaluate(transcript: String, expected: [String]) -> (matched: [String], missed: [String])` -- normalize transcript into word set, check each expected term (normalized) for exact membership

5. **Create `Tests/TranscriptionTests/GroundTruth.swift`**
   - `struct ReferenceChunk: Equatable { let speakerLabel: String; let script: String }`
   - `enum GroundTruth` with static constants:
     - `chunks: [ReferenceChunk]` (the 3 reference chunks from the spec)
     - `chunkLevenshteinTolerance = 0.05`
     - `vocabTerms: [String]` (the 10 custom-vocab terms)
     - `tunedDiarizationClusterThreshold: Float = 0.40` (placeholder)
   - `struct ChunkEvaluation { let chunkCount, distinctSpeakers: Int; let perChunkRatios: [Double]; let passed: Bool; let detail: String }`
   - `enum DiarizationGroundTruth` with `static func evaluate(_ r: TranscriptResult) -> ChunkEvaluation`
   - `struct VocabEvaluation { let matched, missed: [String]; let passed: Bool; let detail: String }`
   - `enum VocabGroundTruth` with `static func evaluate(_ r: TranscriptResult) -> VocabEvaluation`

6. **Create `Tests/TranscriptionTests/TextNormalizeTests.swift`** -- unit tests for normalize + words
7. **Create `Tests/TranscriptionTests/LevenshteinTests.swift`** -- unit tests for distance + ratio
8. **Create `Tests/TranscriptionTests/TranscriptChunkerTests.swift`** -- unit tests: same-speaker merge, A/B/A -> 3 chunks / 2 distinct, nil speaker handling, empty result
9. **Create `Tests/TranscriptionTests/WordMatchTests.swift`** -- unit tests: all match, none match, partial, punctuation stripping, case insensitivity
10. **Create `Tests/TranscriptionTests/GroundTruthEvaluatorTests.swift`** -- tests on synthetic TranscriptResults:
    - DiarizationGroundTruth.evaluate: passing case (3 chunks, 3 distinct, low ratios), wrong chunk count, non-distinct speakers, high Levenshtein ratio
    - VocabGroundTruth.evaluate: all 10 present, some missing, none present

## Tests

- `TextNormalizeTests`: lowercase, trim, whitespace collapse, punctuation strip, words split
- `LevenshteinTests`: identical strings, single edit, empty strings, ratio edge cases
- `TranscriptChunkerTests`: single-segment, multi-segment same-speaker merge, alternating A/B/A, nil speakerID, empty segments
- `WordMatchTests`: all match, none match, partial match, punctuation + case normalization
- `GroundTruthEvaluatorTests/Diarization`: pass case, chunk count fail, distinctness fail, Levenshtein fail
- `GroundTruthEvaluatorTests/Vocab`: pass case (10/10), partial miss, all miss

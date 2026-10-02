---
status: complete
---

# Phase 2: Transcription Capture

## Overview

Replace the placeholder `speakerEmbeddings` field on `TranscriptResult` with the
production embedding types: `embeddingSets` (raw + PLDA per speaker) and
`speakerSpeechDurations`. Add `SpeakerEmbeddingSpace`, `SpeakerDurations`,
`EmbeddingSetBuilder`, `DiarizationSettings`, and `SpeakerAnalyzer`. Update the
engine to use `.trainableOnly` centroid source. Update sanitizer pass-through,
CLI output, all call sites, and tests. Mark `tx_*` manual tests `not-run`.

## Steps

1. **New types in `TranscriptResult.swift`**: Add `EmbeddingKind` enum,
   `SpeakerEmbeddingSet` struct. Remove `speakerEmbeddings` from
   `TranscriptResult`, add `embeddingSets: [SpeakerEmbeddingSet]` and
   `speakerSpeechDurations: [Int: TimeInterval]` with defaults.

2. **New file `SpeakerEmbeddingSpace.swift`**: `SpeakerEmbeddingSpace.current(_:)`
   reads `ModelInfo.embedder()` and `ModelInfo.plda()` to build the space key.

3. **New file `SpeakerDurations.swift`**: `DiarizedSpan` struct,
   `SpeakerDurations.compute(_:)` and `.spans(from:)`.

4. **New file `EmbeddingSetBuilder.swift`**: Builds `[SpeakerEmbeddingSet]` from
   a `DiarizationResult`, dropping empty/non-finite vectors.

5. **New file `DiarizationSettings.swift`**: `DiarizationSettings.options` with
   `.trainableOnly`.

6. **Update `InProcessTranscriptionEngine.swift`**: Use
   `DiarizationSettings.options` in `runDiarization`, populate `embeddingSets`
   and `speakerSpeechDurations` in `assembleResult`. Extract `loadAudioSamples`
   and `makeSpeakerConfig` as internal shared helpers (`AudioLoading`,
   `SpeakerKitConfigFactory`) for reuse by `SpeakerAnalyzer`.

7. **New file `SpeakerAnalyzer.swift`**: Public actor for diarization-only
   analysis (CLI backfill), using shared helpers.

8. **Update `TranscriptSanitizer.swift`**: Pass `embeddingSets` and
   `speakerSpeechDurations` through.

9. **Update `OutputFormatting.swift`**: Print each embedding set as
   `kind (space): N speakers x D dims` instead of raw vector dump.

10. **Update all call sites**: Remove `speakerEmbeddings: [:]` argument from
    ~40 call sites in Transcription tests, BiscottiKit tests, and sources.

11. **Rewrite `ResultCodableTests`**: Test round-trip with `embeddingSets` and
    `speakerSpeechDurations`.

12. **Rewrite `CLIOutputTests`**: Test new embedding set display format.

13. **Update `SanitizerTests`**: Verify new fields pass through.

14. **New tests**: `SpeakerDurations.compute`, `EmbeddingSetBuilder`,
    `SpeakerEmbeddingSpace.current`, `TranscriptSanitizer` pass-through.

15. **Manual test staleness**: Verify `tx_*` steps are `not-run` (they already
    are on this branch).

## Tests

- `SpeakerDurationsTests`: sums per speaker; empty input; overlapping spans
- `EmbeddingSetBuilderTests`: both sets present; empty vectors dropped; kind
  with no vectors omitted; correct space per kind
- `SpeakerEmbeddingSpaceTests`: raw key format; PLDA key format; no `unknown`
  components on macOS 15
- `ResultCodableTests`: round-trip with `embeddingSets` and durations; JSON
  field names; empty sets
- `SanitizerTests`: `embeddingSets` and `speakerSpeechDurations` preserved
- `CLIOutputTests`: embedding set display format

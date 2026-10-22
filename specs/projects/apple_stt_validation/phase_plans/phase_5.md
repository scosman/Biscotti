---
status: complete
---

# Phase 5: Analysis Core

## Overview

Build all the pure analysis logic in `STTLabAnalysis` (depends on `STTLabCore` only). This replaces the phase 2 placeholder. Speaker metrics (spec section 6.6), speaker alignment (section 7) and the report (section 8) are phase 6.

## Steps

1. **Model types** (`STTLabAnalysis/Model.swift`): `EngineID`, `EngineWord`, `EngineTranscript`, `AlignedWord`, `AlignedSegment`, `AlignedTranscript` per spec section 2.

2. **AppleWordGrouper** (`STTLabAnalysis/AppleWordGrouper.swift`): tokenizes `AppleResult.text`, maps runs to tokens, computes `RunClass` per run, detects anomalies, outputs `[EngineWord]` + `RunStats`. Per spec section 3.

3. **Normalizer** (`STTLabAnalysis/Normalizer.swift`): `Normalizer.tokens(for:) -> [NormToken]`. Steps: NFKC + lowercase, symbol expansion, hyphen/dash/slash splitting, non-letter/digit/apostrophe removal, contraction expansion (fixed table), number spell-out, filler removal. Per spec section 4.

4. **Aligner** (`STTLabAnalysis/Aligner.swift`): `Aligner.align(_:_:) -> [EditOp]` (Hirschberg, linear memory) and `Aligner.alignNaive(_:_:) -> [EditOp]` (full matrix). Token interning, costs match=0 sub=1 del=1 ins=1, tie order: diagonal > deletion > insertion. Per spec section 5.

5. **WER** (`STTLabAnalysis/WER.swift`): `WERResult` with S/D/I counts and `wer` ratio. Uses the Aligner + Normalizer. Per spec section 6.1.

6. **TieBreak** (`STTLabAnalysis/TieBreak.swift`): disagreement regions from Apple-vs-Whisper alignment, map to reference spans, classify (appleMatches / whisperMatches / appleCloser / whisperCloser / tiedPartial / neither), region sampling. Per spec section 6.2.

7. **Flags** (`STTLabAnalysis/Flags.swift`): `werRatio`, `droppedStretch`, `emptyResult` per spec section 6.3.

8. **TextQuality** (`STTLabAnalysis/TextQuality.swift`): punctuation density, sentence casing, filler counts. Per spec section 6.4.

9. **Timing** (`STTLabAnalysis/Timing.swift`): `TimingStats` for matched word pairs across engine pairs. Per spec section 6.5.

10. **Package.swift**: add `STTLabAnalysisTests` test target.

## Tests

- `NormalizerTests`: one test per normalization rule (NFKC, lowercase, symbol expansion, hyphens, stripping, contractions, numbers, ordinals, decimals, fillers, sourceIndex preservation).
- `AlignerTests`: property test: 200 seeded random pairs (length 0-60, vocab 6), verify Hirschberg cost == naive cost and op counts match; replay test: verify edit script replays a into b.
- `AppleWordGrouperTests`: hand-built AppleResults testing token-to-run mapping, RunClass classification, anomaly detection, and untimed runs.
- `WERTests`: known S/D/I counts on hand-built inputs; zero-ref-words case returns nil WER.
- `TieBreakTests`: hand-built triples with known classes; region merging (single-match gap); token-weighted counts.
- `FlagsTests`: werRatio trigger and non-trigger; droppedStretch with/without coverage; emptyResult.
- `TextQualityTests`: punctuation counting, sentence start capitalization, mid-sentence caps, filler counting.
- `TimingTests`: median/p90/max on known data; empty pairs.

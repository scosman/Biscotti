---
status: complete
---

# Phase 6: Docs + Final Pass

## Overview

Update the four documentation targets listed in architecture.md section 8. Verify that all `tx_*` manual-test steps exist in the results file and are marked `not-run`, ready for the human's on-hardware pass on macOS 26/27 and macOS 15.

## Steps

1. **`specs/projects/initial_implementation/architecture.md`** -- update the Transcription package card (component 2) to mention two engines (Whisper + Apple Speech via `SpeechTranscriber`), the `SpeechEngine`/`ModelComponent` split, and the app-side `AppleSpeechSupport` API. Add a note that Apple code compiles on macOS 15 (26 SDK) behind `#if canImport(Speech)` + `@available`.

2. **`specs/research/stt-engine-swap/summary.md`** -- add a "Decision Outcome" section after "Implications" recording that the user chose the dual-engine path (Apple Speech + Whisper), not the FluidAudio single-engine swap. Reference the `apple_speech_engine` spec project.

3. **`CLAUDE.md`** -- update the current-stage paragraph to mention the `apple_speech_engine` spec project (Apple Speech as a second STT engine, engine selection, Speech to Text Model sheet, onboarding 3-row model card). Add an entry in the "Process & planning records" section for `specs/projects/apple_speech_engine/`.

4. **`experiments/STTLab/NOTES.md`** -- add a "Graduated" section noting that the Apple Speech engine path validated by STTLab has been productionized into `Packages/Transcription` (the `AppleSpeech/` directory) by the `apple_speech_engine` spec project. The experiment's `AppleWordGrouping` logic now lives in `Packages/Transcription/Sources/Transcription/AppleSpeech/AppleWordGrouping.swift`.

5. **Verify manual-test readiness** -- confirm all `tx_*` entries in `ManualTestApp/Results/manual_test_results.json` are present and `not-run`. The steps are: `tx_apple_status`, `tx_apple_install`, `tx_apple_transcribe`, `tx_apple_no_prompt`, `tx_apple_output_ok`, `tx_ai_test_passed`, `tx_clear_cache`, `tx_model_disk`, `tx_model_download`.

## Tests

- No new tests (docs-only phase). Existing tests must still pass.

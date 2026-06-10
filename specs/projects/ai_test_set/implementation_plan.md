---
status: complete
---

# Implementation Plan: A.5 — AI Test Set & Manual Test App Updates

Phased build order. Each phase is a coherent, reviewable unit. **One human-in-the-loop checkpoint** is unavoidable (the agent can't run models/`make test-ai`): confirming the AI tests pass (Phase 2), run by the user via `!`.

## Phases

- [x] **Phase 1 — Comparison support + unit tests (pure, gating-testable).**
  In `Tests/TranscriptionTests` (test-target `internal`): add `TextNormalize`, `Levenshtein`, `TranscriptChunker`, `WordMatch`, and ground truth + evaluators (`GroundTruth`, `DiarizationGroundTruth.evaluate`, `VocabGroundTruth.evaluate`). Full fast unit tests on synthetic `TranscriptResult`s — runs in `make test`. No model work, no public API on `Transcription`. *(arch §2, §3.5)*

> **Diarization tuning knob — DEFERRED.** The early plan (original Phase 2) exposed an optional test-only `diarizationClusterThreshold` parameter plus a CLI sweep diagnostic, because the original short reference clip collapsed to 1 speaker under SDK defaults. The clip was **re-recorded** with longer, more distinct turns and now diarizes to **3 speakers under production defaults**, so the knob is unnecessary. The threshold plumbing + CLI flags + XPC field were implemented briefly and then **reverted** (commit `d8cdd21` → revert `9febe90`). Exposing a diarization tuning parameter (note: `numberOfSpeakers` would be the more direct lever than `clusterDistanceThreshold`, since SpeakerKit's VBx refinement can override the AHC seed) is deferred to a future project. Production is unchanged; the AI test passes no diarization override.

- [ ] **Phase 2 — AI tests + clips + make target.**
  Relocate `mic.aac`/`system.aac`/`custom_vocab_test.aac` into `Tests/TranscriptionTests/Fixtures/`. Add `.aiModel` tag + `AITestGate` (env `BISCOTTI_RUN_AI_TESTS`) + the two gated AI tests (diarization/accuracy via chunk eval under production defaults; custom-vocab word match). Add `make test-ai`; document it in `CLAUDE.md`. *(arch §3, §4)*
  - **🧑 Checkpoint (AI test run):** user runs `make test-ai` → confirm both tests green (validates diarization under production defaults + vocab end-to-end on real models). If word-match needs adjustment, iterate per arch §7.

- [ ] **Phase 3 — Manual Test App updates.**
  `ManualTestKit`: `AudioCaptureScript.swift` — reword (Google Meet, AirPods transfer, named kill process) + add steps (`ac_meet_close_midcapture`, `ac_meet_open_midcapture`, `ac_mega_setup`/`ac_mega_voice`/`ac_mega_timing`). `TranscriptionScript.swift` — reduce to download steps + `tx_ai_test_passed`; cut quality + crash steps. `WiredScripts.swift` — keep only the two download-step wirings; remove `currentCapturePaths`, result holders, transcribe/crash/autoCheck wiring. Remove the 3 `.aac` from `ManualTestApp/Resources/`. Regenerate `manual_test_results.json` (all current step IDs `not-run`; drop cut keys). Verify with `make build-app` (agent ✓ via hooks-mcp). *(arch §5)*
  - Hardware re-run of the scripts is the existing **Phase 4.5** (human, on Apple silicon) — out of this project's automated scope; `manual-tests-check` stays RED until then.

## Dependencies

- Phase 2 (AI tests) depends on Phase 1 (evaluators + ground truth).
- Phase 3 (Manual Test App) is independent of Phases 1–2 (the app no longer transcribes reference clips / uses evaluators); sequenced last for a clean review, but could run any time.

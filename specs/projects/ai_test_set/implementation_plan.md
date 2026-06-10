---
status: complete
---

# Implementation Plan: A.5 — AI Test Set & Manual Test App Updates

Phased build order. Each phase is a coherent, reviewable unit. **Two human-in-the-loop checkpoints** are unavoidable (the agent can't run models/`make test-ai`): finding the threshold (Phase 2) and confirming the AI tests pass (Phase 3) — both run by the user via `!`.

## Phases

- [x] **Phase 1 — Comparison support + unit tests (pure, gating-testable).**
  In `Tests/TranscriptionTests` (test-target `internal`): add `TextNormalize`, `Levenshtein`, `TranscriptChunker`, `WordMatch`, and ground truth + evaluators (`GroundTruth` with placeholder threshold, `DiarizationGroundTruth.evaluate`, `VocabGroundTruth.evaluate`). Full fast unit tests on synthetic `TranscriptResult`s — runs in `make test`. No model work, no public API on `Transcription`. *(arch §2, §3.5)*

- [ ] **Phase 2 — Diarization threshold knob + CLI diagnostic.**
  Plumb optional `diarizationClusterThreshold: Float?` through `Transcriber.processAudio` → `TranscriptionEngine` → `InProcessTranscriptionEngine.runDiarization` → `XPCProcessRequest` + XPC service (completeness) → stub. Add `transcribe-cli --diarization-threshold` and `--diarization-sweep` (sweep prints SDK `speakerCount` + inline distinct-speaker count — no chunker dependency). Unit tests: XPC request Codable round-trip, CLI parsing. Default `nil` ⇒ production unchanged. *(arch §1)*
  - **🧑 Checkpoint (diagnostic run):** user runs `transcribe-cli --diarization-sweep "0.30,0.35,0.40,0.45,0.50"` on the 3-speaker clip → read the value giving `speakers=3 distinct=3` → set `GroundTruth.tunedDiarizationClusterThreshold`.

- [ ] **Phase 3 — AI tests + clips + make target.**
  Relocate `mic.aac`/`system.aac`/`custom_vocab_test.aac` into `Tests/TranscriptionTests/Fixtures/`. Add `.aiModel` tag + `AITestGate` (env `BISCOTTI_RUN_AI_TESTS`) + the two gated AI tests (diarization/accuracy via chunk eval; custom-vocab word match). Add `make test-ai`; document it in `CLAUDE.md`. *(arch §3, §4)*
  - **🧑 Checkpoint (AI test run):** user runs `make test-ai` → confirm both tests green (validates the diarization fix + vocab end-to-end on real models). If threshold/word-match needs adjustment, iterate per arch §7.

- [ ] **Phase 4 — Manual Test App updates.**
  `ManualTestKit`: `AudioCaptureScript.swift` — reword (Google Meet, AirPods transfer, named kill process) + add steps (`ac_meet_close_midcapture`, `ac_meet_open_midcapture`, `ac_mega_setup`/`ac_mega_voice`/`ac_mega_timing`). `TranscriptionScript.swift` — reduce to download steps + `tx_ai_test_passed`; cut quality + crash steps. `WiredScripts.swift` — keep only the two download-step wirings; remove `currentCapturePaths`, result holders, transcribe/crash/autoCheck wiring. Remove the 3 `.aac` from `ManualTestApp/Resources/`. Regenerate `manual_test_results.json` (all current step IDs `not-run`; drop cut keys). Verify with `make build-app` (agent ✓ via hooks-mcp). *(arch §5)*
  - Hardware re-run of the scripts is the existing **Phase 4.5** (human, on Apple silicon) — out of this project's automated scope; `manual-tests-check` stays RED until then.

## Dependencies

- Phase 2 is independent of Phase 1 (the sweep computes distinct speakers inline, not via the chunker).
- Phase 3 depends on Phases 1–2 (evaluators + threshold knob + finalized threshold constant).
- Phase 4 is independent of 1–3 (the app no longer transcribes reference clips / uses evaluators); sequenced last for a clean review, but could run any time.

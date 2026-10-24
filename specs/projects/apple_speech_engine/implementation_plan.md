---
status: complete
---

# Implementation Plan: Apple Speech Engine

Specs: `functional_spec.md`, `ui_design.md`, `architecture.md`, `components/*.md`.

## Phases

- [x] Phase 1: Engine core (`Packages/Transcription`, no Speech framework yet) — `SpeechEngine`, `ModelComponent`, `TranscriptionConfig`, Codable `TranscriptionMethod` + `appleV1`, resolver `engine`, per-call config in `InProcessTranscriptionEngine` / `Transcriber` / `XPCEngineAdapter`, component download/presence/delete, `engineUnavailable` error, XPC request/protocol changes, pure `AppleWordGrouping` + bridge, `WAVWriter`; unit tests (`components/transcription_engine.md`).
- [x] Phase 2: Apple runtime + hardware spike — `AppleSpeechSupport`, `AppleLocaleReservations`, `AppleSpeechSTT`, engine `.apple` branch, CLI `--engine/--locale`, app Info.plist key, Apple AI test, ManualTestApp `tx_apple_*` steps + fixtures, mark `tx_*` not-run. No stop here: the hardware checks (XPC works, no prompt, app-installed assets usable) run with the final pass in Phase 6. If they fail, the fallback in `architecture.md` §5 applies.
- [x] Phase 3: App state (`BiscottiKit`) — `AppSettings` fields, `Transcribing` changes + adapters, `AppleSpeechProviding` + live provider, policies, `SpeechEngineManager`, `TranscriptionService` job config/components/vocab, AppCore wiring (two `Transcriber`s, `onLaunch` refresh, migration), re-transcribe offer gating, Settings VM vocab logic, fakes + tests (`components/speech_engine_manager.md`).
- [x] Phase 4: Speech to Text Model sheet + Settings — shared sheet components extracted from `ManageModelsSheet`, `SpeechEngineRowBuilder`, `SpeechModelSheetViewModel` + view + alerts, Settings row, Custom Vocabulary toggle/alert (`components/ui.md` §1–3).
- [ ] Phase 5: Onboarding — 3-row model card, row states (`ready(caption:)`, Speaker ID row), `RecommendationLine` changes, footer "all three", Continue persists target, sheet presentation (`components/ui.md` §4).
- [ ] Phase 6: Docs + final pass — update `specs/architecture.md`, `specs/research/stt-engine-swap/summary.md`, `CLAUDE.md`, `experiments/STTLab/NOTES.md`; full manual-test pass on the macOS 26/27 Mac (including the Phase 2 `tx_apple_*` spike steps) and on macOS 15 (Apple disabled, onboarding without "See all options").

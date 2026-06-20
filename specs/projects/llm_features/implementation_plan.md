---
status: complete
---

# Implementation Plan: LLM Features

Ordered, dependency-driven phases. Each phase is independently reviewable and must land **green on `lint` + `test` + `build`** (app-touching phases also run `build-app`). Details live in `functional_spec.md`, `ui_design.md`, `architecture.md`, and `components/*`.

> **Manual-test note:** this project does **not** modify `Packages/LocalLLM`, `Packages/Transcription`, or `Packages/AudioCapture`, so the `ac_*`/`tx_*`/`llm_*` manual-test results are **not** invalidated. (Phase 7 may add a *new* manual-test script for the app-level AI features.)

## Phases

- [x] **Phase 1 — Data model & DataStore.** Add `Meeting.summary`/`editedSummary`, `TranscriptRecord.speakerAssignments` (JSON `[Int: UUID]`), `AppSettings.summarizeTranscripts`/`guessSpeakerNames`. Extend DTOs (`SegmentData.speakerID`, `TranscriptData.speakerAssignments` resolved to `PersonData`, `MeetingDetailData.summary`/`editedSummary`, `AppSettingsData`). Add `DataStore` methods (`applyGeneratedSummary`, `setSummary`, `setSpeakerAssignments`, `setSpeakerAssignment`, `allPersonData`) and resolve new fields in `meetingDetail`/`transcript`. Additive schema (no V2). **Tests:** DataStoreTests for every field/method, `[Int:UUID]` round-trip, read-model resolution, dangling-ID drop. *(No LLM/UI yet.)*

- [ ] **Phase 2 — `Intelligence` module core.** Add `LocalLLM` dep to BiscottiKit; create the `Intelligence` target + product + test target. Build `LLMRunning`/`LLMSession`/`ModelProviding` protocols + live impls, `IntelligencePrompts` (Swift-constant catalog), `TranscriptFormatter`, `SpeakerMappingParser`, `SpeakerIdentifier`, `Summarizer`, the `Intelligence` service (orchestration, `runAutoEnhancements`, `generateSummary`, download state), and the status/download enums. **Tests:** full IntelligenceTests with fakes — gating, ordering (speakers→summary), edited-summary guard, single-session, streaming accumulation, parser cases, download state machine, cancellation. *(Compiles + tests standalone; no app wiring.)*

- [ ] **Phase 3 — AppCore wiring & auto-run.** `AppCore` owns a live `Intelligence`; `stopRecording()` triggers `runAutoEnhancements` after `transcribe()`. App target embeds `llama.framework`; verify a hosted connection launches from the app process (`build-app` + smoke). **Tests:** AppCoreTests (trigger-after-transcription, skip when off/no-model, via fakes). *(Milestone: app now links/loads LocalLLM.)*

- [ ] **Phase 4 — Settings: AI Enhancements + model download.** `SettingsView` section (two toggles + conditional download row), `SettingsViewModel` additions, download-row state machine bound to `Intelligence.download`/`downloadModel()`, no-model disabling, live flip on completion. **Tests:** SettingsUITests (toggle persistence + revert, no-model state, download state machine). *(Lets a human download the model + toggle features for later manual testing.)*

- [ ] **Phase 5 — Meeting detail: Summary tab.** New first `Tab.summary`; `summaryTabContent` state machine (streaming / editable / empty×{no-model, off, ready} / error / no-transcript); VM summary state + debounced edit→`setSummary`; "Regenerate Summary" overflow item + edited-summary confirm; tab-bar status pill; Generate/Regenerate via `Intelligence.generateSummary`; observe enhancement completion → reload. **Tests:** MeetingDetailUITests (tab states, regenerate gating, streaming display, pill visibility, copy).

- [ ] **Phase 6 — Meeting detail: Speaker names + mapping sheet.** `TranscriptContent` name param (color keyed by `speakerID`, cache-key includes names); `SpeakerLink` clickable speaker spans; `SpeakerMappingSheet` (invitees → people → add-by-name → unassigned, apply-on-change); VM sheet assembly via `allPersonData`/calendar + `setSpeakerAssignment`. **Tests:** name-replacement rendering, color stability, sheet option assembly + assign/clear; works model-free.

- [ ] **Phase 7 — End-to-end verification & docs.** On-hardware manual run (download model → record/transcribe → auto speaker-ID + streamed summary → edit/regenerate → manual rename); tune prompt wording if needed; update root `architecture.md`/`implementation_plan.md` roadmap status; optional new ManualTestKit script for the AI features. **Gate:** full `ci` + `build-app` green.

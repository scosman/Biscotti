---
status: complete
---

# Implementation Plan: Import Audio

Each phase is green on `make precommit-checks` on its own. Details live in `architecture.md` and `components/`. Phases 1–2 are behavior-neutral foundations that ship value on their own (the multi-meeting transcription fix).

## Phases

- [ ] **Phase 1: Single-track audio and placeholder titles.**
  - Optional mic/system paths through `Packages/Transcription`: engine, `AudioLoading`, XPC request, `Transcriber`, `SpeakerAnalyzer`, CLI. Plus `XPCServices/BiscottiTranscriber`, `TranscriptionService` + the `Transcribing` seam + the live adapter, `DataStore.audioPaths`, and voiceprint-cli backfill. Mark the recordable `tx_*` manual tests `not-run`.
  - `Meeting.titleIsPlaceholder` and `Meeting.isAIReplaceableTitle`, wired into `applyGeneratedTitle` / `setTitle` / `applyEventTitle`, the two Intelligence gates and `MeetingDetailData`.
  - (architecture §2.1–2.2, §2.4, §3)
- [ ] **Phase 2: Post-processing queue.**
  - `PostProcessingQueue`. `stopRecording` and the test seam move onto it. `enqueueTranscription` / `enqueueReTranscription`. Deletion drops waiting entries.
  - MeetingDetailUI: Retry and Re-transcribe enqueue, plus the "Waiting to transcribe…" state, the pipeline stage and `canReTranscribe`.
  - (architecture §4, §6)
- [ ] **Phase 3: `AudioImport` module and AppCore wiring.**
  - Classifier, AVFoundation converter (real-file tests), metadata reader, `AudioImportController`, `ImportHeaderCopy`, `DataStore.createImportedMeeting`, the `FakeAudioConverter` test support.
  - AppCore: `Route.importing`, `importFiles`, `showImport`, the import-panel request flag, completion → queue + `ImportAutoNavigation`, staging cleanup on launch.
  - (architecture §2.3, §5; components/audio_import.md)
- [ ] **Phase 4: Import screen, sidebar row and File menu.**
  - The `ImportUI` module (`ImportViewModel`, `ImportView`).
  - DesignSystem `BezelButtonStyle` plus the `dropVeil`/`controlStroke` tokens, and `TimeFormatting.dateAndTime`.
  - AppShell: route case, "Imported" sidebar row, `.fileImporter`. App: File > Import Audio File… (⌘⇧I is P3).
  - (ui_design §1, §3, §4, §6; components/import_ui.md §4–5)
- [ ] **Phase 5: Window drop target and overlay.**
  - Spike the placement first (P1 → P2 → P3), then build `WindowDropView` (pasteboard classification, file promises — all promised files if straightforward, else first-only), `DropOverlayState`, `DropOverlayView` and the root wiring.
  - If only P3 works, ship it without pausing and add the confirm item to `backlog.md` (components/import_ui.md §2.6).
  - Ends with the human manual checklist (components/import_ui.md §6) before commit.
  - (ui_design §2; components/import_ui.md §2–3)

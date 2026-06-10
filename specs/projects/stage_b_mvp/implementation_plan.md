---
status: complete
---

# Implementation Plan: Stage B — MVP (Record → Transcribe)

Dependency-ordered phases. **Every phase except the last is agent-completable with no hardware**:
it builds + passes unit tests (and where relevant `build_app`) via `hooks-mcp`, using stubs/seams and
in-memory stores. All hardware/human validation is the single final phase. Each phase ends green on
`lint` + `test` (+ `build_app` from Phase 6) and is one reviewable commit.

## Phases

- [x] **Phase 1 — Leaf modules + DataStore read-models.** Add the `DesignSystem` (tokens +
  `RecordButton`/`StatusRow`/`TranscriptSegmentRow`/`Banner`) and `Permissions` (mic via a
  `MicAuthorizing` seam + settings-URL recovery) targets; add the additive `Sendable` read-model DTOs
  + query methods to `DataStore` (`MeetingSummary`, `MeetingDetailData`, `TranscriptData`,
  `SegmentData`, `meetingSummaries`, `meetingDetail`, `audioPaths`). Wire Package.swift. Unit tests
  for Permissions state machine and the DTO mappers. *(arch §3, §4, §9 DesignSystem)*

- [x] **Phase 2 — `Recording` module.** `RecordingController` over a `RecorderControlling` seam +
  `DataStore` + `Permissions`: start (create meeting → link mic/system `AudioFileRef`s → `.recording`
  marker → start engine → pump elapsed) / stop (stop → clear marker → `markAudioPresence` → return
  meeting id) / `recoverOrphans` (marker scan reconciliation) / system-audio denial inference. Fake
  recorder + in-memory store + temp storage root in tests. *(arch §5, §7)*

- [x] **Phase 3 — `TranscriptionService` module.** `TranscriptionService` over a `Transcribing` seam +
  `DataStore`: `transcribe`/`reTranscribe` → ensure models (message status) → `processAudio` →
  `addTranscript` + `setPreferredTranscript` → per-meeting `JobStatus`; typed error/retry mapping;
  single in-flight job. Fake engine (canned `TranscriptResult` + retriable throw) in tests. *(arch §6)*

- [x] **Phase 4 — `AppCore` coordinator.** Wire Recording + TranscriptionService + Permissions +
  `DataStore` + `route` + `summaries`; `onLaunch` (recover + reload), `startRecording`,
  `stopRecording` (stop → reload → route → auto-enqueue transcribe), `select`. `AppCore.live` factory.
  Headless flow tests (start→stop→transcribe, orphan recovery, routing) with all fakes. *(arch §8)*

- [x] **Phase 5 — UI modules.** `MeetingListUI`, `RecordingUI`, `MeetingDetailUI`, `AppShellUI`
  (view models + SwiftUI views, previews). View-model unit tests: list rendering/selection,
  recording-state rendering, the three Meeting Detail states (downloading/transcribing · transcript ·
  failed+Retry), shell routing. *(arch §9, ui_design.md)*

- [ ] **Phase 6 — App target + XPC integration.** Update `App/project.yml` (add `Transcription` +
  `AudioCapture` packages; add the `BiscottiTranscriber` xpc-service target; app depends on
  `AppShellUI`/`AppCore`/`DataStore` + embeds the XPC service); add Info.plist usage strings + keep
  audio-input entitlement; replace `BiscottiApp.swift` stub with the `AppCore.live` composition root
  presenting `AppShellView` (window-only, no MenuBarExtra). `build_app` green (app + embedded XPC
  compile/link/launch). *(arch §10, §11)*

- [ ] **Phase 7 — Manual hardware validation (human, non-gating).** Run the real app on Apple-silicon:
  first-Record permission prompts (mic + system audio), record→stop→auto-transcribe, first-run model
  download, two-stream quality, re-transcribe, crash-isolation, orphan recovery after a force-quit.
  Record findings; fold any fixes back. Not a merge gate. *(functional_spec §0, §9)*

## Notes

- **Manual-test staleness:** Phases 1–6 **don't edit** `Packages/AudioCapture` or
  `Packages/Transcription`, so the `ac_*`/`tx_*` gate is untouched. (DataStore edits don't affect it.)
- **`// TODO` markers:** every deliberate MVP shortcut (inline-only setup, no version picker, no
  playback, no vocab, single-job, hardcoded title format, private-TCC preflight deferral, license
  attribution) is marked in code for pre-ship cleanup.
- Phases 1–5 are pure `swift test` (fast, agent-friendly). Phase 6 is the only `xcodebuild`/`build_app`
  phase. Phase 7 is the only human/hardware phase.

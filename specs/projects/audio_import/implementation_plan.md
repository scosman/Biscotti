---
status: draft
---

# Implementation Plan: Audio Import

- [x] **Phase 1 — Single-file transcription.** `AudioRole.imported`, `MeetingAudio`,
  optional `systemPath` through XPC/engine/Transcriber/`Transcribing`; `DataStore.audioPaths(meetingID:)` and
  `TranscriptionService.resolveAudioPaths(meetingID:)` return the lone `.imported` file as `mic` (no `system`) so
  imported-only meetings resolve; fakes + tests.
- [x] **Phase 2 — AppCore `importAudio`.** Validator, copy, meeting creation, auto
  transcribe + enhance chain, failure cleanup; tests.
- [x] **Phase 3 — UI.** Toolbar button, File menu command, drag-and-drop, alerts,
  Meeting Detail role handling.
- [ ] **Phase 4 — Verification & docs.** `make lint test`, manual hardware test with
  mp3/m4a/wav, update `CLAUDE.md` stage notes and the README feature list.

Phases 1-3 are implemented and unit-tested (`make lint` and `swift test` pass for `BiscottiKit` and `Transcription`).
Phase 4's on-hardware check (real mp3/m4a/wav through the XPC worker, plus the app target build, which needs `xcodegen`) is left to the author; `tx_*` manual tests are reset to `not-run` per the repo rule.

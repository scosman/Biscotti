---
status: complete
---

# Implementation Plan: Record Screen Redesign

Ordered, dependency-respecting phases. Each phase is one reviewable unit and ends
green on `precommit_checks` (format + lint + test) before commit. Details live in
`functional_spec.md`, `ui_design.md`, and `architecture.md` — this is the build
order, not a restatement.

## Phases

- [x] **Phase 1 — DesignSystem foundations + shared title.**
  Add the new color tokens (§11 / ui_design §2) and the reusable
  `LightAlertButtonStyle`. Extract the inline meeting-detail title control into a
  shared `EditableMeetingTitle` (`DesignSystem`) and refactor `MeetingDetailView`
  to use it — behavior-preserving. (Foundation for Phases 3–5.)

- [x] **Phase 2 — Notes backend + markdown seeding (no UI).**
  Add `MeetingNote`; `RecordingController` notes state + `addNote/updateNote/
  removeNote`, reset on `start()`, seed on `stop()`. Add the pure `NotesMarkdown`
  generator (link format `biscotti://meeting/{id}?time=…`, oldest-first, merge).
  Unit tests for generator + controller notes/seeding. (Produces the deep-link
  URLs consumed in Phase 6.)

- [ ] **Phase 3 — Recording pane core (view model + view).**
  Rework `RecordingViewModel` (load detail, title via shared control, submeta,
  Elapsed/Left/Over chips with the amber warning, notes proxy, `stop` committing
  the composer) and rebuild `RecordingView` (center-then-scroll layout, RECORDING
  badge, light Stop & Save, title, submeta, time chips, composer, notes list with
  inline edit + hover-✕, retained system-audio banner). Add
  `reloadSummaries()` after calendar association in `startRecording`. Pure-logic
  unit tests (chips, submeta builders). Depends on 1 + 2.

- [ ] **Phase 4 — Auto-stop "Auto-stopping soon" section.**
  Additive `AppCore.autoStop` state + `keepRecording()` (leave the merged
  notification/sleep path intact); render the top-of-column countdown card with
  the `TimelineView` decreasing bar + Keep Recording (reduced-motion aware).
  Update existing auto-stop tests; add `autoStop`/`keepRecording` tests. Depends
  on 1 + 3.

- [ ] **Phase 5 — Chrome: header button + sidebar RECORDING NOW.**
  Restyle the toolbar record button's recording state (lighter + bigger, pulsing
  dot, "REC m:ss") via `LightAlertButtonStyle`; idle unchanged. Add the sidebar
  "RECORDING NOW" section/row (tint, no badge, navigates to the pane) +
  `AppShellViewModel.recordingMeetingTitle`. Depends on 1.

- [ ] **Phase 6 — `biscotti://meeting` deep link end-to-end.**
  Register the `biscotti` URL scheme (Info.plist); `BiscottiApp.onOpenURL` →
  `AppDelegate` → `AppCore.handleDeepLink` + `pendingTranscriptJump`/`consume`;
  lift `MeetingDetailView.Tab` into its VM and apply the pending jump (switch to
  Transcript + seek, clamped, deferring until audio loads). Unit tests for
  parsing + jump application. Depends on 2.

---
status: complete
---

# Phase 12: Record button — stateful redesign

## Overview

Replace the toolbar Record button with a two-state control (idle vs recording), remove the
now-duplicated recording indicator from the sidebar, and remove the big Start Recording button from
the Home screen. The toolbar button becomes the single, app-wide recording-status affordance.

## Steps

### 1. AppShellViewModel — replace recording properties

- Remove `recordButtonDisabled` (no longer needed; button is never disabled, just changes state).
- Remove `showRecordingIndicator` (sidebar indicator is being removed).
- Keep `recordingElapsedText` but change its format to match the toolbar label: `M:SS` for
  under-an-hour, `H:MM:SS` for >= 1 hour (reuse the pattern from `RecordingViewModel.formatElapsed`
  but with non-padded minutes: `1:53` not `01:53`). This matches the existing format which already
  does `"%d:%02d"`.
- Add `isRecording: Bool` computed property (proxies `core.recording.state.isRecording`).
- Keep `startRecording()` and `showRecording()` (both are used by the new button).

### 2. AppShellView — stateful toolbar button

Replace the current toolbar Record button with a stateful view:
- **Idle:** `Button { startRecording } label: { Image("record.circle") tinted red + "Record" }`.
  Style: `.bordered` (less prominent than the recording state).
- **Recording:** `Button { showRecording } label: { Image("record.circle") white + "Recording… M:SS" }`.
  Style: `.borderedProminent` with `.tint(Tokens.recordingRed)` (bold red, white text/icon).

The elapsed time updates automatically because `recordingElapsedText` reads from the observable
`core.recording.state.elapsed` which is pumped every ~1s by the existing `RecordingController`.
No new timer is needed.

### 3. AppShellView — remove sidebar recording indicator

Remove the `if viewModel.showRecordingIndicator { recordingIndicator }` block and the
`recordingIndicator` computed property from the sidebar.

### 4. HomeView — remove Start Recording button

Remove the `StartRecordingButton` from `HomeView`. Remove `startRecording()` and `startDisabled`
from `HomeViewModel` (now unused).

### 5. Update tests

- **AppShellViewModelTests:** Remove tests for `recordButtonDisabled` and `showRecordingIndicator`.
  Add test for `isRecording` (false when idle, true when recording). Update `recordingElapsedText`
  test. Add test that toolbar button action when idle calls startRecording (covered by existing
  routing test). Add test that toolbar button action when recording calls showRecording
  (navigateToRecording).
- **HomeViewModelTests:** Remove the `startDisabled` test and `startRecording delegates` test
  (those properties/methods are removed).

## Tests

- `isRecording is false when idle`: verify `viewModel.isRecording == false` on fresh fixture.
- `isRecording is true when recording`: start recording, verify `viewModel.isRecording == true`.
- `recordingElapsedText formats M:SS at zero`: verify `viewModel.recordingElapsedText == "0:00"`.
- `showRecording navigates to recording when recording` (existing test, kept).
- `showRecording no-op when not recording` (existing test, kept).
- `startRecording routes to .recording` (existing test, kept).
- HomeViewModelTests: `startDisabled` and `startRecordingDelegates` tests removed (dead code).

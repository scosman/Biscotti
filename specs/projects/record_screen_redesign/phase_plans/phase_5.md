---
status: complete
---

# Phase 5: Chrome -- Header Button + Sidebar RECORDING NOW

## Overview

Restyle the toolbar record button's RECORDING state (lighter + bigger, pulsing
dot, "REC m:ss") using `LightAlertButtonStyle` from Phase 1, while keeping the
IDLE state unchanged. Add the sidebar "RECORDING NOW" section/row (tinted, no
badge, navigates to the recording pane). Add
`AppShellViewModel.recordingMeetingTitle` computed from summaries. Unit tests
for the testable pure logic (`recordingMeetingTitle` derivation, "REC m:ss"
formatting is already tested via `formatElapsed`).

## Steps

1. **Add `recordingMeetingTitle` to `AppShellViewModel`.**
   Computed property that finds the summary matching
   `core.recording.state.meetingID` in `core.summaries` and returns its title,
   with a fallback of "Untitled Meeting".

2. **Restyle the toolbar record button recording branch in `AppShellView`.**
   Replace `ToolbarRecordButtonStyle(fill: Tokens.recordingRed)` with
   `LightAlertButtonStyle()`. The label becomes: 8pt `signalRed` dot with a
   slow pulse animation (~1.6s, gated on `accessibilityReduceMotion`), then
   "REC {m:ss}" in `.monoMetaMedium` `signalRed`, with increased horizontal
   padding (~16) and height (~34) -- bigger than idle. The idle branch stays
   exactly as-is.

3. **Add the "RECORDING NOW" sidebar section in `AppShellView`.**
   A new `RecordingNowSection` extracted struct (matching the
   `UpcomingSidebarSection` pattern), placed after the brand lockup and before
   `homeRow`, shown only when `viewModel.isRecording`. Contains:
   - Kicker "RECORDING NOW" (`.kicker()`, `signalRed`).
   - One two-line row: title (`viewModel.recordingMeetingTitle`, `.body`,
     `ink`, 1 line) + "Recording" subtitle (`.monoMeta`, `signalRed`).
   - Background `recordingTintSoft`; when `route == .recording`,
     `recordingTintStrong` fill + 0.5pt inset `recordingOutlineStrong` stroke.
   - Tap -> `viewModel.showRecording()`.
   - Divider below.

4. **Write unit tests for `recordingMeetingTitle`.**
   - Returns fallback when not recording.
   - Returns the matching summary title when recording.
   - Returns fallback when recording but summary not found.

## Tests

- `recordingMeetingTitle returns fallback when not recording`
- `recordingMeetingTitle returns meeting title when recording`
- `recordingMeetingTitle returns fallback when summary not found`

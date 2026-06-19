---
status: complete
---

# Phase 2: Reduce "RECORDING" emphasis

## Overview

The active-recording state is currently emphasized in three simultaneous places: the toolbar REC button, the sidebar RECORDING NOW section (red-tinted backdrop), and the in-page RECORDING badge. This phase reduces redundancy with two changes: normalizing the sidebar row styling (2a) and disabling the toolbar button when already on the recording page (2b).

## Steps

### 2a: Normalize the sidebar RecordingNowSection

1. In `AppShellView.swift`, modify `RecordingNowSection`:
   - Replace the `.background(RoundedRectangle(...).fill(isSelected ? Tokens.recordingTintStrong : Tokens.recordingTintSoft))` with `.background(isSelected ? Tokens.accentWashStrong : Color.clear, in: RoundedRectangle(cornerRadius: 4))` -- matching `homeRow`, `pastMeetingsRow`, etc.
   - Remove the `.overlay(Group { if isSelected { RoundedRectangle(...).strokeBorder(Color.recordingOutlineStrong, ...) } })` entirely.
   - Change the "Recording" subtitle from `.foregroundStyle(Color.signalRed)` to `.foregroundStyle(Color.inkSecondary)` (matches `Tokens.secondaryText`).

### 2b: Disable the top-right recording button while on the recording page

1. In `AppShellViewModel.swift`, add a computed property:
   ```swift
   public var isOnRecordingPage: Bool {
       core.route == .recording
   }
   ```
   Place it next to the existing `isHome` property.

2. In `AppShellView.swift`, apply `.disabled(viewModel.isOnRecordingPage)` to the `RecordingToolbarButton` (the `if viewModel.isRecording` branch, ~line 87).

## Tests

- `isOnRecordingPage true when route is .recording`: start recording, verify `isOnRecordingPage == true`.
- `isOnRecordingPage false when route is not .recording`: verify false on home, settings, meetings routes.
- `isOnRecordingPage false when recording but on a different route`: start recording, navigate to meetings, verify false.

Note: 2a is purely visual (SwiftUI view changes) and does not warrant unit tests. The view still renders the same button with the same action; only colors/backgrounds change.

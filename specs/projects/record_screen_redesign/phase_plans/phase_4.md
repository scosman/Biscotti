---
status: complete
---

# Phase 4: Auto-stop "Auto-stopping soon" countdown section

## Overview

Surfaces the existing mic-driven auto-stop countdown on the recording pane as a
prominent card with a decreasing progress bar and a "Keep Recording" button. This
phase adds the `AutoStopState` observable to `AppCore` (set when the countdown
begins, cleared on cancel/stop/fire), exposes it through `RecordingViewModel`,
and renders the card in `RecordingView`. The existing notification/sleep auto-stop
path remains intact -- this is purely additive.

## Steps

1. **Add `AutoStopState` to `AppCore`.**
   - New `public struct AutoStopState: Sendable, Equatable` with `meetingID: UUID`,
     `deadline: Date`, `total: TimeInterval`.
   - New `public private(set) var autoStop: AutoStopState?` on `AppCore`.
   - In `beginAutoStopCountdown`: set `autoStop = AutoStopState(...)` with
     `deadline = Date() + autoStopSeconds` and `total = autoStopSeconds`.
   - In `cancelAutoStopCountdown`: set `autoStop = nil`.
   - `stopRecording` already calls `cancelAutoStopCountdown`, so `autoStop` is
     cleared on stop. The auto-fire path calls `stopRecording`, which also clears.

2. **Add `keepRecording()` to `AppCore`.**
   - `public func keepRecording()`: if `runState` is `.recording(id)`, call
     `cancelAutoStopCountdown(meetingID: id)`.

3. **Add `autoStopCountdown` + `keepRecording()` to `RecordingViewModel`.**
   - `autoStopCountdown: AutoStopState?` -- returns `core.autoStop` only when
     its `meetingID` matches the current recording's meeting ID.
   - `keepRecording()` -- delegates to `core.keepRecording()`.

4. **Add the countdown card to `RecordingView`.**
   - Conditional section at the top of `mainColumn` when
     `viewModel.autoStopCountdown != nil`.
   - Uses `TimelineView(.animation)` (or `.periodic(by: 1)` for reduce motion)
     to compute `remaining = max(0, deadline - context.date)`.
   - Shows: "Auto-stopping soon" + "{n}s" label, a capsule progress bar
     (fill width = remaining / total), and a "Keep Recording" button.
   - Reduce motion: `TimelineView(.periodic(from: .now, by: 1))`, bar steps
     without smooth tween.
   - Extract into `AutoStopCountdownCard` (separate file or extension) to stay
     within body-length lint limits.

5. **Update existing auto-stop tests to assert `autoStop` state.**
   - In `autoStopCountdownFiresAndStops`: assert `core.autoStop != nil` after
     countdown begins, `core.autoStop == nil` after it fires.
   - In `keepRecordingCancelsActiveCountdown`: assert `core.autoStop != nil`
     before keep, `core.autoStop == nil` after.
   - In `manualRecordingAutoStopsOnMicUserStop`: assert `core.autoStop != nil`
     during countdown.
   - In `stopRecordingCancelsCountdownAndNotification`: assert `autoStop == nil`.

6. **Add new unit tests for `autoStop` / `keepRecording`.**
   - `autoStopCountdown` derivation: returns nil when no countdown, returns nil
     when countdown is for a different meeting, returns the state when matching.
   - `keepRecording()` clears `autoStop`.
   - `stopRecording()` clears `autoStop`.
   - `RecordingViewModel.autoStopCountdown` returns non-nil only for matching
     meeting ID.
   - `RecordingViewModel.keepRecording()` delegates correctly.

## Tests

- `autoStopCountdownFiresAndStops` -- (updated) assert autoStop set then cleared
- `keepRecordingCancelsActiveCountdown` -- (updated) assert autoStop cleared
- `manualRecordingAutoStopsOnMicUserStop` -- (updated) assert autoStop set
- `stopRecordingCancelsCountdownAndNotification` -- (updated) assert autoStop nil
- `testAutoStopStateSetOnCountdownBegin` -- new: verify autoStop is non-nil with correct fields
- `testAutoStopStateClearedOnKeepRecording` -- new: keepRecording clears autoStop
- `testAutoStopStateClearedOnStop` -- new: stopRecording clears autoStop
- `testAutoStopCountdownNilWhenNoCountdown` -- new VM test
- `testAutoStopCountdownNilForDifferentMeeting` -- new VM test
- `testAutoStopCountdownMatchesCurrentMeeting` -- new VM test
- `testKeepRecordingDelegates` -- new VM test

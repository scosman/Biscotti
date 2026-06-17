---
status: complete
---

# Phase 3: Recording Pane Core (View Model + View)

## Overview

Rework `RecordingViewModel` to own the recording pane's data (meeting detail
load, title edit/save via the shared control, submeta builders, Elapsed/Left/Over
time chips with amber warning, notes proxy, stop with composer commit) and
rebuild `RecordingView` to the new centered-column layout: RECORDING badge,
light Stop & Save button, editable title, submeta line, time chips, note
composer, notes list with inline edit and hover-delete, retained system-audio
banner. Pure-logic unit tests cover time chip computation and submeta builders.

Also adds `reloadSummaries()` after calendar association in
`AppCore.startRecording` so the VM's `.task(id:)` picks up the calendar context.

## Steps

1. **Update `AppCore.startRecording`** to call `await reloadSummaries()` after
   `associateEvent` so the recording VM can observe calendar context.

2. **Rework `RecordingViewModel`** (`RecordingUI/RecordingViewModel.swift`):
   - Add `detail: MeetingDetailData?`, `load()` async method.
   - Add `editableTitle: String`, `saveTitle()` mirroring
     MeetingDetailViewModel.
   - Add submeta computed properties: `hasEvent`, `scheduleText`,
     `platformText`, `openInCalendar()`, `startedClockText`.
   - Add `LeftChip` enum and static `leftChip(scheduledEnd:now:)` pure function.
   - Add notes proxy: `notes`, `addNote`, `updateNote`, `removeNote`.
   - Rework `stop(pendingComposer:)` to commit non-empty composer text first.
   - Keep `showSystemAudioWarning`, `systemAudioSettingsURL`, `isRecording`,
     `elapsedText` (existing).
   - Add `meetingID: UUID?` convenience.

3. **Rebuild `RecordingView`** (`RecordingUI/RecordingView.swift`):
   - Center-then-scroll layout with `ScrollView` + min-height spacers.
   - Status row: RECORDING badge (pulsing dot + ripple, reduced-motion aware) +
     Stop & Save button (`LightAlertButtonStyle`).
   - Editable title via `EditableMeetingTitle`.
   - Submeta line (event: time range + platform + "Open in calendar"; ad-hoc:
     "Started {clock} + No calendar event").
   - Time chips (Elapsed always; Left/Over conditional, amber warning).
   - Hairline divider.
   - Note composer (text field + "Add note" button).
   - Notes list (newest-first, timestamp + text, hover-delete, inline edit).
   - System-audio banner (retained, maxWidth 400).
   - `.task(id: meetingID)` loads detail and re-loads on `core.summaries`
     changes.

4. **Add pure-logic unit tests** (`RecordingUITests/RecordingViewModelTests.swift`):
   - `leftChip` static function: none (nil scheduledEnd), normal (>5min),
     warning (<=5min), overtime (past end), label formatting.
   - `scheduleText` / `platformText` / `startedClockText` builders.
   - `stop(pendingComposer:)` commits non-empty, skips empty.

## Tests

- `testLeftChipNoneWhenNoScheduledEnd`: nil scheduledEnd -> .none
- `testLeftChipNormalAboveFiveMinutes`: >300s remaining -> .normal with label
- `testLeftChipWarningAtFiveMinutes`: <=300s remaining -> .warning with label
- `testLeftChipOvertimePastEnd`: past scheduledEnd -> .overtime with "+m:ss"
- `testLeftChipOvertimeLabel`: correct "+m:ss" formatting
- `testSubmetaScheduleText`: correct time range formatting
- `testSubmetaPlatformText`: platform present vs absent
- `testSubmetaStartedClockText`: ad-hoc clock text
- `testStopWithPendingComposer`: non-empty composer text added as note
- `testStopWithEmptyComposer`: empty composer text not added

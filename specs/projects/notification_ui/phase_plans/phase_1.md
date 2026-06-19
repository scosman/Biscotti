---
status: complete
---

# Phase 1: Settings -- persistence, wiring, UI, and gating

## Overview

Adds three notification settings end-to-end: persistence in DataStore, cached settings + live observers + behavior gating in AppCore, and the SettingsUI section with two toggles, a picker, and a disabled/badge state.

## Steps

### DataStore

1. Create `DataStore/Models/CalendarNotificationMode.swift` with enum mirroring `MenuBarLeadTime` shape (String rawValue, CaseIterable, Sendable, Identifiable, displayText, init(raw:) fallback).
2. Add three stored properties to `AppSettings.swift`: `monitorForMeetings: Bool = true`, `stopRecordingAutomatically: Bool = true`, `calendarNotificationModeRaw: String = "allMeetings"`. Add matching init parameters.
3. Add three fields to `AppSettingsData` DTO in `DataStore+ReadModels.swift`: `monitorForMeetings`, `stopRecordingAutomatically`, `calendarNotificationMode: CalendarNotificationMode`. Update `settings()` read mapping and `updateSettings` write mapping.

### AppCore

4. Add three `Notification.Name`s: `monitorForMeetingsDidChange`, `calendarNotificationModeDidChange`, `stopRecordingAutomaticallyDidChange`.
5. Add cached properties: `monitorForMeetings`, `calendarNotificationMode`, `stopRecordingAutomatically`. Load in `onLaunch()` via `loadNotificationSettings(from:)`.
6. Add `startNotificationSettingsObservers()` (three tasks mirroring `startMenuBarLeadTimeObserver`). Calendar mode observer also calls `scheduleCalendarTimers()`.
7. Add monitor guard at top of `handleDetectionStarted`: `guard monitorForMeetings else { return }`.
8. Add auto-stop guard at top of `handleAllMicUsersStopped`: `guard stopRecordingAutomatically else { return }`.
9. Add `eventsToNotify(_:mode:)` static filter. Update `scheduleCalendarTimers()` to use it. Add re-check guard in `handleCalendarTimerFired`.

### SettingsUI

10. Add `monitorForMeetings`, `calendarNotificationMode`, `stopRecordingAutomatically` properties + `calendarNotificationsDisabled` computed on `SettingsViewModel`. Add three setters (persist + post Notification.Name + revert on failure). Update `load()`.
11. Add `notificationsSection` to `SettingsView` between General and Permissions: Monitor toggle (Row 1), Calendar picker with disabled/badge state (Row 2), Stop Recording toggle (Row 3).

## Tests

### DataStore
- `CalendarNotificationMode` rawValue stability, displayText, allCases count, init(raw:) fallback
- `AppSettings`/DTO round-trip for the three new fields with defaults and explicit values

### AppCore
- `eventsToNotify` -- `.never` returns empty; `.videoConferencing` filters to conferenceURL-bearing events; `.allMeetings` filters to isMeetingLike
- Detection gating: `handleDetectionStarted` no-ops when `monitorForMeetings == false` (no notification, no detectedPending)
- Auto-stop gating: `handleAllMicUsersStopped` no-ops when `stopRecordingAutomatically == false`

### SettingsUI
- SettingsViewModel setters persist and post correct Notification.Name
- SettingsViewModel `load()` populates the three fields from store
- `calendarNotificationsDisabled` reflects `calendarState`

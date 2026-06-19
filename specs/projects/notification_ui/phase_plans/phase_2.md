---
status: complete
---

# Phase 2: Notification presentation & copy

## Overview

Reworks the notification content, categories, and actions for meeting-detected and calendar-event notifications. Updates meeting-detected copy to "Meeting detected" / "App: {name}"; sets `.timeSensitive` on both notification types; replaces the two-button calendar flow (Open & Record + Join) with a single "Record & Join" / "Record" action; removes the `.join` action/enum case entirely; adds `cancelAdHocDetected()` to dismiss lingering meeting-detected banners on record start; and rewrites the AppDelegate URL-open / window-foreground logic.

## Steps

### Notifications module

1. **NotificationIdentifiers.swift** -- Remove `ActionID.openAndRecord` and `ActionID.join`; add `ActionID.recordAndJoin`. Keep `record` and `keepRecording` unchanged.

2. **NotificationAction.swift** -- Remove the `.join(URL)` case. Only `.openAndRecord(eventKey:)` and `.keepRecording(meetingID:)` remain.

3. **NotificationService.swift -- categories** -- Rewrite `registerCategories()`:
   - `meetingStarting` (no link): single `record` action, title "Record", options `[]`.
   - `meetingStartingWithJoin` (link): single `recordAndJoin` action, title "Record & Join", options `[]`.
   - `adHocDetected`: `record` action unchanged, keeps `.customDismissAction`.
   - `stopCountdown`: `keepRecording` unchanged.

4. **NotificationService.swift -- ad-hoc content** -- In `makeRequest(for:)`, change `.adHocDetected` case: title = "Meeting detected", subtitle = "App: {appName}", body = "", interruptionLevel = `.timeSensitive`.

5. **NotificationService.swift -- meeting-start content** -- In `fillMeetingStartContent`, set `content.interruptionLevel = .timeSensitive`.

6. **NotificationService.swift -- cancelAdHocDetected()** -- Add `presentedAdHocIDs: Set<String>` tracking. In `present(_:)`, after successful add for `.adHocDetected`, insert the request identifier. Add `public func cancelAdHocDetected() async` that removes pending+delivered and clears tracking.

7. **ResponseMapper.swift** -- Rewrite `mapMeetingStartResponse`: for both meeting categories, `recordAndJoin` / `record` / `UNNotificationDefaultActionIdentifier` all map to `.openAndRecord(eventKey:)`. Remove the `.join` branch entirely.

### AppCore

8. **AppCore.swift -- startRecording** -- After the runState guard, call `await notifications.cancelAdHocDetected()`.

9. **AppCore.swift -- consumeNotificationActions** -- Remove the `.join` case (enum case is gone).

### App target

10. **BiscottiApp.swift -- didReceive delegate** -- Rewrite the post-handleResponseValues block:
    - Open the call link for Record & Join: if category is `meetingStartingWithJoin` and action is `recordAndJoin` or default, open the joinURL.
    - Foreground Biscotti only for ad-hoc Record and Keep-Recording, never for calendar notifications.
    - Remove the old `biscotti.action.join` URL block and the `open-and-record` window-foreground.

## Tests

### Notifications

- **ResponseMapper**: `recordAndJoin` / `record` / default on both meeting categories map to `.openAndRecord(eventKey:)`. Ad-hoc unchanged. No `.join` test. Dismiss returns nil.
- **CategoryRegistration**: Update meeting-starting to expect `record` (title "Record"), no foreground. Update meeting-starting-with-join to expect single `recordAndJoin` (title "Record & Join"), no foreground. Ad-hoc and countdown unchanged.
- **ContentConstruction**: Ad-hoc sets title = "Meeting detected", subtitle = "App: {name}", body = "". Both meeting-start and ad-hoc set `.timeSensitive`. (Update existing tests + add new assertions.)
- **cancelAdHocDetected**: Present an ad-hoc, then cancel -- asserts removed pending+delivered IDs match the ad-hoc identifier; clears tracking on second cancel (no-op).

### AppCore

- **startRecording calls cancelAdHocDetected**: Drive through the fixture; present an ad-hoc detection, then startRecording; assert the ad-hoc identifiers appear in removedPendingIDs/removedDeliveredIDs.

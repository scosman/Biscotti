---
status: complete
---

# Phase 1: Notification Cleanup

## Overview

Implements all notification cleanup behaviors (C1, C2, D1, L1, L2) in one phase: the `Notifications` module gets new removal/query methods and the `start` field on `meetingStarting`, while `AppCore` gets expiry timers, recording-start removal, detection-stop removal, and launch cleanup. Both test fakes model delivery so the new code is testable without hardware.

## Steps

1. **NotificationKind.swift** -- add `start: Date` to `.meetingStarting(eventKey:title:joinURL:start:)`.
2. **NotificationIdentifiers.swift** -- add `UserInfoKey.eventStart`, add `meetingStartRequestIdentifier(eventKey:)` and `adHocRequestIdentifier(bundleID:)` free functions; refactor `requestIdentifier(for:)` to call them.
3. **NotificationCenterProviding.swift** -- add `deliveredNotifications() async -> [DeliveredNotification]` and the `DeliveredNotification` value type.
4. **LiveNotificationCenter.swift** -- implement `deliveredNotifications()` by mapping `UNNotification` to `DeliveredNotification`.
5. **PreviewAppCore.swift** -- add `deliveredNotifications()` returning `[]` to `PreviewNotificationCenter`.
6. **NotificationService.swift** -- write `eventStart` into `userInfo` in `fillMeetingStartContent`; add `DeliveredOfferNotification`, `cancelMeetingStarting(eventKey:)`, `cancelAllMeetingStarting()`, `cancelAdHocDetected(bundleID:)`, `deliveredOfferNotifications()`; update `makeRequest` switch for the new `start` parameter.
7. **FakeNotificationCenter** (NotificationsTests) -- add `delivered` backing, update `add`/`removeDeliveredNotifications`, add `deliveredNotifications()`.
8. **FakeTestNotificationCenter** (CoreFixture.swift) -- same delivery-modelling changes.
9. **AppCore.swift** -- add `calendarNotificationLifetime`, `calendarNotificationExpiryTasks`, `scheduleCalendarNotificationExpiry`, `cancelAllCalendarNotificationExpiryTasks`; update `handleCalendarTimerFired` with `shouldPostCalendarNotification` guard + expiry scheduling + `start:` argument; update `startRecording` with `cancelAllCalendarNotificationExpiryTasks` + `cancelAllMeetingStarting`; make `handleDetectionStopped` async and add `cancelAdHocDetected(bundleID:)`; add `cleanUpStaleNotificationsOnLaunch`, `launchNotificationCleanupPlan`, `shouldPostCalendarNotification`, `ScheduledExpiry`, `LaunchNotificationCleanupPlan`; call cleanup from `startBackgroundServices`.
10. Update all existing test call sites that construct `.meetingStarting` to include `start:`.
11. **NotificationsTests/NotificationCleanupTests.swift** -- new file with tests per architecture section 4.2.
12. **AppCoreTests/NotificationCleanupTests.swift** -- new file with tests per architecture section 4.3.

## Tests

- `cancelMeetingStarting(eventKey:)` removes the correct ID from pending and delivered
- `cancelAdHocDetected(bundleID:)` removes the single-app ID and drops from tracking
- `cancelAllMeetingStarting()` removes all meeting-start entries, leaves others
- `cancelAllMeetingStarting()` with no entries makes no remove calls
- Cancel methods run when authorization is denied
- `meetingStarting` request has `userInfo[eventStart]` equal to `String(start.timeIntervalSince1970)`
- `deliveredOfferNotifications()` parses meeting-start, meeting-start fallback, ad-hoc, skips others
- C1: calendar notification posted then removed after 300s
- C1 survives calendar refresh (expiry not cancelled by `scheduleCalendarTimers`)
- `shouldPostCalendarNotification` boundary test (true < 300s, false >= 300s)
- C2: recording start removes calendar notification and drops expiry task
- D1 pending: `.stopped(app)` removes that app's ad-hoc notification
- D1 other app: only the stopped app's notification is removed
- D1 while recording: still calls remove
- L1 plan (pure): correct three lists, boundary `expiry == now` -> remove
- L1 integration: seed delivered, launch, verify removals and deferred expiry

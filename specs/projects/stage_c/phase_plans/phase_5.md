---
status: complete
---

# Phase 5: Notifications Module

## Overview

Build the `Notifications` module — manages user-facing macOS notifications (categories, actions,
content), delivers/updates/cancels notifications through a `NotificationCenterProviding` seam, and
publishes a typed `AsyncStream<NotificationAction>` for AppCore. Authorization is relayed to
`Permissions` via the existing `NotificationAuthorizing` seam. This module presents and reports intent
only; AppCore performs the actions.

New `Notifications` target in BiscottiKit (L1, depends on UserNotifications only — no internal module
deps). Full unit tests against a `FakeNotificationCenter`.

## Steps

1. **Create target directories.**
   - `Sources/Notifications/`
   - `Tests/NotificationsTests/`

2. **Add `Notifications` target + test target to `Package.swift`.**
   - New product: `.library(name: "Notifications", targets: ["Notifications"])`.
   - New target: `Notifications`, no internal deps (uses only `UserNotifications` + `Foundation`).
   - New test target: `NotificationsTests`, depends on `Notifications`.

3. **Create `NotificationKind.swift` — domain types.**
   ```swift
   public enum NotificationKind: Sendable, Equatable {
       case meetingStarting(eventKey: String, title: String, joinURL: URL?)
       case adHocDetected(bundleID: String, appName: String)
       case stopCountdown(meetingID: UUID, secondsRemaining: Int)
   }
   ```

4. **Create `NotificationAction.swift` — typed user intent.**
   ```swift
   public enum NotificationAction: Sendable, Equatable {
       case openAndRecord(eventKey: String?)
       case join(URL)
       case keepRecording(meetingID: UUID)
   }
   ```

5. **Create `NotificationIdentifiers.swift` — category/action/request/userInfo ID constants.**
   Internal enums: `CategoryID`, `ActionID`, `UserInfoKey`, plus a `requestIdentifier(for:)` helper
   that produces the stable per-kind request ID.

6. **Create `NotificationCenterProviding.swift` — the seam protocol.**
   ```swift
   public protocol NotificationCenterProviding: Sendable {
       func requestAuthorization() async throws -> Bool
       func setCategories(_ categories: Set<UNNotificationCategory>)
       func add(_ request: UNNotificationRequest) async throws
       func removePendingRequests(withIdentifiers ids: [String])
       func removeDeliveredNotifications(withIdentifiers ids: [String])
       func authorizationStatus() async -> UNAuthorizationStatus
   }
   ```

7. **Create `LiveNotificationCenter.swift` — production wrapper around `UNUserNotificationCenter.current()`.**

8. **Create `ResponseMapper.swift` — the pure mapping function.**
   ```swift
   func mapResponse(categoryID: String, actionID: String, userInfo: [AnyHashable: Any]) -> NotificationAction?
   ```
   Extracts typed `NotificationAction` from raw delegate response data. Testable without
   `UNNotificationResponse`.

9. **Create `NotificationService.swift` — the main coordinator.**
   - `@MainActor public final class NotificationService`
   - `init(provider:)` registers all four categories via `provider.setCategories(...)`.
   - `requestAuthorization() async -> Bool` — delegates to provider.
   - `present(_:) async` — builds `UNMutableNotificationContent` per kind, checks cached auth
     status, adds via provider.
   - `updateCountdown(meetingID:secondsRemaining:) async` — re-adds with same stable ID.
   - `cancelCountdown(meetingID:) async` — removes pending + delivered.
   - `actions() -> AsyncStream<NotificationAction>` — lazy, single-consumer.
   - `handleResponse(_:) -> Bool` — uses `mapResponse` + yields to continuation.
   - `foregroundPresentationOptions(for:) -> UNNotificationPresentationOptions`.

10. **Write unit tests in `NotificationsTests/`.**
    - `FakeNotificationCenter` conforming to `NotificationCenterProviding`: records all calls, can
      script authorization results.
    - Test cases per the component spec test plan (split across multiple files for lint compliance).

## Tests

- **registersCategoriesOnInit** — `setCategories` called once with 4 category IDs, correct actions per category.
- **meetingStartingContentUsesEventTitle** — content title, category, sound, userInfo for meeting-start without joinURL.
- **meetingStartingWithJoinUsesJoinCategory** — join variant uses the `with-join` category + userInfo includes URL.
- **adHocContentNamesApp** — content title contains app name, correct category + userInfo.
- **stopCountdownContentShowsSeconds** — title contains seconds value, correct category.
- **meetingStartRequestIDContainsEventKey** — request ID varies by event key.
- **countdownUpdateReusesIdentifier** — update uses same request ID as initial present.
- **adHocRequestIDContainsBundleID** — request ID varies by bundle ID, reuses for same.
- **cancelCountdownRemovesPendingAndDelivered** — both remove methods called with correct ID.
- **delegateResponseMapsToOpenAndRecord** — meeting-start + open-and-record action -> `.openAndRecord(eventKey:)`.
- **joinActionMapsToJoinURL** — join action -> `.join(url)`.
- **adHocRecordActionMapsToOpenAndRecordNilKey** — ad-hoc record -> `.openAndRecord(eventKey: nil)`.
- **keepRecordingActionMapsToKeepRecording** — countdown keep-recording -> `.keepRecording(meetingID:)`.
- **defaultActionOnMeetingStartMapsToOpenAndRecord** — banner tap on meeting-start -> `.openAndRecord`.
- **dismissActionIsNotEnqueued** — dismiss returns false, stream does not yield.
- **requestAuthorizationReturnsProviderResult** — true/false pass-through.
- **deniedAuthMakesPresentNoOp** — denied status -> `add` not called.
- **cancelCountdownWorksWhenDenied** — remove calls still execute when auth denied.
- **foregroundMeetingStartShowsBannerAndSound** — returns `[.banner, .sound]` for meeting-start.
- **foregroundCountdownShowsListOnly** — returns `[.list]` for countdown.

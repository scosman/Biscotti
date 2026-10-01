---
status: complete
---

# Architecture: Notification Cleanup

Implements `functional_spec.md` (C1, C2, D1, L1, L2). Small project: one architecture doc, no component docs.

Paths are relative to `Packages/BiscottiKit/`.

## Overview and Ownership

The existing split stays:

- **`Notifications` module (`NotificationService`)**: owns notification identifiers, `userInfo` encoding/decoding, and the calls to `NotificationCenterProviding`. It gets new *removal* and *query* methods. It has no timers and no policy.
- **`AppCore`**: owns all timers (convention from `stage_c/components/notifications.md`: AppCore runs its own timers via the `AppScheduler` seam) and all policy (the 5-minute lifetime, when to remove what).

No new module. No new dependency.

## 1. `Notifications` module changes

### 1.1 `NotificationKind.meetingStarting` gets the event start

`Sources/Notifications/NotificationKind.swift`:

```swift
case meetingStarting(eventKey: String, title: String, joinURL: URL?, start: Date)
```

Update all pattern matches (`requestIdentifier(for:)`, `makeRequest(for:)`) and test call sites (`ContentConstructionTests`, `ForegroundPresentationTests`, `RequestIdentifierTests`, `CancelAdHocTests`). The request identifier does **not** change (`biscotti.notif.meeting-start.<eventKey>`).

### 1.2 Event start in `userInfo`

`NotificationIdentifiers.swift`: add `UserInfoKey.eventStart = "biscotti.eventStart"`.

`fillMeetingStartContent` writes `info[UserInfoKey.eventStart] = String(start.timeIntervalSince1970)`. (All `userInfo` values stay `String`.) The launch cleanup (L1) reads it back. `ResponseMapper` ignores unknown keys, so it needs no change.

Add a free function next to `countdownRequestIdentifier`:

```swift
func meetingStartRequestIdentifier(eventKey: String) -> String   // "biscotti.notif.meeting-start.\(eventKey)"
func adHocRequestIdentifier(bundleID: String) -> String           // "biscotti.notif.adhoc.\(bundleID)"
```

`requestIdentifier(for:)` calls these, so there is one source of truth for each ID format.

### 1.3 Provider seam: list delivered notifications

`NotificationCenterProviding` gets one new method:

```swift
/// Notifications currently in Notification Center for this app.
func deliveredNotifications() async -> [DeliveredNotification]
```

New public Sendable value type (in `NotificationCenterProviding.swift`), so `UNNotification` (a non-Sendable class) never crosses an isolation boundary:

```swift
public struct DeliveredNotification: Sendable, Equatable {
    public let identifier: String
    public let date: Date                    // UNNotification.date (delivery time)
    public let userInfo: [String: String]    // only String keys/values kept
    public init(identifier: String, date: Date, userInfo: [String: String])
}
```

`LiveNotificationCenter`: `await UNUserNotificationCenter.current().deliveredNotifications()`, mapped to `DeliveredNotification` in the same function (keep entries of `request.content.userInfo` where key and value are both `String`).

`PreviewNotificationCenter` (`Sources/AppCore/PreviewAppCore.swift`): returns `[]`.

### 1.4 `NotificationService` new API

```swift
/// A delivered "offer to record" notification, parsed. Other kinds are not reported.
public enum DeliveredOfferNotification: Equatable, Sendable {
    case meetingStarting(eventKey: String, meetingStart: Date)
    case adHocDetected(bundleID: String)
}

/// C1: removes one calendar notification (pending + delivered).
public func cancelMeetingStarting(eventKey: String) async

/// C2: removes every delivered/pending calendar notification.
public func cancelAllMeetingStarting() async

/// D1: removes one app's "Meeting detected" notification and drops it from
/// `presentedAdHocIDs`.
public func cancelAdHocDetected(bundleID: String) async

/// L1: parsed list of delivered offer notifications.
public func deliveredOfferNotifications() async -> [DeliveredOfferNotification]
```

Behavior:

- All `cancel…` methods run regardless of authorization (same rule as `cancelCountdown`) and call both `removePendingRequests` and `removeDeliveredNotifications` with the same ID list. Each logs one `info` line with the IDs.
- `cancelAllMeetingStarting()`: calls `provider.deliveredNotifications()`, keeps entries with `userInfo[kind] == KindValue.meetingStarting`, and removes their identifiers. If the list is empty, it makes no remove calls. It uses the delivered list (not an in-memory set) so it also removes notifications from a previous process that L1 kept alive. Pending requests are not a concern: all requests use `trigger: nil`.
- `deliveredOfferNotifications()`: parses each `DeliveredNotification` by `userInfo[kind]`:
  - `meeting-starting` + `eventKey` present → `.meetingStarting(eventKey:, meetingStart:)`, where `meetingStart = Double(userInfo[eventStart]).map(Date.init(timeIntervalSince1970:)) ?? notification.date`. (The fallback covers notifications posted by older builds; those are posted at the event start, so the delivery date is a good estimate.)
  - `ad-hoc` + `bundleID` present → `.adHocDetected(bundleID:)`.
  - Anything else (countdown, missing keys, unknown kind) → skipped.
- The existing `cancelAdHocDetected()` (remove all tracked) is unchanged.

## 2. `AppCore` changes (`Sources/AppCore/AppCore.swift`)

### 2.1 New state and constant

```swift
/// How long a calendar notification stays after the meeting starts (C1).
nonisolated static let calendarNotificationLifetime: TimeInterval = 300 // 5 minutes

/// Removal timers for posted calendar notifications, keyed by event key.
/// Separate from `calendarTimerTasks` so `scheduleCalendarTimers()` (which
/// runs on every calendar refresh) never cancels them (C1).
private var calendarNotificationExpiryTasks: [String: Task<Void, Never>] = [:]
```

### 2.2 Removal timer

```swift
private func scheduleCalendarNotificationExpiry(eventKey: String, at expiry: Date) {
    calendarNotificationExpiryTasks[eventKey]?.cancel()
    let delay = expiry.timeIntervalSinceNow
    let sched = scheduler
    calendarNotificationExpiryTasks[eventKey] = Task { [weak self] in
        if delay > 0 {
            do { try await sched.sleep(for: .seconds(delay)) } catch { return }
        }
        guard let self, !Task.isCancelled else { return }
        calendarNotificationExpiryTasks[eventKey] = nil
        await notifications.cancelMeetingStarting(eventKey: eventKey)
    }
}

private func cancelAllCalendarNotificationExpiryTasks() {
    for (_, task) in calendarNotificationExpiryTasks { task.cancel() }
    calendarNotificationExpiryTasks.removeAll()
}
```

**L2 (sleep/wake):** `LiveAppScheduler` sleeps on `ContinuousClock`, which keeps counting while the Mac is asleep. A deadline that passes during sleep fires at wake. No added code. (The existing calendar-start timers already depend on this.)

### 2.3 C1 — post, then schedule removal

`handleCalendarTimerFired(event:)`:

1. Existing checks (mode, recording suppression) stay.
2. **New:** `guard Self.shouldPostCalendarNotification(eventStart: event.start, now: Date()) else { log; return }`, where

   ```swift
   /// False once the notification would already be expired (now >= start + lifetime).
   nonisolated static func shouldPostCalendarNotification(eventStart: Date, now: Date) -> Bool
   ```

   Then `let expiry = event.start.addingTimeInterval(Self.calendarNotificationLifetime)`. (This occurs when the Mac sleeps through the start and `start + 5 min`, and the timer fires at wake. Without this check, we post a notification that is already expired.)
3. Present `.meetingStarting(eventKey:, title:, joinURL:, start: event.start)`.
4. `scheduleCalendarNotificationExpiry(eventKey: event.id, at: expiry)`.

`scheduleCalendarTimers()` is **not** changed and does not touch `calendarNotificationExpiryTasks`.

### 2.4 C2 — recording start

In `startRecording(eventKey:title:)`, after the existing `await notifications.cancelAdHocDetected()`:

```swift
cancelAllCalendarNotificationExpiryTasks()
await notifications.cancelAllMeetingStarting()
```

This is inside the one-recording-at-a-time guard, so it runs once per real start. Every start path already goes through `startRecording`.

### 2.5 D1 — call ended

`handleDetectionStopped(app:)` becomes `async`; `consumeDetectorEvents` awaits it. Add, before the existing `detectedPending` check, with no run-state condition:

```swift
await notifications.cancelAdHocDetected(bundleID: app.bundleID)
```

The existing `runState` / `activeDetectedBundleID` reset logic stays unchanged.

### 2.6 L1 — launch cleanup

New method, called from `startBackgroundServices()` **before** `detector.start()` (so a new "Meeting detected" notification cannot be posted and then removed by the sweep) and before `scheduleCalendarTimers()`:

```swift
private func cleanUpStaleNotificationsOnLaunch() async {
    let delivered = await notifications.deliveredOfferNotifications()
    let plan = Self.launchNotificationCleanupPlan(delivered, now: Date())
    for bundleID in plan.adHocBundleIDsToRemove {
        await notifications.cancelAdHocDetected(bundleID: bundleID)
    }
    for eventKey in plan.meetingEventKeysToRemove {
        await notifications.cancelMeetingStarting(eventKey: eventKey)
    }
    for item in plan.meetingExpiriesToSchedule {
        scheduleCalendarNotificationExpiry(eventKey: item.eventKey, at: item.expiry)
    }
}
```

The decision is a pure, `nonisolated static` function for direct unit tests:

```swift
struct ScheduledExpiry: Equatable { let eventKey: String; let expiry: Date }

struct LaunchNotificationCleanupPlan: Equatable {
    var adHocBundleIDsToRemove: [String] = []
    var meetingEventKeysToRemove: [String] = []
    var meetingExpiriesToSchedule: [ScheduledExpiry] = []
}

nonisolated static func launchNotificationCleanupPlan(
    _ delivered: [DeliveredOfferNotification], now: Date
) -> LaunchNotificationCleanupPlan
```

Rules:
- `.adHocDetected(bundleID)` → always in `adHocBundleIDsToRemove`.
- `.meetingStarting(eventKey, meetingStart)`: `expiry = meetingStart + calendarNotificationLifetime`. If `expiry <= now` → `meetingEventKeysToRemove`; else → `meetingExpiriesToSchedule`.

Mark the plan types `package` (or `internal` + `@testable import`, matching what `AppCoreTests` already does).

`startBackgroundServices()` is near the lint function-body limit; the single added call (`await cleanUpStaleNotificationsOnLaunch()`) keeps it short.

## 3. Error Handling and Logging

- The `UserNotifications` remove calls do not throw. `deliveredNotifications()` does not throw. There is no error path to handle.
- If the system has no delivered notifications, or authorization is denied, all queries return empty lists and the removals are no-ops.
- Logging: `NotificationService` logs each removal (`info`, the IDs) on its existing logger. `AppCore` logs on the `Detection` logger for D1, and on the `AppCore` logger for the launch cleanup summary (counts) and for a skipped late calendar post.

## 4. Testing Strategy

Swift Testing, as in the existing suites. All tests run via `make test`.

### 4.1 Test fakes

Both `FakeNotificationCenter` (`Tests/NotificationsTests/`) and `FakeTestNotificationCenter` (`Tests/BiscottiTestSupport/CoreFixture.swift`) model delivery:

- New backing field `delivered: [DeliveredNotification]`.
- `add(_:)` also appends a `DeliveredNotification` built from the request (`identifier`, `date: Date()`, String-only `userInfo`), replacing any entry with the same identifier (real `UNUserNotificationCenter` semantics).
- `removeDeliveredNotifications(withIdentifiers:)` also removes matching entries from `delivered` (the existing recording arrays stay, so current assertions keep working).
- `deliveredNotifications()` returns `delivered`.
- Tests seed `delivered` directly for launch-cleanup cases.

### 4.2 `NotificationsTests` (new file `NotificationCleanupTests.swift`, plus updated call sites)

1. `cancelMeetingStarting(eventKey:)` removes `biscotti.notif.meeting-start.<key>` from pending and delivered.
2. `cancelAdHocDetected(bundleID:)` removes `biscotti.notif.adhoc.<id>`; a following `cancelAdHocDetected()` does not include that ID again.
3. `cancelAllMeetingStarting()` removes all meeting-start delivered entries and leaves ad-hoc and countdown entries.
4. `cancelAllMeetingStarting()` with no meeting-start entries makes no remove calls.
5. Cancel methods run when authorization is denied.
6. Content: a `.meetingStarting` request has `userInfo[eventStart]` equal to `String(start.timeIntervalSince1970)`.
7. `deliveredOfferNotifications()`: parses meeting-start (with `eventStart`), meeting-start without `eventStart` (falls back to `date`), ad-hoc; skips countdown, unknown kind, missing `eventKey`/`bundleID`.

### 4.3 `AppCoreTests` (new file `NotificationCleanupTests.swift`, using `CoreFixture` + `FakeScheduler`)

Timers compute delays from `Date()` while `FakeScheduler` controls only the sleep, as the existing calendar-timer tests do. Set event starts relative to `Date()` and advance the scheduler by the delay plus a small margin.

1. **C1:** event starts in 60s → advance 60s → calendar notification posted, not removed → advance 300s → the meeting-start ID is in `removedDeliveredIDs`.
2. **C1 survives refresh:** after the post, change `upcoming` (remove the event) → advance 300s → still removed exactly at expiry (the expiry task was not cancelled by `scheduleCalendarTimers()`).
3. **C1 late fire (pure):** `shouldPostCalendarNotification` is true at `start`, true at `start + 299s`, false at `start + 300s` and later.
4. **C2:** post a calendar notification, then `startRecording()` → meeting-start ID removed and no pending expiry sleep remains for it (`FakeScheduler.pendingCount` drops).
5. **D1 pending:** ad-hoc posted for app A → detector `.stopped(A)` → `biscotti.notif.adhoc.A` removed.
6. **D1 other app:** ad-hoc for A and B → `.stopped(A)` → only A removed.
7. **D1 while recording:** `.stopped(A)` while recording still calls remove for A (no-op in practice).
8. **L1 plan (pure):** `launchNotificationCleanupPlan` with ad-hoc, expired meeting-start, fresh meeting-start → correct three lists; boundary `expiry == now` → remove.
9. **L1 integration:** seed fake `delivered` with ad-hoc, expired meeting-start, fresh meeting-start (start 2 min ago), countdown → `onLaunch()` → ad-hoc and expired removed, countdown untouched → advance 180s → fresh one removed.

### 4.4 Manual check (not gated)

No library in the manual-test staleness list is touched (`Notifications`/`AppCore` only; `MeetingDetection` is unchanged), so `manual_test_results.json` does not change. After merge, a human check on hardware is recommended: calendar notification goes away 5 minutes after the start; "Meeting detected" goes away about 8 seconds after leaving the call; stale entries are gone after relaunch.

## 5. Risks

- **`deliveredNotifications()` isolation:** `UNNotification` is not `Sendable`. Map to `DeliveredNotification` inside `LiveNotificationCenter` before returning, so nothing non-Sendable leaves the call.
- **Delivered list freshness:** `cancelAllMeetingStarting()` depends on the system list. If the user already dismissed a notification, it is not in the list, and that is correct.
- **Sleep/wake on `ContinuousClock`:** expected to fire promptly at wake (the calendar-start timers rely on the same behavior). Covered by the recommended manual check, not by an automated test.

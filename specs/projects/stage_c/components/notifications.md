---
status: complete
---

# Component: Notifications

## Purpose and Scope

The `Notifications` module owns **user-facing macOS notifications and their action buttons**. It
registers notification categories, builds content for each notification kind, delivers/updates/cancels
notifications through `UNUserNotificationCenter`, and publishes a typed `AsyncStream` of user actions
back to `AppCore`.

**In scope:** notification authorization, category/action registration, content construction per kind,
immediate delivery, countdown update/cancel lifecycle, delegate response typing, foreground
presentation policy, and the `NotificationCenterProviding` test seam.

**Out of scope:** deciding *when* meetings start (owned by `MeetingDetection` + `CalendarService`),
performing recordings or the auto-stop timer (owned by `AppCore`), and the `UNUserNotificationCenter`
delegate implementation itself (glue in the app target that forwards into this module). This module
**presents and reports intent only**; `AppCore` performs the action.

---

## Public Interface

The public API is **fixed** by architecture.md section 8. Reproduced here with full signatures, plus the
concrete identifier scheme and delegate-response mapping that the architecture intentionally deferred
to this doc.

### Domain types

```swift
/// The three notification kinds the app can present.
public enum NotificationKind: Sendable, Equatable {
    case meetingStarting(eventKey: String, title: String, joinURL: URL?)
    case adHocDetected(bundleID: String, appName: String)
    case stopCountdown(meetingID: UUID, secondsRemaining: Int)
}

/// Typed user intent extracted from a raw delegate response.
public enum NotificationAction: Sendable, Equatable {
    case openAndRecord(eventKey: String?)   // from meetingStarting or adHocDetected
    case join(URL)                          // from meetingStarting (join link)
    case keepRecording(meetingID: UUID)     // from stopCountdown
}
```

### Category and action identifiers

Four `UNNotificationCategory` registrations (two variants for meeting-start), each with its own
action set:

| Category ID | Actions | Action IDs |
|---|---|---|
| `biscotti.meeting-starting` | "Open & Record" (foreground) | `biscotti.action.open-and-record` |
| `biscotti.meeting-starting-with-join` | "Open & Record" (foreground) + "Join" (foreground) | `biscotti.action.open-and-record`, `biscotti.action.join` |
| `biscotti.ad-hoc-detected` | "Record" (background) | `biscotti.action.record` |
| `biscotti.stop-countdown` | "Keep Recording" (background) | `biscotti.action.keep-recording` |

Two category IDs for meeting-start because `UNNotificationCategory` action sets are fixed at
registration time. `present(_:)` picks the category based on whether `joinURL` is non-nil. This
avoids showing a dead "Join" button when there is no conference link.

**Notes on action options:**
- "Open & Record" and "Join" use `UNNotificationAction(options: [.foreground])` — tapping them
  brings the app window to the front (Open & Record shows the recording screen; Join opens the
  conference URL in the browser).
- "Record" (ad-hoc) uses no `.foreground` option — recording starts headlessly in the background;
  the user sees the menu-bar indicator change. This matches the "never interrupt flow" principle for
  ad-hoc detection.
- "Keep Recording" uses no `.foreground` option — cancelling auto-stop is a background operation.

### Notification request identifiers (for replace/cancel)

| Kind | Request identifier | Purpose |
|---|---|---|
| `meetingStarting` | `"biscotti.notif.meeting-start.\(eventKey)"` | One per event; prevents duplicate banners for the same event. |
| `adHocDetected` | `"biscotti.notif.adhoc.\(bundleID)"` | One per app; re-posting replaces an un-actioned banner. |
| `stopCountdown` | `"biscotti.notif.countdown.\(meetingID)"` | Stable across countdown updates — re-adding with the same ID replaces the delivered notification in-place per `UNNotificationRequest.init(identifier:content:trigger:)` semantics. |

### `userInfo` keys

Every notification request carries structured `userInfo` so the delegate response can be typed:

```swift
enum UserInfoKey {
    static let kind = "biscotti.kind"            // "meeting-starting" | "ad-hoc" | "countdown"
    static let eventKey = "biscotti.eventKey"     // String (meetingStarting, adHocDetected optionally nil)
    static let bundleID = "biscotti.bundleID"     // String (adHocDetected)
    static let joinURL = "biscotti.joinURL"       // String (meetingStarting, if present)
    static let meetingID = "biscotti.meetingID"   // String (UUID, stopCountdown)
}
```

### Seam protocol

```swift
/// Test seam over UNUserNotificationCenter.
///
/// The live implementation wraps `UNUserNotificationCenter.current()`.
/// Tests inject a fake that records calls and can script authorization results.
public protocol NotificationCenterProviding: Sendable {
    /// Request alert+sound authorization. Returns true if granted.
    func requestAuthorization() async throws -> Bool

    /// Register notification categories (called once at init).
    func setCategories(_ categories: Set<UNNotificationCategory>)

    /// Add (or replace) a notification request.
    func add(_ request: UNNotificationRequest) async throws

    /// Remove pending + delivered notifications matching identifiers.
    func removePendingRequests(withIdentifiers ids: [String])
    func removeDeliveredNotifications(withIdentifiers ids: [String])

    /// Current authorization status.
    func authorizationStatus() async -> UNAuthorizationStatus
}
```

### `NotificationService`

```swift
/// Manages notification lifecycle: authorization, presentation, countdown updates,
/// and the typed action stream consumed by AppCore.
@MainActor
public final class NotificationService {
    /// Creates the service, registers categories, and prepares the action stream.
    ///
    /// - Parameter provider: The notification center seam (defaults to the live
    ///   `UNUserNotificationCenter` wrapper).
    public init(provider: any NotificationCenterProviding = LiveNotificationCenter())

    /// Requests notification authorization (alert + sound).
    /// Returns `true` if granted. Safe to call multiple times (no-ops after first grant/deny).
    public func requestAuthorization() async -> Bool

    /// Posts a notification for the given kind.
    /// No-op if authorization was denied (avoids silent `add` failures; logs a warning).
    public func present(_ kind: NotificationKind) async

    /// Refreshes the stop-countdown notification with a new seconds-remaining value.
    /// Re-adds a request with the same stable identifier so the existing banner is replaced in-place.
    public func updateCountdown(meetingID: UUID, secondsRemaining: Int) async

    /// Removes the stop-countdown notification (user tapped Keep Recording, or recording stopped).
    public func cancelCountdown(meetingID: UUID) async

    /// An unbounded AsyncStream of typed actions from user interactions with notifications.
    /// Single-consumer (AppCore). The stream is fed by the app-target delegate calling
    /// `handleResponse(_:)`.
    public func actions() -> AsyncStream<NotificationAction>

    // MARK: - Delegate bridge (called by app-target glue)

    /// Types a raw `UNNotificationResponse` into a `NotificationAction` and pushes it onto
    /// the `actions()` stream. Called by the app-target's `UNUserNotificationCenterDelegate`.
    ///
    /// Returns `true` if the response was recognized and enqueued; `false` for dismiss/unknown
    /// (AppCore ignores those).
    @discardableResult
    public func handleResponse(_ response: UNNotificationResponse) -> Bool

    /// Called by the app-target delegate for `willPresent`. Returns the presentation options
    /// to use when a notification arrives while the app is in the foreground.
    public func foregroundPresentationOptions(
        for notification: UNNotification
    ) -> UNNotificationPresentationOptions
}
```

### Delegate response → `NotificationAction` mapping

| Category | Action ID | Extracted from `userInfo` | `NotificationAction` |
|---|---|---|---|
| `biscotti.meeting-starting` | `biscotti.action.open-and-record` | `eventKey` | `.openAndRecord(eventKey: key)` |
| `biscotti.meeting-starting-with-join` | `biscotti.action.open-and-record` | `eventKey` | `.openAndRecord(eventKey: key)` |
| `biscotti.meeting-starting-with-join` | `biscotti.action.join` | `joinURL` | `.join(url)` |
| `biscotti.ad-hoc-detected` | `biscotti.action.record` | `eventKey` (nil) | `.openAndRecord(eventKey: nil)` |
| `biscotti.stop-countdown` | `biscotti.action.keep-recording` | `meetingID` | `.keepRecording(meetingID: uuid)` |
| any | `UNNotificationDefaultActionIdentifier` (banner tap) | varies | `.openAndRecord(eventKey:)` for start/ad-hoc; ignored for countdown |
| any | `UNNotificationDismissActionIdentifier` | — | not enqueued (no action) |

**Assumption:** tapping the notification banner itself (default action, no explicit button) for
meeting-start and ad-hoc notifications maps to `.openAndRecord` — the most natural intent when the
user taps "Meeting detected in Zoom" is to open the app and start recording. For countdown, a bare
banner tap is ignored (the countdown continues; only the explicit "Keep Recording" button cancels it).

---

## Internal Design Approach

### Category registration

On `init`, the service calls `provider.setCategories(...)` with all four categories (the two
meeting-start variants, ad-hoc, and stop-countdown). Registration is idempotent — calling it on every
launch is standard practice and costs nothing.

```swift
// Sketch (not production code)
private func registerCategories() {
    let openAndRecord = UNNotificationAction(
        identifier: ActionID.openAndRecord,
        title: "Open & Record",
        options: [.foreground]
    )
    let join = UNNotificationAction(
        identifier: ActionID.join,
        title: "Join",
        options: [.foreground]
    )
    let record = UNNotificationAction(
        identifier: ActionID.record,
        title: "Record",
        options: []
    )
    let keepRecording = UNNotificationAction(
        identifier: ActionID.keepRecording,
        title: "Keep Recording",
        options: []
    )

    let meetingStart = UNNotificationCategory(
        identifier: CategoryID.meetingStarting,
        actions: [openAndRecord],
        intentIdentifiers: []
    )
    let meetingStartWithJoin = UNNotificationCategory(
        identifier: CategoryID.meetingStartingWithJoin,
        actions: [openAndRecord, join],
        intentIdentifiers: []
    )
    let adHoc = UNNotificationCategory(
        identifier: CategoryID.adHocDetected,
        actions: [record],
        intentIdentifiers: [],
        options: [.customDismissAction]  // so dismiss routes through the delegate
    )
    let countdown = UNNotificationCategory(
        identifier: CategoryID.stopCountdown,
        actions: [keepRecording],
        intentIdentifiers: [],
        options: [.customDismissAction]
    )

    provider.setCategories([meetingStart, meetingStartWithJoin, adHoc, countdown])
}
```

The `.customDismissAction` option on ad-hoc and countdown categories causes
`UNNotificationDismissActionIdentifier` to route through `didReceive`. This lets the module
distinguish an explicit dismiss from an un-actioned notification (useful for future analytics; the
current implementation simply drops dismiss actions).

### Content construction

`present(_:)` builds a `UNMutableNotificationContent` per kind:

**Meeting starting:**
```swift
content.title = title                          // e.g. "Standup is starting"
content.body = ""                              // title is sufficient; body empty or "Tap to record"
content.sound = .default
content.categoryIdentifier = joinURL != nil
    ? CategoryID.meetingStartingWithJoin
    : CategoryID.meetingStarting
content.userInfo = [
    UserInfoKey.kind: "meeting-starting",
    UserInfoKey.eventKey: eventKey,
    // UserInfoKey.joinURL: joinURL?.absoluteString  (if present)
]
```

**Ad-hoc detected:**
```swift
content.title = "Meeting detected in \(appName)"
content.body = "Tap Record to start capturing."
content.sound = .default
content.categoryIdentifier = CategoryID.adHocDetected
content.userInfo = [
    UserInfoKey.kind: "ad-hoc",
    UserInfoKey.bundleID: bundleID,
]
```

**Stop countdown:**
```swift
content.title = "Audio stopped \u{2014} stopping in \(secondsRemaining)s"
content.body = "Tap Keep Recording to continue."
content.sound = nil                            // silent update (no repeated ding)
content.categoryIdentifier = CategoryID.stopCountdown
content.userInfo = [
    UserInfoKey.kind: "countdown",
    UserInfoKey.meetingID: meetingID.uuidString,
]
```

All requests use `trigger: nil` (immediate delivery). The request identifier is the stable per-kind
key from the table above.

### Immediate delivery vs. scheduled (meeting-start timing)

**Decision: `NotificationService` always delivers immediately; `AppCore` owns the timing.**

The architecture (section 11) shows `AppCore` consuming `CalendarService.upcoming` and scheduling its own
timer to fire at each event's start time. When that timer fires, `AppCore` calls
`notifications.present(.meetingStarting(...))`. This is simpler and more correct than having
`NotificationService` schedule `UNCalendarNotificationTrigger`s itself, because:

1. `AppCore` already de-duplicates (suppresses the calendar notification if a recording is already
   active or the same event was already prompted).
2. Calendar events change (`EKEventStoreChanged`); rescheduling `UNCalendarNotificationTrigger`s in
   sync with the calendar would duplicate the refresh logic that `CalendarService` already owns.
3. The module stays stateless regarding scheduling — it just presents what it is told to present.

**Contract gap / risk flagged:** this means **AppCore must run a timer (or `Task.sleep`) for each
upcoming meeting-like event** and must reschedule those timers when the upcoming set changes. If the
app is quit (not just window-closed), those timers die and no notification fires. This is acceptable
because: (a) the app defaults to launch-at-login and runs in the background; (b) a
`UNCalendarNotificationTrigger` fallback could be added later if needed without changing
`NotificationService`'s API.

### Stop-countdown lifecycle

The countdown is driven by `AppCore`, not this module. The sequence:

1. `MeetingDetector` emits `.stopped(app:)` during an active detection-driven recording.
2. `AppCore` calls `notifications.present(.stopCountdown(meetingID: id, secondsRemaining: 15))`.
3. `AppCore` ticks a 1-second `Task.sleep` loop, calling
   `notifications.updateCountdown(meetingID: id, secondsRemaining: n)` each second.
   - `updateCountdown` builds a new `UNMutableNotificationContent` with the updated body and re-adds
     a `UNNotificationRequest` with the **same stable identifier**
     (`"biscotti.notif.countdown.\(meetingID)"`). Per Apple docs, re-adding with the same identifier
     replaces the delivered notification in Notification Center (the banner updates in-place).
   - `sound` is `nil` on updates to avoid repeated chimes.
4. If the user taps "Keep Recording" → the delegate fires → `handleResponse` enqueues
   `.keepRecording(meetingID:)` → `AppCore` receives it on the `actions()` stream → cancels the
   timer → calls `notifications.cancelCountdown(meetingID:)`.
5. If the timer reaches 0 without a "Keep Recording" action → `AppCore` stops the recording → calls
   `notifications.cancelCountdown(meetingID:)`.
6. `cancelCountdown` calls both `removePendingRequests(withIdentifiers:)` and
   `removeDeliveredNotifications(withIdentifiers:)` to clean up.

### Foreground presentation policy

When the app is in the foreground and a notification arrives, `willPresent` is called. The service's
`foregroundPresentationOptions(for:)` returns `[.banner, .sound]` for meeting-start and ad-hoc
notifications (the user should still see the banner even if the window is open — they may be looking
at a past meeting, not the sidebar). For countdown updates it returns `[.list]` (update Notification
Center silently, no repeated banner pop while the user is in the app — they can see the recording
indicator).

### The `actions()` AsyncStream

Implemented with `AsyncStream.makeStream(of: NotificationAction.self)` (unbuffered continuation).
`handleResponse(_:)` calls `continuation.yield(action)`. The stream is consumed by a single `Task`
in `AppCore.onLaunch()` that `for await`s actions and dispatches them.

**Buffering:** the continuation is unbuffered (`.bufferingPolicy(.unbounded)` — default). In
practice at most one action is in flight at a time (the user taps one notification). If somehow two
arrive before `AppCore` consumes, they queue in the stream's buffer.

**Lifecycle:** the continuation is stored as a property on `NotificationService`. The stream is
created lazily on first `actions()` call and lives for the process lifetime (no cancellation —
`AppCore` never stops listening).

### Authorization and denied state

- `requestAuthorization()` calls `provider.requestAuthorization()` with options `[.alert, .sound]`.
  Returns `true` if granted. The result is also reported to `Permissions` via the
  `NotificationAuthorizing` seam (architecture section 9).
- `present(_:)` and `updateCountdown(...)` check cached authorization status before calling
  `provider.add(...)`. If denied, they log a warning via `os.Logger` and return without error — the
  caller (`AppCore`) does not need to handle this; the notification simply does not appear. The
  recording/detection flows are unaffected.
- `cancelCountdown(meetingID:)` always executes (removing requests is valid even if auth is denied).

### `LiveNotificationCenter` (production implementation)

A thin `Sendable` wrapper around `UNUserNotificationCenter.current()`. Lives in the `Notifications`
module (not the app target). Conforms to `NotificationCenterProviding` by forwarding each method to
the real center. No interesting logic — it exists purely to make the seam injectable.

---

## Dependencies

### This module depends on
- **UserNotifications** (system framework) — `UNUserNotificationCenter`, `UNNotificationCategory`,
  `UNNotificationAction`, `UNMutableNotificationContent`, `UNNotificationRequest`,
  `UNNotificationResponse`, `UNAuthorizationStatus`, `UNNotificationPresentationOptions`.
- **Foundation** — `UUID`, `URL`, `os.Logger`.

No dependency on `DataStore`, `Calendar`, `MeetingDetection`, or any other BiscottiKit module. Content
strings (event title, app name) arrive as parameters on `NotificationKind`; the caller (`AppCore`)
resolves them from its own dependencies.

### What depends on this module
- **`AppCore`** (L2) — constructs `NotificationService`, calls `present`/`updateCountdown`/
  `cancelCountdown`, and consumes `actions()`.
- **App target** (`App/Sources/`) — implements `UNUserNotificationCenterDelegate` and forwards
  `didReceive` responses to `NotificationService.handleResponse(_:)` and `willPresent` calls to
  `foregroundPresentationOptions(for:)`. The delegate is set in `BiscottiApp` on launch
  (`UNUserNotificationCenter.current().delegate = self`). This is the only app-target glue for
  notifications.
- **`Permissions`** (L0) — `NotificationService` reports authorization results into `Permissions`
  via the `NotificationAuthorizing` seam protocol (defined in `Permissions`; the live implementation
  that imports `UserNotifications` lives here in `Notifications` or is injected by the app). The
  direction: `NotificationService` → `Permissions.noteNotifications(_:)` (analogous to
  `Recording` → `Permissions.noteSystemAudio(_:)`).

---

## Test Plan

All tests use `swift-testing` and run against a `FakeNotificationCenter` conforming to
`NotificationCenterProviding`. The fake records every `setCategories`, `add`, `removePending`,
`removeDelivered` call with arguments, and can be configured with a scripted authorization result.
No real `UNUserNotificationCenter` is involved — tests are headless and CI-safe.

### Category / action registration

- **`registersCategoriesOnInit`** — creating a `NotificationService` calls `setCategories` on the
  provider exactly once. The registered set contains all four category IDs
  (`meeting-starting`, `meeting-starting-with-join`, `ad-hoc-detected`, `stop-countdown`). Each
  category's `actions` array has the correct action IDs and option flags (`.foreground` where
  expected).

### Content construction

- **`meetingStartingContentUsesEventTitle`** — `present(.meetingStarting(eventKey: "k", title: "Standup", joinURL: nil))`
  adds a request whose content has `title == "Standup"`, `categoryIdentifier == "biscotti.meeting-starting"`,
  `sound == .default`, and `userInfo` containing the event key and kind.

- **`meetingStartingWithJoinUsesJoinCategory`** — same as above but with a non-nil `joinURL`. Asserts
  `categoryIdentifier == "biscotti.meeting-starting-with-join"` and `userInfo` includes the URL string.

- **`adHocContentNamesApp`** — `present(.adHocDetected(bundleID: "us.zoom.xos", appName: "Zoom"))`
  adds a request whose `title` contains "Zoom", `categoryIdentifier == "biscotti.ad-hoc-detected"`,
  and `userInfo` contains the bundle ID.

- **`stopCountdownContentShowsSeconds`** — `present(.stopCountdown(meetingID: id, secondsRemaining: 15))`
  adds a request whose title contains "15" and `categoryIdentifier == "biscotti.stop-countdown"`.

### Request identifiers (de-dup / replace)

- **`meetingStartRequestIDContainsEventKey`** — the request identifier for a meeting-start
  notification includes the event key, so two calls with different keys produce different IDs.

- **`countdownUpdateReusesIdentifier`** — calling `updateCountdown(meetingID: id, secondsRemaining: 10)`
  after an initial `present(.stopCountdown(...))` adds a request with the **same** identifier. The
  fake records both `add` calls; assert the identifiers match and the second content's title
  reflects the updated seconds.

- **`adHocRequestIDContainsBundleID`** — two ad-hoc notifications for different bundle IDs produce
  different request identifiers; two for the same bundle ID reuse the same identifier.

### Countdown cancel

- **`cancelCountdownRemovesPendingAndDelivered`** — `cancelCountdown(meetingID: id)` calls both
  `removePendingRequests(withIdentifiers:)` and `removeDeliveredNotifications(withIdentifiers:)`
  with the stable countdown identifier for that meeting ID.

### Delegate response mapping

- **`delegateResponseMapsToOpenAndRecord`** — construct a fake `UNNotificationResponse` (or use a
  test-double struct) with category `biscotti.meeting-starting`, action ID
  `biscotti.action.open-and-record`, and `userInfo` containing an event key. Call
  `handleResponse(_:)` and assert the `actions()` stream yields
  `.openAndRecord(eventKey: "the-key")`.

- **`joinActionMapsToJoinURL`** — response with category `biscotti.meeting-starting-with-join`,
  action `biscotti.action.join`, and a join URL in `userInfo`. Assert `.join(url)` is yielded.

- **`adHocRecordActionMapsToOpenAndRecordNilKey`** — response with category
  `biscotti.ad-hoc-detected`, action `biscotti.action.record`. Assert
  `.openAndRecord(eventKey: nil)`.

- **`keepRecordingActionMapsToKeepRecording`** — response with category `biscotti.stop-countdown`,
  action `biscotti.action.keep-recording`, and a meeting ID in `userInfo`. Assert
  `.keepRecording(meetingID: uuid)`.

- **`defaultActionOnMeetingStartMapsToOpenAndRecord`** — response with
  `UNNotificationDefaultActionIdentifier` (bare banner tap) on a meeting-start category. Assert
  `.openAndRecord(eventKey: key)`.

- **`dismissActionIsNotEnqueued`** — response with `UNNotificationDismissActionIdentifier`. Assert
  `handleResponse` returns `false` and the `actions()` stream does not yield.

### Authorization

- **`requestAuthorizationReturnsProviderResult`** — fake returns `true`; assert
  `requestAuthorization()` returns `true`. Repeat with `false`.

- **`deniedAuthMakesPresentNoOp`** — configure the fake to report `.denied` authorization status.
  Call `present(.adHocDetected(...))`. Assert `add` was **not** called on the provider.

- **`cancelCountdownWorksWhenDenied`** — even with denied auth, `cancelCountdown` still calls
  `removePendingRequests` / `removeDeliveredNotifications` (cleanup is always valid).

### Foreground presentation

- **`foregroundMeetingStartShowsBannerAndSound`** — `foregroundPresentationOptions(for:)` returns
  `[.banner, .sound]` for a notification with a meeting-start category.

- **`foregroundCountdownShowsListOnly`** — returns `[.list]` for a countdown notification (silent
  update, no repeated banner).

### Testing `UNNotificationResponse` (seam note)

`UNNotificationResponse` is a system class with no public initializer. The delegate-mapping tests
need a way to simulate responses. Two options:

1. **Extract the mapping logic into a pure function** that takes the category identifier, action
   identifier, and `userInfo` dictionary — not the full `UNNotificationResponse`. The pure function
   is trivially testable. `handleResponse` calls this function internally, and the app-target
   delegate calls `handleResponse` with the real response object. This is the preferred approach.
2. Subclass `UNNotificationResponse` in tests (fragile, not recommended).

The tests above target the **pure mapping function** (e.g., `mapResponse(categoryID:actionID:userInfo:) -> NotificationAction?`).
`handleResponse` is a thin wrapper that extracts those three values from the real
`UNNotificationResponse` and delegates to the pure function + yields to the continuation.

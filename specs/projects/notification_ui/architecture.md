---
status: complete
---

# Architecture: Notification UI

Single-document architecture. Every change is to **existing** components — no new modules. The work spans five layers: `DataStore` (persistence), `Notifications` (content/actions/alert-style), `AppCore` (cached settings + gating), `SettingsUI` (the controls), and the App-target `AppDelegate` (URL-open / window glue).

> **Design note — the monitor always runs.** The audio-activity monitor observes only per-process audio I/O *flags* (`kAudioProcessPropertyIsRunningInput/Output`), never audio content, so there is no privacy reason to stop it. It runs continuously as today; the three settings are pure presentation/behavior gates. No detector start/stop, no lifecycle reconcile.

Concrete anchors are cited as `file:line` from the pre-change tree.

---

## 1. Data model

### 1.1 New enum — `CalendarNotificationMode`

New file `Packages/BiscottiKit/Sources/DataStore/Models/CalendarNotificationMode.swift`, mirroring `MenuBarLeadTime`'s shape:

```swift
public enum CalendarNotificationMode: String, CaseIterable, Sendable, Identifiable {
    case allMeetings
    case videoConferencing
    case never

    public var id: String { rawValue }

    public var displayText: String {
        switch self {
        case .allMeetings: "All Meetings"
        case .videoConferencing: "Meetings with Video Conferencing"
        case .never: "Never"
        }
    }

    /// Stored-string → enum, defaulting to `.allMeetings` for unknown values.
    public init(raw: String) { self = Self(rawValue: raw) ?? .allMeetings }
}
```

Lives in `DataStore` because both `SettingsUI` and `AppCore` already depend on `DataStore` (same home as `MenuBarLeadTime`).

### 1.2 `AppSettings` (`@Model`) — three new stored properties

In `DataStore/Models/AppSettings.swift` (after `onboardingComplete`, before the calendar-IDs block), add primitives with defaults (store the **raw String** for the mode — SwiftData + String is the safe pattern used throughout this model):

```swift
public var monitorForMeetings: Bool = true
public var stopRecordingAutomatically: Bool = true
public var calendarNotificationModeRaw: String = "allMeetings"   // CalendarNotificationMode.allMeetings.rawValue
```

Add matching parameters (with the same defaults) to `init(...)` (`AppSettings.swift:61`).

### 1.3 `AppSettingsData` (DTO) — typed fields

In `DataStore+ReadModels.swift:122`, add to the Sendable DTO. The DTO exposes the **typed enum** (cleaner than the menu-bar `Int` pattern, and the enum lives in `DataStore`):

```swift
public var monitorForMeetings: Bool
public var stopRecordingAutomatically: Bool
public var calendarNotificationMode: CalendarNotificationMode
```

Defaults in the DTO `init`: `true`, `true`, `.allMeetings`.

### 1.4 `DataStore.settings()` / `updateSettings(_:)`

In `DataStore+ReadModels.swift:390` and `:411`, extend the model↔DTO mapping:

- **Read** (`settings()`): `monitorForMeetings: existing.monitorForMeetings`, `stopRecordingAutomatically: existing.stopRecordingAutomatically`, `calendarNotificationMode: CalendarNotificationMode(raw: existing.calendarNotificationModeRaw)`.
- **Write** (`updateSettings`): build the DTO the same way, then write back `model.monitorForMeetings = dto.monitorForMeetings`, `model.stopRecordingAutomatically = dto.stopRecordingAutomatically`, `model.calendarNotificationModeRaw = dto.calendarNotificationMode.rawValue`.

No migration needed — SwiftData adds the new columns with their declared defaults for existing rows.

---

## 2. Notifications module

### 2.1 Alert-style readback (for the "Notifications Stay Visible" row)

**Provider seam** (`NotificationCenterProviding.swift:7`) — add:

```swift
/// Current on-screen alert style (banner vs. alert vs. none).
func alertStyle() async -> UNAlertStyle
```

**Live impl** (`LiveNotificationCenter.swift`):

```swift
public func alertStyle() async -> UNAlertStyle {
    await UNUserNotificationCenter.current().notificationSettings().alertStyle
}
```

**New Sendable enum** (new file `Notifications/NotificationAlertStyle.swift`):

```swift
public enum NotificationAlertStyle: Sendable, Equatable { case none, banner, alert }
```

**NotificationService** (`NotificationService.swift`) — public mapper:

```swift
public func currentAlertStyle() async -> NotificationAlertStyle {
    switch await provider.alertStyle() {
    case .none: .none
    case .banner: .banner
    case .alert: .alert
    @unknown default: .banner
    }
}
```

### 2.2 Time-sensitive interruption level

In `makeRequest(for:)` (`NotificationService.swift:252`), set `content.interruptionLevel = .timeSensitive` for **`.meetingStarting`** (inside `fillMeetingStartContent`, `:283`) and **`.adHocDetected`** (`:262`). Leave `.stopCountdown` at the default (out of scope). The `com.apple.developer.usernotifications.time-sensitive` entitlement is **not** added here (deferred to Project 9); without it the level degrades to `.active` — harmless.

### 2.3 Meeting-detected copy (`.adHocDetected` case, `:262`)

```swift
content.title = "Meeting detected"
content.subtitle = "App: \(appName)"
content.body = ""
content.interruptionLevel = .timeSensitive
content.sound = .default
content.categoryIdentifier = CategoryID.adHocDetected
content.userInfo = [UserInfoKey.kind: KindValue.adHoc, UserInfoKey.bundleID: bundleID]
```

### 2.4 Calendar-notification actions — "Record & Join" / "Record"

**Identifiers** (`NotificationIdentifiers.swift:16`): remove `openAndRecord` and `join`; add `recordAndJoin`; keep `record`, `keepRecording`:

```swift
enum ActionID {
    static let recordAndJoin = "biscotti.action.record-and-join"
    static let record = "biscotti.action.record"
    static let keepRecording = "biscotti.action.keep-recording"
}
```

**Category registration** (`registerCategories()`, `:182`):

| Category | Action(s) | Title(s) | Options |
|---|---|---|---|
| `meetingStarting` (no link) | `record` | "Record" | `[]` |
| `meetingStartingWithJoin` (link) | `recordAndJoin` | "Record & Join" | `[]` |
| `adHocDetected` | `record` | "Record" | `[]` (category keeps `.customDismissAction`) |
| `stopCountdown` | `keepRecording` | "Keep Recording" | unchanged |

> Both calendar actions use options `[]` — we do **not** `.foreground` Biscotti. The browser/meeting app is foregrounded by the link-open instead (handled in the delegate, §5).

**`NotificationAction`** (`NotificationAction.swift:4`): remove the `.join(URL)` case. Remaining: `.openAndRecord(eventKey:)`, `.keepRecording(meetingID:)`.

**`ResponseMapper`** (`ResponseMapper.swift`):
- `mapMeetingStartResponse` (`:38`): for both meeting categories, any of `recordAndJoin` / `record` / `UNNotificationDefaultActionIdentifier` → `.openAndRecord(eventKey:)`; delete the `.join` branch.
- `mapAdHocResponse` (`:62`): unchanged (`record` / default → `.openAndRecord(eventKey: nil)`).

### 2.5 Dismiss lingering meeting-detected on record start

Track presented ad-hoc identifiers and expose a cancel:

```swift
private var presentedAdHocIDs: Set<String> = []

// in present(_:), after a successful add for an .adHocDetected kind:
//   presentedAdHocIDs.insert(request.identifier)

public func cancelAdHocDetected() async {
    guard !presentedAdHocIDs.isEmpty else { return }
    let ids = Array(presentedAdHocIDs)
    provider.removePendingRequests(withIdentifiers: ids)
    provider.removeDeliveredNotifications(withIdentifiers: ids)
    presentedAdHocIDs.removeAll()
}
```

(Identifier is `biscotti.notif.adhoc.{bundleID}` — `NotificationIdentifiers.swift:53`.)

---

## 3. AppCore — cached settings & gating

### 3.1 New `Notification.Name`s (`AppCore.swift:14`)

`monitorForMeetingsDidChange`, `calendarNotificationModeDidChange`, `stopRecordingAutomaticallyDidChange` — same `net.scosman.biscotti.*` convention as the existing three.

### 3.2 Cached settings + accessor

New stored properties on `AppCore` (defaults match the model):

```swift
public private(set) var monitorForMeetings = true
public private(set) var calendarNotificationMode: CalendarNotificationMode = .allMeetings
public private(set) var stopRecordingAutomatically = true
```

Loaded in `onLaunch()` from the snapshot already read at `AppCore.swift:309-314` (add a `loadNotificationSettings(from:)` analogous to `loadMenuBarLeadTime(from:)`), and refreshed by observers (§3.3).

Banner-style helper for the settings row:

```swift
public func notificationsUseBannerStyle() async -> Bool {
    await notifications.currentAlertStyle() == .banner
}
```

### 3.3 Live observers

Add `startNotificationSettingsObservers()` (called next to `startMenuBarLeadTimeObserver()` at `:318`), spawning one task per name (same `for await … NotificationCenter.default.notifications(named:)` pattern as `:720`). On each event, re-read `store.settings()` and update the cached field. Additionally, `calendarNotificationModeDidChange` → `scheduleCalendarTimers()` so already-scheduled timers match the new mode. The monitor / auto-stop observers only refresh their cached flags — the gates (§3.5, §3.6) read those flags live when detection events fire, so nothing else is required.

### 3.4 The monitor keeps running — no lifecycle management

`startBackgroundServices()` (`:357-363`) is **unchanged**: `detector.start()` + the single `consumeDetectorEvents()` task run for the process lifetime, exactly as today. Because the monitor reads only per-process audio I/O flags (not audio content), it stays always-on; this also means auto-stop works regardless of the Monitor toggle. No reconcile, no stop/restart, no truth table.

### 3.5 Gate the detection notification (`handleDetectionStarted`, `:885`)

Add at the very top: `guard monitorForMeetings else { return }`. When Monitor is off, an incoming `.started` event is dropped here — no notification, no `runState = .detectedPending`. The detector keeps emitting; we simply ignore detection starts for presentation. (Reads the live cached `monitorForMeetings`; the existing `.recording` suppression below it is retained.)

### 3.6 Auto-stop gating (`handleAllMicUsersStopped`, `:941`)

```swift
private func handleAllMicUsersStopped() {
    guard stopRecordingAutomatically else { return }
    guard case let .recording(meetingID) = runState else { return }
    beginAutoStopCountdown(meetingID: meetingID)
}
```

### 3.7 Calendar-timer gating (mode-aware)

**Pure filter** (testable):

```swift
static func eventsToNotify(
    _ upcoming: [CalendarEvent], mode: CalendarNotificationMode
) -> [CalendarEvent] {
    switch mode {
    case .never: []
    case .allMeetings: upcoming.filter(\.isMeetingLike)
    case .videoConferencing: upcoming.filter { $0.conferenceURL != nil }
    }
}
```

- `scheduleCalendarTimers()` (`:1044`): iterate `Self.eventsToNotify(upcoming, mode: calendarNotificationMode)` instead of `upcoming where event.isMeetingLike`. (`.never` ⇒ all existing timers cancelled and none scheduled.)
- `handleCalendarTimerFired(event:)` (`:1069`): add a re-check guard against the current mode (`mode == .never` ⇒ bail; `mode == .videoConferencing && event.conferenceURL == nil` ⇒ bail), covering the race between a mode change and reschedule.
- Calendar permission already gates the data (`upcoming` is empty without auth), so no extra permission guard is needed in AppCore; the disabled-UI is cosmetic (§4).

### 3.8 Cancel ad-hoc on record start (`startRecording`, `:384`)

After the `runState` guard (`:386-388`): `await notifications.cancelAdHocDetected()`. Combined with the existing `.recording` suppression in `handleDetectionStarted`, this satisfies functional-spec **B2** (no meeting-detected banner survives into an active recording).

### 3.9 Notification-action consumer (`consumeNotificationActions`, `:1015`)

Remove the `.join` case (the enum case is gone). `.openAndRecord` and `.keepRecording` unchanged.

---

## 4. SettingsUI

### 4.1 `SettingsViewModel` (`SettingsViewModel.swift`)

New observable state:

```swift
public private(set) var monitorForMeetings = true
public private(set) var calendarNotificationMode: CalendarNotificationMode = .allMeetings
public private(set) var stopRecordingAutomatically = true
public private(set) var showStayVisibleRow = false   // true only when alert style == .banner

public var calendarNotificationsDisabled: Bool { calendarState != .authorized }
```

Setters (each mirrors `setMenuBarLeadTime`: optimistic set → persist → post Notification.Name → revert on throw):
- `setMonitorForMeetings(_:)` → posts `.monitorForMeetingsDidChange`
- `setCalendarNotificationMode(_:)` → posts `.calendarNotificationModeDidChange`
- `setStopRecordingAutomatically(_:)` → posts `.stopRecordingAutomaticallyDidChange`

`load()` (`:307`): additionally read the three fields from `settings`, and `showStayVisibleRow = await core.notificationsUseBannerStyle()`.

```swift
public func refreshAlertStyle() async { showStayVisibleRow = await core.notificationsUseBannerStyle() }

public func openNotificationSettings() {
    NSWorkspace.shared.open(core.permissions.settingsURL(for: .notifications))
}
```

(`settingsURL(for: .notifications)` already returns `x-apple.systempreferences:com.apple.Notifications-Settings.extension` — `Permissions.swift:142`.) No new module import needed: `core.notificationsUseBannerStyle()` returns `Bool`, so `SettingsUI` does **not** depend on `Notifications`.

### 4.2 `SettingsView` (`SettingsView.swift`)

Insert `notificationsSection` between `generalSection` and `permissionsSection` (`:22-25`).

- **Row 1** (Monitor for Meetings): the `VStack { Toggle; Text(subtitle) }` pattern from "Exit app on window close" (`:55-63`), with a `Binding<Bool>` wrapper (`Task { await viewModel.setX(newValue) }`).
- **Row 2** (Calendar dropdown): `VStack(alignment:.leading)` with a `Picker("Calendar Event Notifications", selection: calendarNotificationModeBinding)` over `CalendarNotificationMode.allCases` (`Text(mode.displayText).tag(mode)`); the subtitle below. When `viewModel.calendarNotificationsDisabled`:
  - `.disabled(true)` on the picker and the display binding's getter returns `.never` (stored value untouched — the setter is inert while disabled).
  - A warning badge between picker and subtitle: a small capsule, `exclamationmark.triangle.fill` + "Requires Calendar Access", `Tokens.warningChipFill` background + `Tokens.warningChipText` foreground (a private `requiresCalendarAccessBadge` view; reuse `StatChip` styling if it fits).
- **Row 3** (Stay-visible, conditional on `viewModel.showStayVisibleRow`): `HStack { VStack { Text("Notifications Stay Visible"); Text("Make notifications stay open until clicked or dismissed.").metadata }; Spacer(); Button("Enable") { showAlertsHelp = true } .bordered .controlSize(.small) }`.
- **Stop Recording Automatically** lives in the **General** section (not Notifications) — same `VStack { Toggle; Text(subtitle) }` pattern, placed after the global-shortcut toggle.
- `@State private var showAlertsHelp = false` → `.sheet(isPresented:)` presents `AlertsHelpSheet` (the §4.3 dialog).
- Re-check style on return from System Settings:
  `.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await viewModel.refreshAlertStyle() } }`.

### 4.3 Alerts help sheet (new private view in `SettingsView.swift` or a sibling file)

A small modal: title "Keep Notifications On Screen", the explanatory paragraph + the 3 numbered steps (per `ui_design.md`), and buttons **Cancel** (dismiss) / **Open Settings** (`viewModel.openNotificationSettings()` then dismiss). Design-system styling; primary button `.sage`.

---

## 5. App target — `AppDelegate` (`BiscottiApp.swift:571`)

The delegate keeps owning AppKit side effects (URL-open, window foreground); AppCore stays AppKit-free. Rewrite the post-`handleResponseValues` block (`:597-613`) — using the same hardcoded ID strings already in use there:

```swift
// Open the call link for Record & Join (button or body-tap on a link-bearing calendar notif).
if categoryID == "biscotti.meeting-starting-with-join",
   actionID == "biscotti.action.record-and-join"
     || actionID == UNNotificationDefaultActionIdentifier,
   let s = userInfo["biscotti.joinURL"] as? String, let url = URL(string: s) {
    NSWorkspace.shared.open(url)
}

// Foreground Biscotti only for ad-hoc Record and Keep-Recording — never for calendar notifs.
let isAdHocRecord = categoryID == "biscotti.ad-hoc-detected"
    && (actionID == "biscotti.action.record" || actionID == UNNotificationDefaultActionIdentifier)
let isKeepRecording = actionID == "biscotti.action.keep-recording"
    || (actionID == UNNotificationDefaultActionIdentifier && categoryID == "biscotti.stop-countdown")
if isAdHocRecord || isKeepRecording { showMainWindow() }
```

Removed: the old `biscotti.action.join` URL block and the `open-and-record` window-foreground. The stale code comment about `.join` (AppCore `:1021-1030`, delegate `:584-588`) is deleted with the case.

`willPresent` (`:617`) and `foregroundPresentationOptions` (`NotificationService.swift:171`) are unchanged (`[.banner, .sound]`).

---

## 6. Error handling

Consistent with existing patterns: settings setters revert optimistic UI on a thrown store write; `cancelAdHocDetected()` / detector `start`/`stop` are fire-and-forget (no throw); `currentAlertStyle()` defaults to `.banner` on `@unknown`; URL opens are best-effort (`NSWorkspace.open`). No new fatal paths. Logging via the existing `os.Logger` categories (`Notifications`, AppCore's `detectionLogger`).

---

## 7. Testing strategy

Swift Testing, fakes via existing seams. New/updated unit tests (all runnable under `make test`):

**DataStore**
- `AppSettings`/DTO round-trip for the three new fields, including defaults on a fresh store and `CalendarNotificationMode(raw:)` fallback for an unknown stored string.
- `CalendarNotificationMode`: `displayText`, `rawValue` stability, `allCases` order.

**Notifications**
- `ResponseMapper`: `recordAndJoin` / `record` / default on both meeting categories → `.openAndRecord(eventKey)`; ad-hoc unchanged; dismiss → nil; (no `.join`).
- `NotificationService` (fake provider capturing requests/categories):
  - `present(.meetingStarting…)` and `present(.adHocDetected…)` set `interruptionLevel == .timeSensitive`; ad-hoc sets `title == "Meeting detected"`, `subtitle == "App: …"`.
  - Registered categories carry the new action ids/titles ("Record & Join", "Record").
  - `cancelAdHocDetected()` removes exactly the presented ad-hoc identifiers (pending + delivered) and clears tracking.
  - `currentAlertStyle()` maps each `UNAlertStyle` (fake scripts the value).

**AppCore**
- `eventsToNotify(_:mode:)` — `.never` ⇒ empty; `.videoConferencing` ⇒ only `conferenceURL != nil`; `.allMeetings` ⇒ `isMeetingLike`.
- Detection-notification gating: `handleDetectionStarted` no-ops (no present, no `detectedPending`) when `monitorForMeetings == false`; presents when true (drive via the existing AppCore test harness / fake detector stream + a notifications spy).
- Auto-stop gating: `handleAllMicUsersStopped` no-ops when `stopRecordingAutomatically == false`; fires when true + recording.
- `startRecording` calls `notifications.cancelAdHocDetected()` (spy on the notifications seam).
- Live-toggle wiring: posting each `Notification.Name` updates the cached field; `calendarNotificationModeDidChange` reschedules timers (assert via the pure helper + a scheduler spy).

**SettingsUI**
- `SettingsViewModel` setters persist + post the right `Notification.Name` and revert on a failing store seam.
- `load()` populates the three fields; `showStayVisibleRow` reflects a scripted banner/alert/none style; `calendarNotificationsDisabled` reflects `calendarState`.

**App target / manual.** The `AppDelegate` URL-open / window-foreground branch is thin AppKit glue (its decision logic is covered by `ResponseMapper` tests). Notification *presentation* (dwell, time-sensitive prominence, the alert-style row self-hiding, deep link) is not unit-testable → cover in a manual hardware smoke test.

**Manual-test gate.** This project does **not** modify `Packages/AudioCapture` or `Packages/Transcription`, so the `ac_*`/`tx_*` manual-test results and the `manual-tests-check` gate are **untouched** (no `not-run` marking needed). Detection/notification behavior should still be smoke-tested on hardware before sign-off, but it is outside that gate.

---

## 8. File-change summary

| File | Change |
|---|---|
| `DataStore/Models/CalendarNotificationMode.swift` | **new** enum |
| `DataStore/Models/AppSettings.swift` | +3 stored props + init params |
| `DataStore/DataStore+ReadModels.swift` | DTO +3 fields; read/write mapping |
| `Notifications/NotificationAlertStyle.swift` | **new** enum |
| `Notifications/NotificationCenterProviding.swift` | + `alertStyle()` |
| `Notifications/LiveNotificationCenter.swift` | impl `alertStyle()` |
| `Notifications/NotificationService.swift` | `currentAlertStyle()`; `.timeSensitive`; ad-hoc copy; categories; `cancelAdHocDetected()` + tracking |
| `Notifications/NotificationIdentifiers.swift` | `ActionID`: −openAndRecord/−join, +recordAndJoin |
| `Notifications/NotificationAction.swift` | remove `.join` |
| `Notifications/ResponseMapper.swift` | meeting-start mapping; drop `.join` |
| `AppCore/AppCore.swift` | 3 Notification.Names; cached settings + loader; observers (calendar-mode reschedules); `notificationsUseBannerStyle()`; `handleDetectionStarted` monitor guard; auto-stop guard; `eventsToNotify` + timer gating; `cancelAdHocDetected` on start; drop `.join` consumer case |
| `SettingsUI/SettingsViewModel.swift` | new props/setters; `load()`; `refreshAlertStyle()`; `openNotificationSettings()` |
| `SettingsUI/SettingsView.swift` | `notificationsSection`; badge; stay-visible row; help sheet; active-refresh |
| `App/Sources/BiscottiApp.swift` | delegate URL-open / window-foreground rewrite |
| `…/Tests/**` | tests per §7 |

---

## 9. Out of scope (reaffirmed)

Time-sensitive **entitlement** (Project 9); stop-countdown copy/behavior; notification-permission request flow; capture/recording internals; onboarding changes; localization.

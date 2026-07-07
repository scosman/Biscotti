---
status: complete
---

# Architecture: Stage C — V1 Feature Layering

Technical design, deep enough to code from. The **static topology** (component homes, boundaries,
dependency edges) is fixed by the repo [`architecture.md`](../../architecture.md). This doc designs
the **concrete app-level APIs** for the Stage C slices, the cross-component contracts (the seams
between Calendar / MeetingDetection / Notifications / AppCore / UI), the data-model deltas, and the
app-target/background/menu-bar wiring. Foundation-engine APIs (`AudioCapture`, `Transcription`) are
fixed and only **consumed**.

It builds directly on the Stage B architecture (`../stage_b_mvp/architecture.md`) — same threading
rule, same DTO discipline, same seam-for-tests approach. **Read that first**; this doc states only the
deltas and the new contracts.

> **Two-phase doc.** This file pins the topology, threading, navigation, data model, shared seams, and
> the cross-component contracts. Per-component internals live in `components/`:
> [`calendar.md`](components/calendar.md), [`meeting_detection.md`](components/meeting_detection.md),
> [`notifications.md`](components/notifications.md), [`app_core.md`](components/app_core.md),
> [`ui_modules.md`](components/ui_modules.md). Vocabulary, DataStore, Permissions, and
> TranscriptionService deltas are small enough to live here.

> **Manual-test staleness:** Stage C **does not edit** `Packages/AudioCapture` or
> `Packages/Transcription` source (it only consumes them). The `ac_*`/`tx_*` staleness rule is **not**
> triggered. (If any change to those packages becomes necessary, mark the affected manual tests
> `not-run` per the repo rule.)

---

## 1. Module map (new + extended targets in `BiscottiKit`)

All new app-level code is **modules (targets) in `Packages/BiscottiKit`** (app target stays thin). New
targets, plus the existing targets Stage C extends:

| Target | New/Extended | Layer | Depends on (internal) | External |
|---|---|---|---|---|
| `Calendar` | **new** | L1 | `DataStore` | EventKit |
| `MeetingDetection` | **new** | L1 | `AudioCapture`(pkg) | — |
| `Notifications` | **new** | L1 | — | UserNotifications |
| `Vocabulary` | **new** | L1 | `DataStore` | — |
| `HomeUI` | **new** | L3a | `AppCore`, `DataStore`, `Calendar`, `DesignSystem` | SwiftUI |
| `SearchUI` | **new** | L3a | `AppCore`, `DataStore`, `DesignSystem` | SwiftUI |
| `SettingsUI` | **new** | L3a | `AppCore`, `Calendar`, `Vocabulary`, `Permissions`, `DesignSystem` | SwiftUI |
| `OnboardingUI` | **new** | L3a | `AppCore`, `Permissions`, `Calendar`, `TranscriptionService`, `DesignSystem` | SwiftUI |
| `MenuBarUI` | **new** | L3a | `AppCore`, `DataStore`, `DesignSystem` | SwiftUI |
| `Permissions` | extended | L0 | — | AVFoundation, EventKit, UserNotifications, AppKit |
| `DataStore` | extended | L0 | `Transcription` | SwiftData |
| `TranscriptionService` | extended | L1 | `DataStore`, `Vocabulary` | `Transcription`(pkg) |
| `AppCore` | extended | L2 | + `Calendar`, `MeetingDetection`, `Notifications`, `Vocabulary` | — |
| `MeetingDetailUI` | extended | L3a | + `Calendar` | SwiftUI/AVKit |
| `MeetingListUI` | extended | L3a | + `Calendar` | SwiftUI |
| `AppShellUI` | extended | L3b | + `HomeUI`,`SearchUI`,`SettingsUI`,`OnboardingUI` | SwiftUI |

New BiscottiKit **library products** exposed to the app target: `MenuBarUI` (the app target needs it
for `MenuBarExtra`), plus `OnboardingUI`/`SettingsUI` arrive transitively through `AppShellUI`. The
app target also gains a direct dep on `Calendar`/`Notifications` only if it must reference their types
in glue (it shouldn't — it talks to `AppCore`).

**`RemoteConfig` is intentionally NOT a module in Stage C** (decision C1). Its job is served by a
small `MeetingCatalog` seam (§7) backed by bundled constants.

### Dependency sanity
No cycles. UI(L3) → AppCore(L2) → services(L1) → foundation(L0). `Calendar`/`MeetingDetection`/
`Notifications`/`Vocabulary` are siblings of the Stage B `Recording`/`TranscriptionService` at L1 and
depend only downward.

---

## 2. Threading model (unchanged rule)

Same as Stage B:
- **Heavy work on background actors** — `AudioCapture.AudioActivityMonitor` (actor, exists),
  `DataStore` (actor). `EKEventStore` work runs off the main thread inside the `Calendar` seam
  (`events(matching:)` is synchronous/blocking).
- **Services + view models are `@MainActor @Observable`** that `await` actors and pump `AsyncStream`s
  into observable state.
- **No live `@Model` crosses to UI.** `DataStore` and `Calendar` return **`Sendable` DTOs**. Calendar
  maps `EKEvent` → DTO promptly (and never hands `EKEvent` outward — they retain the store).

---

## 3. Navigation / Route model (extended)

`Route` grows; `AppShellUI` routes the detail pane; first launch shows onboarding.

```swift
public enum Route: Sendable, Equatable {
    case home                  // replaces Stage B `.empty`
    case recording
    case meeting(UUID)         // a recorded meeting (DataStore)
    case event(String)         // an un-recorded upcoming calendar event, keyed by composite key (read-only preview)
    case search
    case settings
    case onboarding            // first-run takeover
}
```

- `AppCore` owns `route` (as in Stage B) plus `searchReturnRoute: Route?` so Search "Back" restores
  the prior route.
- **Onboarding gate**: `AppSettings.onboardingComplete` (new) decides whether the app opens to
  `.onboarding` or `.home`. Re-runnable from Settings (sets route `.onboarding`).
- **Upcoming preview**: selecting an Upcoming row routes to `.event(key)`, rendered read-only with a
  **Record** action that starts recording and associates that event (per C4). See `ui_modules.md`.

---

## 4. Data model & `DataStore` deltas

The SwiftData schema **already contains** every entity Stage C needs (`Meeting`, `TranscriptRecord`
versions, `CalendarSnapshot`, `Person`, `AudioFileRef`, `AppSettings`). Stage C **wires the unwired
parts** and adds **queries + DTOs**. Goal: keep the schema as-is where possible to avoid a migration;
only `AppSettings` gains a field (`onboardingComplete`) and `enabledCalendarIDs` storage.

### 4.1 Settings persistence (wire `AppSettings`)
`AppSettings` exists but no store method reads/writes it. Add:

```swift
public struct AppSettingsData: Sendable, Equatable {
    public var customVocabulary: [String]
    public var launchAtLogin: Bool
    public var onboardingComplete: Bool          // NEW field on the model
    public var enabledCalendarIDs: Set<String>?  // nil = all calendars enabled (NEW field, stored as [String]?)
}

extension DataStore {
    public func settings() throws -> AppSettingsData          // creates the singleton row on first read
    public func updateSettings(_ mutate: @Sendable (inout AppSettingsData) -> Void) throws
}
```

> **Migration note**: adding `onboardingComplete: Bool = false` and `enabledCalendarIDs: [String]? =
> nil` to `AppSettings` is a lightweight additive SwiftData migration. Bump to `DataStoreSchemaV2` with
> a stage in `DataStoreMigrationPlan` (the plan currently has empty stages). Defaulted properties make
> this automatic/lightweight. This is the **only** schema change in Stage C.

### 4.2 Calendar association & snapshot
Already present and reused as-is: `setSnapshot`, `clearSnapshot`, `associate(meetingID:…)`,
`correctAssociation(meetingID:…)`, `setParticipants(_:organizer:for:)`, `findOrCreatePerson`. Stage C
calls these from `AppCore`/`Calendar`. **Correction is atomic**: `correctAssociation` clears the old
snapshot+participants and sets the new in one store call (extend the existing method to also reset
participants/organizer from the new snapshot).

### 4.3 Search (transcript text)
Stage B `search(_:)` covers title + participant names. Extend to transcript text with weighting:

```swift
public struct SearchHit: Sendable, Identifiable, Equatable {
    public let id: UUID                 // meeting id
    public let title: String
    public let date: Date
    public let score: Int               // title matches weighted higher than transcript
    public let matchedFields: [SearchField]   // .title, .people, .transcript — for the "why matched" hint
}
public enum SearchField: Sendable { case title, people, transcript }

extension DataStore {
    public func searchHits(_ query: String, limit: Int) throws -> [SearchHit]
}
```

Implementation: split query into terms; case-insensitive `localizedStandardContains` across title,
participant names, and `TranscriptSegmentRecord.text` (preferred transcript only); score = Σ
(term-field weight); sort desc. No FTS (fine < 1000 docs). Keep `search(_:)` for existing callers or
migrate them.

### 4.4 New read DTOs (calendar context, versions)
```swift
public struct CalendarContextData: Sendable, Equatable {     // from CalendarSnapshot
    public let title: String?
    public let conferencePlatform: String?
    public let conferenceURL: URL?
    public let calendarTitle: String?
    public let calendarColorHex: String?
    public let location: String?
    public let isStale: Bool
    public let organizer: PersonData?
    public let attendees: [PersonData]
}
public struct PersonData: Sendable, Identifiable, Equatable { public let id: UUID; public let name: String; public let email: String?; public let isCurrentUser: Bool }

public struct TranscriptVersionData: Sendable, Identifiable, Equatable {
    public let id: UUID; public let createdAt: Date; public let methodId: String; public let isPreferred: Bool
}

extension DataStore {
    public func calendarContext(meetingID: UUID) throws -> CalendarContextData?
    public func transcriptVersions(meetingID: UUID) throws -> [TranscriptVersionData]
    public func transcript(id: UUID) throws -> TranscriptData?     // a specific version (for the picker)
    public func audioFileRefs(meetingID: UUID) throws -> (mic: URL?, system: URL?, present: Bool)
}
```

`MeetingDetailData` (Stage B) gains optional `calendar: CalendarContextData?` and `notes: String` (for
editing) and `versions: [TranscriptVersionData]`. Notes write-back: `setNotes(_:for:)`.

### 4.5 Effective-date sort
Resolve the Stage B TODO: `recentMeetings`/`meetingSummaries` sort by effective date (`startDate ??
createdAt`). Past-list grouping (Today/Yesterday/This Week/Earlier) is computed in the
`MeetingListUI` view model from `MeetingSummary.date`, not in the store.

---

## 5. `Calendar` module (new) — contract

Full internals in [`components/calendar.md`](components/calendar.md). The **contract AppCore/UI
consume**:

```swift
public enum CalendarAuthStatus: Sendable, Equatable { case notDetermined, authorized, denied, restricted } // .writeOnly→.denied

public struct CalendarInfo: Sendable, Identifiable, Equatable {  // for the include/exclude UI
    public let id: String          // calendarIdentifier
    public let title: String
    public let colorHex: String
    public let sourceTitle: String // grouping
}

public struct CalendarEvent: Sendable, Identifiable, Equatable {  // a live, un-recorded event (DTO; no EKEvent)
    public let id: String          // composite key string
    public let title: String
    public let start: Date
    public let end: Date
    public let conferencePlatform: String?
    public let conferenceURL: URL?
    public let attendeeCount: Int
    public let calendarTitle: String
    public let calendarColorHex: String
    public var isMeetingLike: Bool // conferenceURL != nil || attendeeCount >= 2
}

public protocol EventStoreProviding: Sendable { /* seam over EKEventStore: auth, calendars, events(in:) */ }

@MainActor @Observable
public final class CalendarService {
    public private(set) var auth: CalendarAuthStatus
    public private(set) var upcoming: [CalendarEvent]     // meeting-like, next window; refreshed on change/launch
    public init(store: DataStore, catalog: any MeetingCatalog, provider: any EventStoreProviding = LiveEventStore())

    public func requestAccess() async -> CalendarAuthStatus
    public func calendars() async -> [CalendarInfo]                       // for settings/onboarding
    public func refreshUpcoming(window: DateInterval) async               // re-fetch meeting-like events
    public func event(forKey key: String) -> CalendarEvent?               // for the .event(key) preview
    public func bestMatch(at date: Date) -> CalendarEvent?                // C4 association at record start
    public func snapshot(forKey key: String) async -> CalendarSnapshotInput?  // map event → store input
    public func startObserving()                                          // .EKEventStoreChanged → refreshUpcoming
}
```

- `CalendarService` owns the live event-store seam, the enabled-calendar filter (reads
  `DataStore.settings().enabledCalendarIDs`), conference detection (`ConferenceDetector` from
  EventKitLab, hardcoded patterns via `catalog`), and snapshot mapping (`snapshotFromEvent`).
- It produces **DTOs only**. The store-side write (creating the `CalendarSnapshot`) is done by
  `AppCore` calling `DataStore.setSnapshot(_:for:)` with a `Sendable` `CalendarSnapshotInput` the
  service builds. (Snapshot model lives in DataStore; service maps to a DataStore-defined `Sendable`
  input struct — keeps EventKit out of DataStore.)

---

## 6. `MeetingDetection` module (new) — contract

Full internals in [`components/meeting_detection.md`](components/meeting_detection.md). Contract:

```swift
public enum DetectionEvent: Sendable, Equatable {
    case started(app: DetectedApp)
    case stopped(app: DetectedApp)
}
public struct DetectedApp: Sendable, Equatable { public let bundleID: String; public let displayName: String }
// Convention: DetectedApp.bundleID is the RESOLVED user-facing app (helper bundle IDs are mapped to
// their parent via MeetingCatalog.parentBundleID before emission), so AppCore/Notifications never see
// raw helper IDs like com.apple.WebKit.GPU.

public protocol ActivitySource: Sendable {                 // seam over AudioCapture.AudioActivityMonitor
    func activityStream() -> AsyncStream<[AudioProcess]>
}

@MainActor @Observable
public final class MeetingDetector {
    public init(catalog: any MeetingCatalog, source: any ActivitySource = LiveActivitySource())
    public func events() -> AsyncStream<DetectionEvent>     // de-bounced started/stopped per meeting app
    public func start()                                     // begin observing
    public func stop()
}
```

- Consumes `AudioProcess` snapshots (which already carry `isMeetingApp`/`displayName` + the running
  flags). Applies the validated "in a call" heuristic (input AND output running) and the
  helper-process→app mapping via `catalog`. Emits de-bounced `.started`/`.stopped`. No notification or
  recording logic.

---

## 7. `MeetingCatalog` seam (hardcoded config, replaces RemoteConfig — C1)

A single seam both `Calendar` and `MeetingDetection` consume, so a future RemoteConfig can replace the
backing store with no caller changes:

```swift
public protocol MeetingCatalog: Sendable {
    func displayName(forBundleID id: String) -> String?       // meeting-app name (or its helper)
    func isMeetingApp(bundleID: String) -> Bool
    func parentBundleID(forHelperBundleID id: String) -> String?   // helper→user-facing app (WebKit.GPU→browser, avconferenced→FaceTime, Slack helper→Slack); nil if id is already user-facing
    func conferenceMatch(inURL: URL?, location: String?, notes: String?) -> (platform: String, url: URL)?
}

public struct BundledMeetingCatalog: MeetingCatalog {         // V1: compiled-in lists
    public init()
    // backed by the existing AudioCapture seed watchlist + ConferenceDetector regexes (cached)
}
```

Lives in its own tiny `MeetingCatalog` target (L0, no deps) so both L1 services depend on it without
`MeetingDetection`→`Calendar` coupling. **Conference-link detection (`conferenceMatch`) lives here in
`MeetingCatalog` (L0)** — not in `Calendar` or a separate `RemoteConfig` — because both `Calendar`
and `MeetingDetection` need it. The regex patterns for Zoom, Meet, Teams, etc. and the bundle-ID
watchlist are compiled into `BundledMeetingCatalog`; `CalendarService` calls `catalog.conferenceMatch`
when mapping events to DTOs.

---

## 8. `Notifications` module (new) — contract

Full internals in [`components/notifications.md`](components/notifications.md). Contract:

```swift
public enum NotificationKind: Sendable, Equatable {
    case meetingStarting(eventKey: String, title: String, joinURL: URL?)
    case adHocDetected(bundleID: String, appName: String)
    case stopCountdown(meetingID: UUID, secondsRemaining: Int)
}
public enum NotificationAction: Sendable, Equatable {
    case openAndRecord(eventKey: String?)   // from meetingStarting / adHocDetected
    case join(URL)
    case keepRecording(meetingID: UUID)
}

public protocol NotificationCenterProviding: Sendable { /* seam over UNUserNotificationCenter */ }

@MainActor
public final class NotificationService {
    public init(provider: any NotificationCenterProviding = LiveNotificationCenter())
    public func requestAuthorization() async -> Bool
    public func present(_ kind: NotificationKind) async
    public func updateCountdown(meetingID: UUID, secondsRemaining: Int) async  // re-post/refresh
    public func cancelCountdown(meetingID: UUID) async
    public func actions() -> AsyncStream<NotificationAction>   // delivered to AppCore
}
```

- Registers `UNNotificationCategory`s with the actions per kind. The app-target's
  `UNUserNotificationCenterDelegate` forwards taps into `NotificationService.actions()` (the glue is in
  the app target; the routing/typing is in the module).

---

## 9. `Permissions` deltas (calendar + notifications)

Extend the Stage B `Permissions` (`@MainActor @Observable`) — keep its internal-dep-free posture by
seaming the system frameworks:

```swift
public enum PermissionKind: Sendable { case microphone, systemAudio, calendar, notifications }   // +2

public protocol CalendarAuthorizing: Sendable { func status() -> PermissionState; func request() async -> PermissionState }
public protocol NotificationAuthorizing: Sendable { func status() async -> PermissionState; func request() async -> Bool }

@MainActor @Observable public final class Permissions {
    public private(set) var microphone: PermissionState
    public private(set) var systemAudio: PermissionState
    public private(set) var calendar: PermissionState        // NEW
    public private(set) var notifications: PermissionState    // NEW
    // + requestCalendar(), requestNotifications(), refresh() also reads calendar/notifications
    // settingsURL(for:) adds Privacy_Calendars (calendar). notifications deep-links to its pane.
}
```

`PermissionState` stays `{notDetermined, authorized, denied}`; calendar `.writeOnly`/`.restricted` map
to `.denied` for UI purposes (with recovery guidance). The actual EventKit/UN calls are behind the new
seams; `CalendarService`/`NotificationService` can either own auth or delegate to `Permissions` —
**decision:** `Permissions` is the single source of truth for *status*; `CalendarService`/
`NotificationService` perform requests and report results into `Permissions` (mirrors Stage B's
system-audio-via-Recording pattern). This keeps `Permissions` free of EventKit/UN imports if the seams
live in the services; to honor "Permissions owns the unified view," the seam *protocols* live in
`Permissions`, and the live implementations (importing EventKit/UN) are injected by the services/app.

---

## 10. `Vocabulary` module (new) + `TranscriptionService` delta

```swift
@MainActor public final class VocabularyService {
    public init(store: DataStore)
    public func appWide() async -> [String]                       // AppSettings.customVocabulary
    public func setAppWide(_ terms: [String]) async               // settings write
    public func effectiveVocabulary(meetingID: UUID) async -> [String]  // app-wide ∪ per-meeting terms
}
```

`effectiveVocabulary` = app-wide terms ∪ per-meeting terms derived from the meeting's
participants/organizer names + company/domain tokens (from the `CalendarSnapshot`). Dedup,
case-insensitive, capped to a sane length.

`TranscriptionService` (Stage B) gains a `VocabularyService` dependency — its init becomes
`init(store:engine:vocabulary:)` (source-breaking; update all callers incl. `AppCore.live`) — and, in
`runEngine`, replaces `customVocabulary: []` with `await vocabulary.effectiveVocabulary(meetingID:)`.
The new `TranscriptRecord.vocabularyUsed` records what was actually used. Re-transcribe recomputes the
effective list (so correcting association → better vocab → better re-transcribe).

It also exposes a **standalone model-readiness** method for the onboarding download step (independent
of a transcription job):

```swift
extension TranscriptionService {
    public func ensureModelsReady(status: (@Sendable (String) -> Void)?) async throws  // download/compile only
    public func modelsReady() async -> Bool
}
```

---

## 11. `AppCore` (extended) — the coordinator

Full internals in [`components/app_core.md`](components/app_core.md). The shape:

```swift
public enum RunState: Sendable, Equatable { case idle, recording(UUID), detectedPending }

@MainActor @Observable public final class AppCore {
    // Stage B: store, permissions, recording, transcription, route, summaries
    public let calendar: CalendarService          // NEW
    public let detector: MeetingDetector          // NEW
    public let notifications: NotificationService  // NEW
    public let vocabulary: VocabularyService       // NEW
    public private(set) var runState: RunState     // NEW (menu bar + UI observe)
    public private(set) var upcoming: [CalendarEvent]  // NEW (mirrors calendar.upcoming, meeting-like)
    public private(set) var searchReturnRoute: Route?  // NEW

    public static func live(storageRoot: URL, transcriberServiceName: String) throws -> AppCore

    public func onLaunch() async        // orphans, settings/onboarding gate, calendar observe+refresh, start detection, wire notification+detection streams, reschedule calendar-start notifications
    public func startRecording(eventKey: String?) async  // C4 association (explicit key, or bestMatch(now)), create+link snapshot, start
    public func stopRecording() async
    public func presentSearch() / dismissSearch()
    public func showHome() / showSettings() / showOnboardingReplay()
    public func selectEvent(_ key: String)               // route = .event(key) (upcoming preview)
    public func requestSystemAudioPermission() async     // onboarding audio step (triggers capture probe via Recording)
    public func recordDetectedEvent(eventKey: String?) async  // from a notification action
    public func completeOnboarding() async
    // background: owns per-event calendar-start timers (reschedule on upcoming change), consumes
    // detector.events() + notifications.actions(), runs the auto-stop countdown — all on the MainActor
    // behind an injected `AppScheduler` clock seam for deterministic tests.
}
```

`AppCore.live` additionally builds: `CalendarService` (live event store), `MeetingDetector` (live
activity source), `NotificationService` (live center), `VocabularyService`, and a `BundledMeetingCatalog`
shared by Calendar + Detector. Detection→notification→record→transcribe and auto-stop are detailed in
`components/app_core.md`.

---

## 12. App target & background wiring (`App/`)

- **MenuBarExtra**: add a `MenuBarExtra` scene rendering `MenuBarUI` (driven by `AppCore`). The app
  now has both a `WindowGroup` and a `MenuBarExtra`.
- **Background / don't-quit-on-close (C7)**: `@NSApplicationDelegateAdaptor` with
  `applicationShouldTerminateAfterLastWindowClosed → false`; activation policy `.regular` (Dock icon).
  The window can reopen from the menu bar / Dock. A recording in progress at Quit is stopped-and-saved
  (delegate `applicationShouldTerminate` → `await core.stopRecording()` if recording, then terminate).
- **Launch at login**: `SMAppService.mainApp` register/unregister, driven by the Settings toggle;
  default-on on first run (set during onboarding completion).
- **Notification handling**: app-target `UNUserNotificationCenterDelegate` forwards `didReceive`
  responses into `NotificationService` (which types them and republishes on `actions()`); foreground
  presentation options allow banners while active.
- **Info.plist additions**: `NSCalendarsFullAccessUsageDescription` (mic/system-audio strings already
  present from Stage B). No new entitlement (calendar/notifications are TCC/UN, non-sandboxed).
- **Onboarding gate**: `BiscottiApp` checks `AppCore` for the onboarding flag and routes to
  `.onboarding` vs `.home`.

---

## 13. Cross-cutting conventions

- **Logging**: each new module uses `os.Logger` with its own subsystem/category (e.g.
  `net.scosman.biscotti` / `Calendar`, `Detection`, `Notifications`, `AppCore`).
- **Error surfacing**: calendar/notification/detection failures never crash; they degrade to
  empty/disabled states with user-visible guidance (banner or settings status). Recording/transcription
  error paths are unchanged from Stage B (typed errors, retriable surfaced).
- **Concurrency**: `@MainActor @Observable` services/VMs; `Sendable` DTOs across actor boundaries;
  EventKit blocking calls off-main inside the seam. No `EKEvent`/`@Model` leaves its actor.
- **One recording at a time**: enforced in `AppCore`; concurrent detections become queued
  notifications, not concurrent recordings.

---

## 14. Testing strategy (gating, hardware-free)

Every new module ships swift-testing unit tests against seams. Highlights:

| Area | Seam | What's tested |
|---|---|---|
| `Calendar` | `EventStoreProviding` (scripted calendars/events) | snapshot mapping, meeting-like filter, conference detection, `bestMatch(at:)`, enabled-calendar filtering, stale-on-delete |
| `MeetingDetection` | `ActivitySource` (synthetic `[AudioProcess]` streams) | in-call heuristic, helper→app mapping, started/stopped de-bounce, no-event for non-watchlist |
| `Notifications` | `NotificationCenterProviding` | category/action registration, content per kind, countdown update/cancel, action typing on `actions()` |
| `Vocabulary` | in-memory `DataStore` | app-wide read/write, merge (participants/company), dedup/cap |
| `AppCore` | all of the above as fakes | detection→notification→record→transcribe flow; auto-stop countdown + cancel; de-dup; association at record start; onboarding gate; run-state transitions; search return route |
| `DataStore` | in-memory container | settings read/write + migration, transcript-text search scoring, calendar-context DTO, version list, notes write, effective-date sort |
| UI VMs | fake `AppCore`/DTOs | home/upcoming/empty states, search ranking display, settings forms, onboarding step flow, menu-bar icon/body states, detail rich states (versions/notes/playback availability/association correction) |
| `Permissions` | `CalendarAuthorizing`/`NotificationAuthorizing` | calendar/notification status state machine, `.writeOnly`→denied mapping |

`build_app` (non-gating) proves the app + `MenuBarExtra` + XPC compile/link.

---

## 15. Decisions log (Stage C specifics)

- **No RemoteConfig module (C1)** → `MeetingCatalog` seam backed by bundled constants; replaceable
  later with no caller changes.
- **`MeetingCatalog` as its own tiny L0 target** → both `Calendar` and `MeetingDetection` depend on it
  without coupling the two L1 services.
- **Calendar/Notifications report status into `Permissions`** (seam protocols in `Permissions`, live
  impls injected) → preserves "Permissions = unified status view" without importing EventKit/UN into it.
- **DTOs only across boundaries** → no `EKEvent`/`@Model` in UI/services; `CalendarService` maps
  promptly (EventKit retain-cycle/threading hazards avoided).
- **Single additive schema migration** (`AppSettings.onboardingComplete` + `enabledCalendarIDs`) →
  `DataStoreSchemaV2`, lightweight via defaults; everything else reuses existing models.
- **Upcoming = live calendar DTOs, not DataStore meetings** → sidebar/menu/home "Upcoming" reads
  `CalendarService.upcoming`; recorded meetings come from `DataStore`. `.event(key)` previews an
  un-recorded event.
- **Never auto-record (C2)**, **auto-attach best match + correction (C4)**, **everything-up-front
  skippable onboarding (C3)**, **in-window settings/onboarding (C5)**, **Dock+window+menubar,
  don't-quit-on-close (C7)**, **skippable model download (C8)** — all per the confirmed core decisions.

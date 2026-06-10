---
status: complete
---

# Component: AppCore (Stage C coordination slice)

## Purpose and Scope

AppCore is the headless background-app engine that wires detection, notification, recording, and
transcription into a single coordinated lifecycle. It is the integrative heart of Stage C: every
user-facing action (manual record, notification-driven record, auto-stop, search, navigation) and
every background flow (meeting detection events, calendar-start timers, notification action dispatch)
routes through it.

**In scope:**

- Wire detection -> notification -> record -> transcribe (the complete background flow).
- Own `RunState` (idle / recording / detectedPending) and expose it for UI + menu bar.
- Schedule per-event calendar-start notification timers; reschedule on upstream changes.
- Own navigation (the `Route` state machine) and `searchReturnRoute` save/restore.
- Remain fully operational with no window open (Tasks on MainActor; app alive via menu bar).
- C4 association at record time: resolve event key or bestMatch, snapshot, persist.
- Auto-stop countdown for detection-driven recordings (15s, driven by a clock seam).
- One-recording-at-a-time enforcement.
- Onboarding gate (route `.onboarding` vs `.home` based on settings).
- Graceful degradation when calendar/notification/detection services are unavailable or denied.

**Not its job:**

- Rendering UI (owned by the UI modules that observe AppCore's published state).
- Low-level capabilities: audio capture (`Recording`), ML transcription (`TranscriptionService`),
  calendar fetching (`CalendarService`), audio monitoring (`MeetingDetector`), banner delivery
  (`NotificationService`). AppCore delegates to each service and coordinates their outputs.
- Apple-lifecycle glue: `NSApplicationDelegate` callbacks, `MenuBarExtra` scene setup,
  `UNUserNotificationCenterDelegate` implementation. These live in the app target and call into
  AppCore methods.

---

## Public Interface

The public surface below is **fixed** by architecture.md section 11. Reproduced here with full
signatures, doc comments, and behavioral contracts.

### Run state

```swift
/// The app-wide operational state observable by UI + menu bar.
public enum RunState: Sendable, Equatable {
    case idle
    case recording(UUID)        // the active meeting's ID
    case detectedPending        // a detection notification is outstanding; user hasn't acted yet
}
```

`detectedPending` is entered when an ad-hoc detection notification is presented and the user has
not yet tapped Record or dismissed it. It is a transient state that allows the menu bar to show
a "meeting detected" indicator without a recording being active.

### Route (extended)

```swift
public enum Route: Sendable, Equatable {
    case home
    case recording
    case meeting(UUID)
    case event(String)          // composite key for an un-recorded upcoming calendar event
    case search
    case settings
    case onboarding
}
```

Replaces the Stage B `Route` (`empty`, `recording`, `meeting(UUID)`) with the full set. `.empty`
becomes `.home`. The app target + `AppShellUI` switch on this to render the appropriate view.

### AppCore class

```swift
@MainActor @Observable
public final class AppCore {
    // MARK: - Child services (publicly readable)

    /// Stage B (unchanged)
    public let store: DataStore
    public let permissions: Permissions
    public let recording: RecordingController
    public let transcription: TranscriptionService

    /// Stage C (new)
    public let calendar: CalendarService
    public let detector: MeetingDetector
    public let notifications: NotificationService
    public let vocabulary: VocabularyService

    // MARK: - Published state

    /// Navigation destination.
    public private(set) var route: Route

    /// Sidebar meeting list (newest first).
    public private(set) var summaries: [MeetingSummary]

    /// The current run state. UI + menu bar observe this.
    public private(set) var runState: RunState

    /// Meeting-like upcoming calendar events, mirrored from CalendarService.
    public private(set) var upcoming: [CalendarEvent]

    /// Saved route for Search "Back" restoration.
    public private(set) var searchReturnRoute: Route?

    // MARK: - Init (test injection)

    /// Creates an AppCore from pre-built services (tests and the live factory).
    public init(
        store: DataStore,
        permissions: Permissions,
        recording: RecordingController,
        transcription: TranscriptionService,
        calendar: CalendarService,
        detector: MeetingDetector,
        notifications: NotificationService,
        vocabulary: VocabularyService,
        scheduler: any AppScheduler = LiveAppScheduler(),
        summaryLimit: Int = 50
    )

    // MARK: - Lifecycle

    /// Called once at app launch.
    public func onLaunch() async

    // MARK: - Recording coordination

    /// Starts a recording, optionally associated with a specific calendar event.
    ///
    /// - Parameter eventKey: Composite key for explicit association (from an
    ///   `.event(key)` preview or a notification action). `nil` = auto-match
    ///   via `calendar.bestMatch(at: now)`.
    public func startRecording(eventKey: String?) async

    /// Stops the current recording, enqueues transcription, and routes to detail.
    public func stopRecording() async

    // MARK: - Navigation

    /// Enters search mode, saving the current route for Back restoration.
    public func presentSearch()

    /// Exits search mode, restoring the saved route.
    public func dismissSearch()

    /// Routes to Home.
    public func showHome()

    /// Routes to Settings.
    public func showSettings()

    /// Routes to Onboarding (re-run from Settings).
    public func showOnboardingReplay()

    /// Records a detected event (from a notification action). Opens the window
    /// and starts recording with the given event key.
    public func recordDetectedEvent(eventKey: String?) async

    /// Marks onboarding complete and transitions to Home.
    public func completeOnboarding() async

    /// Selects a meeting in the sidebar and routes to its detail.
    public func select(_ meetingID: UUID)

    /// Routes to the recording screen (sidebar recording indicator tap).
    public func navigateToRecording()

    /// Reloads the sidebar summaries from the store.
    public func reloadSummaries() async

    // MARK: - Production factory

    /// Builds a fully-wired AppCore for the real app.
    public static func live(
        storageRoot: URL,
        transcriberServiceName: String
    ) throws -> AppCore
}
```

### Extended `live(...)` factory composition

```swift
public static func live(
    storageRoot: URL,
    transcriberServiceName: String
) throws -> AppCore {
    let store = try DataStore(storage: .onDisk(storageRoot))
    let permissions = Permissions()
    let recordingsRoot = storageRoot.appendingPathComponent("Recordings")

    let recording = RecordingController(
        store: store,
        permissions: permissions,
        storageRoot: recordingsRoot,
        makeRecorder: { LiveRecorderAdapter(recorder: AudioRecorder.live()) }
    )

    let transcriber = Transcriber(backend: .hosted(serviceName: transcriberServiceName))
    let engine = LiveTranscriberAdapter(transcriber: transcriber)
    let vocabulary = VocabularyService(store: store)
    let transcription = TranscriptionService(store: store, engine: engine, vocabulary: vocabulary)

    let catalog = BundledMeetingCatalog()
    let calendar = CalendarService(store: store, catalog: catalog)
    let detector = MeetingDetector(catalog: catalog)
    let notifications = NotificationService()

    return AppCore(
        store: store,
        permissions: permissions,
        recording: recording,
        transcription: transcription,
        calendar: calendar,
        detector: detector,
        notifications: notifications,
        vocabulary: vocabulary
    )
}
```

Key: `BundledMeetingCatalog` is shared between `CalendarService` and `MeetingDetector` (per
architecture.md section 7). `VocabularyService` is injected into both `TranscriptionService` (which
uses it to compute effective vocabulary at transcription time) and exposed on `AppCore` (for the
Settings UI to read/write app-wide terms).

---

## Internal Design Approach

### Clock / scheduler seam for testability

The auto-stop countdown and calendar-start timers both require scheduling delayed work. To make
tests deterministic (no wall-clock dependency), AppCore injects a scheduler abstraction:

```swift
/// Abstraction over timed work (sleep, scheduled fire). The live implementation
/// uses Task.sleep with ContinuousClock; tests inject a controllable clock.
public protocol AppScheduler: Sendable {
    /// Sleeps for the given duration. Throws CancellationError if the task is cancelled.
    func sleep(for duration: Duration) async throws

    /// Returns the current instant (for computing relative offsets).
    func now() -> ContinuousClock.Instant
}

public struct LiveAppScheduler: AppScheduler {
    public init() {}
    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
    public func now() -> ContinuousClock.Instant {
        ContinuousClock.now
    }
}
```

Tests inject a `FakeScheduler` that:
- Records sleep calls and their durations.
- Allows explicit advancement of time (`advance(by:)`) to fire pending sleeps.
- Returns a controllable `now()`.

This seam is **internal** to AppCore (not exposed in the public API beyond the init parameter). The
public init accepts `scheduler: any AppScheduler = LiveAppScheduler()`.

### Internal state

```swift
// Private stored properties (sketch)
private let scheduler: any AppScheduler
private let summaryLimit: Int

/// Tracks whether the active recording was started due to detection (vs. manual).
/// Determines whether auto-stop applies.
private var isDetectionDriven: Bool = false

/// The bundle ID of the detected app that triggered the current recording.
/// Used to match .stopped(app:) events to the active recording.
private var activeDetectedBundleID: String? = nil

/// The auto-stop countdown task. Cancelled on .keepRecording or manual stop.
private var countdownTask: Task<Void, Never>? = nil

/// Calendar-start notification timer tasks, keyed by event composite key.
/// Cancelled and rebuilt when `upcoming` changes.
private var calendarTimerTasks: [String: Task<Void, Never>] = [:]

/// Background tasks for consuming detector events and notification actions.
private var detectorConsumerTask: Task<Void, Never>? = nil
private var notificationConsumerTask: Task<Void, Never>? = nil

/// The pending transcription task (retained for test await, same as Stage B).
package var pendingTranscriptionTask: Task<Void, Never>? = nil
```

### `onLaunch()` sequence

Called once by the app target's `.task` modifier after UI is presented.

```
1. await recording.recoverOrphans()
2. Load settings → check onboardingComplete
   - If false: route = .onboarding; return early (skip detection/calendar until onboarding done)
   - If true: route = .home
3. calendar.startObserving()
4. await calendar.refreshUpcoming(window: now...now+24h)
5. Mirror upcoming: self.upcoming = calendar.upcoming
6. detector.start()
7. Start detector consumer task (consumeDetectorEvents)
8. Start notification action consumer task (consumeNotificationActions)
9. Schedule calendar-start timers for all meeting-like events in upcoming
10. await reloadSummaries()
```

After onboarding completes (`completeOnboarding()`), steps 3-10 execute for the first time. This
ensures detection and calendar timers do not fire during onboarding (which requests permissions and
has its own flow).

### Calendar-start timer scheduling

AppCore owns the per-event timers that fire `notifications.present(.meetingStarting(...))` at each
event's start time. This is the design flagged in `notifications.md` (contract gap: Notifications
delivers immediately, so AppCore owns the timing).

**Schedule algorithm:**

```swift
private func scheduleCalendarTimers() {
    // Cancel all existing timers
    for (_, task) in calendarTimerTasks { task.cancel() }
    calendarTimerTasks.removeAll()

    let currentTime = scheduler.now()

    for event in upcoming where event.isMeetingLike {
        let delay = event.start.timeIntervalSince(Date())  // wall-clock offset
        guard delay > 0 else { continue }  // already started; skip

        let key = event.id  // composite key
        calendarTimerTasks[key] = Task { [weak self, scheduler] in
            do {
                try await scheduler.sleep(for: .seconds(delay))
            } catch {
                return  // cancelled
            }
            guard let self, !Task.isCancelled else { return }
            await self.handleCalendarTimerFired(event: event)
        }
    }
}

private func handleCalendarTimerFired(event: CalendarEvent) async {
    // De-dup: suppress if already recording or if this event was already prompted
    guard runState == .idle || runState == .detectedPending else { return }

    await notifications.present(.meetingStarting(
        eventKey: event.id,
        title: event.title,
        joinURL: event.conferenceURL
    ))
}
```

**Reschedule triggers:**

Timers are rescheduled (cancelled and rebuilt) when:
1. `calendar.upcoming` changes (observed via a property-observation `Task` that watches
   `calendar.upcoming` — see "Mirroring calendar.upcoming" below).
2. `completeOnboarding()` calls `scheduleCalendarTimers()` for the first time.

**Survival with no window:** The timer `Task`s are children of `AppCore`, which is `@MainActor` and
lives for the process lifetime. The app stays alive via the `MenuBarExtra` scene even when all
windows are closed (`applicationShouldTerminateAfterLastWindowClosed -> false`). If the app is quit,
timers die -- this is accepted per the Notifications component doc (the app defaults to
launch-at-login; a `UNCalendarNotificationTrigger` fallback can be added later).

### Mirroring `calendar.upcoming` into `AppCore.upcoming`

AppCore publishes its own `upcoming` property (so UI modules depend on AppCore, not Calendar
directly for this data). A background task observes changes:

```swift
/// Spawned during onLaunch (or completeOnboarding).
private func startUpcomingMirrorTask() {
    // withObservationTracking loop pattern
    Task { [weak self] in
        while let self, !Task.isCancelled {
            let newUpcoming = await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = self.calendar.upcoming
                } onChange: {
                    continuation.resume(returning: self.calendar.upcoming)
                }
            }
            self.upcoming = newUpcoming
            self.scheduleCalendarTimers()
        }
    }
}
```

This ensures that whenever `CalendarService` refreshes `upcoming` (on `.EKEventStoreChanged`, on
`refreshUpcoming` calls), AppCore picks up the change, updates its own published property, and
reschedules calendar-start timers.

### Detection handling (consuming `detector.events()`)

```swift
private func consumeDetectorEvents() async {
    for await event in detector.events() {
        switch event {
        case let .started(app):
            await handleDetectionStarted(app: app)
        case let .stopped(app):
            await handleDetectionStopped(app: app)
        }
    }
}
```

**`handleDetectionStarted(app:)`:**

1. **Suppress if already recording.** If `runState` is `.recording(_)`, log and ignore. The user
   is already in a session; a second detection becomes a no-op (one recording at a time). The
   architecture allows "additional detections queue as notifications" -- but presenting a second
   "Record" notification while already recording is confusing. Suppress entirely.

2. **Suppress if a calendar meeting for this window already prompted/active.** If a calendar-start
   notification was already presented for a currently-in-progress event and the user hasn't acted,
   suppress the ad-hoc detection to avoid de-dup noise. Implementation: check whether any
   calendar timer has recently fired for an event that overlaps `now` and whose `conferenceURL`
   or attendee list suggests it is the same meeting. In V1, the heuristic is simple: if a
   calendar-start notification was presented in the last 10 minutes for any event, suppress ad-hoc
   detection. (A more precise match by conference URL/app could be added later.)

3. **Present notification.** `await notifications.present(.adHocDetected(bundleID: app.bundleID, appName: app.displayName))`.

4. **Update state.** `runState = .detectedPending`.

**`handleDetectionStopped(app:)`:**

1. If the stopped app's `bundleID` matches `activeDetectedBundleID` and `runState` is
   `.recording(_)` and `isDetectionDriven` is true: begin the auto-stop countdown.
2. Otherwise: ignore. (The stopped app is not the one powering the current recording, or the
   recording is manual, or no recording is active.)

### Auto-stop countdown

Applies **only** to detection-driven recordings when the detected app's audio stops. Manual
recordings (started via the UI or a calendar notification without a matching detection) never
auto-stop.

```swift
private func beginAutoStopCountdown(meetingID: UUID) {
    // Cancel any existing countdown (shouldn't happen, but defensive)
    countdownTask?.cancel()

    let countdownSeconds = 15

    countdownTask = Task { [weak self, scheduler, notifications] in
        // Initial notification
        await notifications.present(.stopCountdown(
            meetingID: meetingID,
            secondsRemaining: countdownSeconds
        ))

        for remaining in stride(from: countdownSeconds - 1, through: 0, by: -1) {
            do {
                try await scheduler.sleep(for: .seconds(1))
            } catch {
                return  // cancelled (keepRecording or manual stop)
            }
            guard !Task.isCancelled else { return }

            if remaining > 0 {
                await notifications.updateCountdown(
                    meetingID: meetingID,
                    secondsRemaining: remaining
                )
            }
        }

        // Timer reached 0 -- auto-stop
        guard let self, !Task.isCancelled else { return }
        await self.stopRecording()
    }
}

private func cancelAutoStopCountdown(meetingID: UUID) {
    countdownTask?.cancel()
    countdownTask = nil
    Task {
        await notifications.cancelCountdown(meetingID: meetingID)
    }
}
```

The countdown `Task` calls `scheduler.sleep(for: .seconds(1))` in a loop. Each iteration updates
the notification banner (via `updateCountdown`). If the user taps "Keep Recording", the notification
action handler cancels the task (see below). If the countdown reaches 0, `stopRecording()` is
called, which also cancels the countdown notification.

### Notification action handling (consuming `notifications.actions()`)

```swift
private func consumeNotificationActions() async {
    for await action in notifications.actions() {
        switch action {
        case let .openAndRecord(eventKey):
            await recordDetectedEvent(eventKey: eventKey)

        case let .join(url):
            // Open the conference URL in the default browser.
            // NSWorkspace.shared.open(url) -- this is the only AppKit call;
            // it lives in AppCore because the action originates here, not in UI.
            // TODO: Consider moving to an injected URLOpener seam for testability.
            NSWorkspace.shared.open(url)

        case let .keepRecording(meetingID):
            cancelAutoStopCountdown(meetingID: meetingID)
        }
    }
}
```

**`.openAndRecord(eventKey:)`:** Delegates to `recordDetectedEvent(eventKey:)`, which ensures the
window is visible (the app target listens for a signal or AppCore calls through a window-management
seam) and starts recording with the given event key. If `eventKey` is `nil` (from an ad-hoc
detection), `startRecording(eventKey: nil)` auto-matches via `bestMatch(at: now)`.

**`.join(url)`:** Opens the URL in the default browser. This is a fire-and-forget action. The
meeting-start notification also has an "Open & Record" action, so Join alone does not start a
recording.

**`.keepRecording(meetingID:)`:** Cancels the auto-stop countdown task, removes the countdown
notification, and the recording continues normally. `isDetectionDriven` remains `true`, so if the
app's audio stops again, a new countdown begins.

### `startRecording(eventKey:)` with C4 association

```swift
public func startRecording(eventKey: String?) async {
    // One-recording-at-a-time guard
    guard runState == .idle || runState == .detectedPending else { return }

    // 1. Resolve the calendar event
    let resolvedEvent: CalendarEvent?
    if let eventKey {
        resolvedEvent = calendar.event(forKey: eventKey)
    } else {
        resolvedEvent = calendar.bestMatch(at: Date())
    }

    // 2. Start the recording engine
    await recording.start()
    guard recording.state.isRecording, let meetingID = recording.state.meetingID else {
        // Permission denied or engine error; recording.lastError surfaces it.
        return
    }

    // 3. Update run state
    runState = .recording(meetingID)
    route = .recording

    // 4. Associate with the calendar event (if resolved)
    if let resolvedEvent {
        await associateEvent(resolvedEvent, with: meetingID)
    }
}

private func associateEvent(_ event: CalendarEvent, with meetingID: UUID) async {
    // Build the snapshot DTO from the live event
    guard let snapshotInput = await calendar.snapshot(forKey: event.id) else {
        // Event was deleted between resolve and snapshot; proceed unlinked.
        return
    }

    do {
        // Persist the snapshot + participants atomically
        try await store.setSnapshot(snapshotInput, for: meetingID)

        // Create/dedup Person records and link as participants
        var personIDs: [UUID] = []
        var organizerID: UUID?

        if let org = snapshotInput.organizer {
            let id = try await store.findOrCreatePerson(name: org.name, email: org.email)
            organizerID = id
        }
        for attendee in snapshotInput.attendees {
            let id = try await store.findOrCreatePerson(name: attendee.name, email: attendee.email)
            personIDs.append(id)
        }

        try await store.setParticipants(personIDs, organizer: organizerID, for: meetingID)
    } catch {
        // Non-fatal: recording continues without calendar context.
        // Log the error; the user can manually associate later.
    }
}
```

**Association flow:** explicit `eventKey` (from an `.event(key)` preview or a notification action)
takes priority; if `nil`, `bestMatch(at: now)` picks the best in-progress/imminent event. If no
match, the recording proceeds unlinked with an auto-generated title. The user can correct the
association later in Meeting Detail.

### `stopRecording()`

```swift
public func stopRecording() async {
    // Cancel any auto-stop countdown (idempotent)
    if case let .recording(meetingID) = runState {
        cancelAutoStopCountdown(meetingID: meetingID)
    }

    guard let meetingID = await recording.stop() else { return }

    // Clear detection tracking
    isDetectionDriven = false
    activeDetectedBundleID = nil

    // Reload summaries, route to detail
    await reloadSummaries()
    runState = .idle
    route = .meeting(meetingID)

    // Fire-and-forget transcription (now using effective vocabulary)
    pendingTranscriptionTask = Task { @MainActor [transcription] in
        await transcription.transcribe(meetingID: meetingID)
    }
}
```

The `TranscriptionService` (extended in Stage C) internally calls
`vocabulary.effectiveVocabulary(meetingID:)` to assemble app-wide + per-meeting terms before running
the engine. AppCore does not need to pass vocabulary explicitly; the service resolves it from the
meeting's associated calendar context.

### `recordDetectedEvent(eventKey:)`

```swift
public func recordDetectedEvent(eventKey: String?) async {
    // Signal the app target to make the window visible.
    // (The app target observes a published flag or NSApp.activate.)
    // This is app-target glue; AppCore sets a flag the app target watches.

    isDetectionDriven = true
    // If this came from an ad-hoc detection, activeDetectedBundleID was set
    // by handleDetectionStarted. If from a calendar notification, it stays nil
    // (calendar recordings don't auto-stop on detection loss).

    await startRecording(eventKey: eventKey)
}
```

When called from a calendar-start notification action (`.openAndRecord(eventKey: someKey)`), the
recording is associated with that event. When called from an ad-hoc detection
(`.openAndRecord(eventKey: nil)`), `startRecording` falls through to `bestMatch`.

**Detection-driven tracking:** `isDetectionDriven = true` means auto-stop applies if the detected
app's audio stops. Calendar-start-triggered recordings where no ad-hoc detection is active do
NOT set `activeDetectedBundleID`, so they will not auto-stop even if some unrelated detection
event fires. Only when the user explicitly records in response to an ad-hoc detection is the
recording tied to that detected app's lifecycle.

### Run-state machine

```
                                         startRecording
    ┌──────────────── idle ──────────────────────────────► recording(id)
    │                  ▲  ▲                                     │
    │                  │  │                                     │ stopRecording
    │   completeOnb.   │  └─────────────────────────────────────┘
    │                  │
    │                  │  cancelAutoStop / keepRecording
    │                  │  (resets to recording, not idle)
    │                  │
    │                  │        handleDetectionStarted
    │                  └──── detectedPending ◄────────── idle
    │                              │
    │                              │ recordDetectedEvent
    │                              └──────────────────► recording(id)
    │
    │  startRecording (from .detectedPending)
    └──────────────────────────────────────────────────► recording(id)
```

Transitions:
- `idle` -> `detectedPending`: ad-hoc detection notification presented.
- `detectedPending` -> `recording(id)`: user taps Record on the notification.
- `detectedPending` -> `idle`: the detection stops before the user acts (notification dismissed
  implicitly; `runState` resets when the detection `.stopped` fires with no active recording).
- `idle` -> `recording(id)`: manual start from UI or calendar notification action.
- `recording(id)` -> `idle`: `stopRecording()` (manual, auto-stop, or quit-while-recording).
- `detectedPending` -> `idle` -> `recording(id)` collapsed: if the user starts manually while
  `detectedPending`, the detection state is cleared and it transitions directly to `recording`.

**Menu bar derivation:** the menu bar reads `runState` directly:
- `.idle` -> show "Start Recording" button.
- `.recording(_)` -> show elapsed time + "Stop" button + recording indicator in the icon.
- `.detectedPending` -> show "Meeting detected" hint + "Record" button.

### Navigation methods

```swift
public func presentSearch() {
    searchReturnRoute = route
    route = .search
}

public func dismissSearch() {
    route = searchReturnRoute ?? .home
    searchReturnRoute = nil
}

public func showHome() {
    route = .home
}

public func showSettings() {
    route = .settings
}

public func showOnboardingReplay() {
    route = .onboarding
}

public func select(_ meetingID: UUID) {
    route = .meeting(meetingID)
}

public func navigateToRecording() {
    guard case .recording = runState else { return }
    route = .recording
}
```

`searchReturnRoute` is saved when entering search and restored when leaving. If search is
dismissed and the saved route is `nil` (should not happen), fall back to `.home`.

### `completeOnboarding()`

```swift
public func completeOnboarding() async {
    // Persist the flag
    do {
        try await store.updateSettings { settings in
            settings.onboardingComplete = true
        }
    } catch {
        // Non-fatal; the flag will be retried on next launch.
    }

    // Transition to Home
    route = .home

    // Now start the background services that were deferred during onboarding
    calendar.startObserving()
    await calendar.refreshUpcoming(window: DateInterval(
        start: Date(),
        end: Date().addingTimeInterval(24 * 60 * 60)
    ))
    upcoming = calendar.upcoming

    detector.start()
    detectorConsumerTask = Task { [weak self] in
        await self?.consumeDetectorEvents()
    }
    notificationConsumerTask = Task { [weak self] in
        await self?.consumeNotificationActions()
    }

    scheduleCalendarTimers()
    startUpcomingMirrorTask()

    await reloadSummaries()
}
```

### One-recording-at-a-time enforcement

Enforced in `startRecording(eventKey:)` via the `runState` guard. If `runState` is
`.recording(_)`, the method returns immediately. Concurrent detection events while recording are
suppressed in `handleDetectionStarted`. Calendar-start notifications that fire while recording
are suppressed in `handleCalendarTimerFired`. The UI's "Start Recording" button is disabled when
`runState != .idle` (driven by the published state).

### Quit-while-recording

Handled by the **app target**, not AppCore directly. The `NSApplicationDelegate`'s
`applicationShouldTerminate(_:)` checks `appCore.runState`:

- If `.recording(_)`: call `await appCore.stopRecording()`, then `NSApp.reply(toApplicationShouldTerminate: true)`.
- Otherwise: return `.terminateNow`.

AppCore's `stopRecording()` handles the full teardown (stop engine, mark audio presence, enqueue
transcription). The transcription task may not complete before the process exits; this is accepted
(it will be a completed-but-untranscribed recording, same as a crash recovery). The audio files are
safe because ADTS-AAC is valid up to the stop point.

### Error handling and graceful degradation

- **Calendar denied/restricted:** `CalendarService.auth` is `.denied`; `upcoming` stays empty;
  calendar-start timers never schedule; `bestMatch` returns `nil`; recordings proceed unlinked.
  No crash, no error surface beyond the empty state in the UI.

- **Notifications denied:** `NotificationService.present(...)` is a no-op internally (logs a
  warning). Detection events still update `runState` to `.detectedPending` and the menu bar
  shows the indicator, but no banner appears. The user can still start recording from the menu
  bar or window.

- **Detection unavailable:** If `AudioActivityMonitor` fails to start (system audio denied),
  `MeetingDetector.events()` produces no events. Calendar-start notifications still work.
  Manual recording still works.

- **Recording/transcription errors:** Unchanged from Stage B. `RecordingController.lastError`
  surfaces permission/engine failures. `TranscriptionService.jobs[id]` surfaces `.failed` with
  retriable flag. AppCore does not crash on these; it resets `runState` to `.idle` and logs.

- **Store errors:** `reloadSummaries` catches and returns an empty list (Stage B behavior).
  `associateEvent` catches and continues without calendar context. Settings read/write failures
  are caught and logged.

---

## Dependencies

### AppCore depends on (internal, Stage B -- unchanged)

| Module | What's used |
|---|---|
| `DataStore` (L0) | `meetingSummaries`, `meetingDetail`, `settings`, `updateSettings`, `setSnapshot`, `findOrCreatePerson`, `setParticipants`, `audioPaths` |
| `Permissions` (L0) | `microphone`, `systemAudio`, `calendar`, `notifications` status; `refresh()` |
| `Recording` (L1) | `RecordingController` -- `start`, `stop`, `recoverOrphans`, `state` |
| `TranscriptionService` (L1) | `transcribe`, `reTranscribe`, `jobs` |

### AppCore depends on (internal, Stage C -- new)

| Module | What's used |
|---|---|
| `Calendar` (L1) | `CalendarService` -- `startObserving`, `refreshUpcoming`, `bestMatch`, `snapshot`, `event(forKey:)`, `upcoming`, `auth`, `requestAccess`, `calendars` |
| `MeetingDetection` (L1) | `MeetingDetector` -- `start`, `stop`, `events()` |
| `Notifications` (L1) | `NotificationService` -- `present`, `updateCountdown`, `cancelCountdown`, `actions()`, `requestAuthorization` |
| `Vocabulary` (L1) | `VocabularyService` -- `appWide`, `setAppWide`, `effectiveVocabulary` (exposed for UI; used by TranscriptionService internally) |
| `MeetingCatalog` (L0) | `BundledMeetingCatalog` -- constructed in `live()`, passed to Calendar + Detector |

### What depends on AppCore

| Consumer | What it reads/calls |
|---|---|
| `HomeUI` (L3a) | `upcoming`, `runState`, `startRecording`, `showSettings` |
| `SearchUI` (L3a) | `presentSearch`, `dismissSearch`, `store.searchHits` |
| `SettingsUI` (L3a) | `showSettings`, `calendar`, `vocabulary`, `permissions` |
| `OnboardingUI` (L3a) | `completeOnboarding`, `permissions`, `calendar`, `transcription` |
| `MenuBarUI` (L3a) | `runState`, `upcoming`, `summaries`, `startRecording`, `stopRecording`, `select` |
| `MeetingListUI` (L3a) | `summaries`, `upcoming`, `select`, `navigateToRecording`, `runState` |
| `MeetingDetailUI` (L3a) | `store`, `transcription`, `calendar`, `select` |
| `RecordingUI` (L3a) | `recording.state`, `stopRecording` |
| `AppShellUI` (L3b) | `route`, `searchReturnRoute`, all navigation methods |
| App target | `onLaunch`, `stopRecording` (quit-while-recording), `live(...)` factory |

---

## Test Plan

All tests use `swift-testing` and run headlessly via `swift test`. Every service is faked:
`RecordingController` with a `FakeRecorder`, `TranscriptionService` with a `FakeTranscriber`,
`CalendarService` with a `FakeEventStoreProviding`, `MeetingDetector` with a `FakeActivitySource`,
`NotificationService` with a `FakeNotificationCenter`, `VocabularyService` with an in-memory
`DataStore`. The `FakeScheduler` (controllable clock) replaces `LiveAppScheduler` for all
timer-dependent tests. Tests live in `BiscottiKit/Tests/AppCoreTests/`.

### Test helpers

```swift
/// Controllable scheduler for deterministic timer tests.
struct FakeScheduler: AppScheduler {
    private let _now: LockIsolated<ContinuousClock.Instant>
    private var pendingSleeps: [(duration: Duration, continuation: CheckedContinuation<Void, Error>)]

    func sleep(for duration: Duration) async throws { /* register and suspend */ }
    func now() -> ContinuousClock.Instant { _now.value }
    func advance(by duration: Duration) { /* advance _now, resume elapsed sleeps */ }
}

/// Drives the MeetingDetector with synthetic events without going through
/// the full ActivitySource -> state machine pipeline.
struct FakeMeetingDetector {
    // Yields scripted DetectionEvent values on demand.
    func emitStarted(app: DetectedApp)
    func emitStopped(app: DetectedApp)
}

/// Scripted CalendarService that returns controlled upcoming/bestMatch/snapshot.
struct FakeCalendarService {
    var upcomingEvents: [CalendarEvent] = []
    var bestMatchResult: CalendarEvent? = nil
    var snapshotResult: CalendarSnapshotInput? = nil
}

/// Records all present/updateCountdown/cancelCountdown calls.
struct FakeNotificationService {
    var presentedKinds: [NotificationKind] = []
    var cancelledCountdowns: [UUID] = []
    // Also drives the actions() stream with scripted actions.
}
```

### Test cases

#### Detection -> notification flow

**`detectionStartedPresentsAdHocNotification`** -- Emit a `.started(app:)` detection event
while `runState == .idle`. Verify `notifications.present(.adHocDetected(...))` was called with the
correct `bundleID` and `appName`. Verify `runState == .detectedPending`.

**`suppressesAdHocWhileRecording`** -- Start a manual recording (`runState == .recording`). Emit a
`.started(app:)` detection event. Verify no notification was presented. Verify `runState` remains
`.recording`.

**`suppressesAdHocWhenCalendarRecentlyPrompted`** -- Fire a calendar-start timer (advance the
scheduler past the event's start time). Then emit a `.started(app:)` detection event within the
suppression window. Verify the ad-hoc notification is NOT presented (de-dup).

#### Notification actions

**`openAndRecordActionStartsAndAssociates`** -- Configure `fakeCalendar.snapshotResult` with a
valid snapshot. Push `.openAndRecord(eventKey: "key-1")` onto the notification actions stream.
Verify `recording.start()` was called. Verify `store.setSnapshot` was called with the snapshot for
the correct meeting ID. Verify `runState == .recording(meetingID)`.

**`openAndRecordNilKeyUseBestMatch`** -- Configure `fakeCalendar.bestMatchResult` to return an
event. Push `.openAndRecord(eventKey: nil)`. Verify the recording is associated with the
bestMatch event.

**`joinActionOpensURL`** -- Push `.join(url)` onto the actions stream. Verify the URL-opener seam
was called with the correct URL. Verify `runState` is unchanged.

#### Auto-stop countdown

**`autoStopCountsDownAndStops`** -- Start a detection-driven recording (set `isDetectionDriven`,
`activeDetectedBundleID`). Emit `.stopped(app:)` for the matching bundle ID. Verify the countdown
notification is presented with `secondsRemaining: 15`. Advance the fake scheduler by 1 second 15
times. Verify `updateCountdown` was called with decreasing seconds. After the 15th advance, verify
`stopRecording()` was called and `runState == .idle`.

**`keepRecordingCancelsCountdown`** -- Start a detection-driven recording. Emit `.stopped(app:)`.
Advance the scheduler by 5 seconds (countdown at 10). Push `.keepRecording(meetingID:)` onto the
actions stream. Verify `cancelCountdown` was called. Advance the scheduler by 20 more seconds.
Verify `stopRecording()` was NOT called. Verify `runState` remains `.recording`.

**`manualRecordingDoesNotAutoStop`** -- Start a manual recording (`isDetectionDriven == false`).
Emit `.stopped(app:)` for a watchlist app. Verify NO countdown is started. Verify `runState`
remains `.recording`.

**`detectionStoppedForWrongAppIgnored`** -- Start a detection-driven recording with
`activeDetectedBundleID = "us.zoom.xos"`. Emit `.stopped(app:)` with `bundleID = "com.tinyspeck.slackmacgap"`.
Verify no countdown starts.

#### Calendar-start timers

**`calendarStartTimerPresentsAtStart`** -- Set `upcoming` to contain one meeting-like event
starting in 60 seconds. Call `scheduleCalendarTimers()`. Advance the fake scheduler by 60 seconds.
Verify `notifications.present(.meetingStarting(eventKey:title:joinURL:))` was called with the
event's data.

**`reschedulesTimersOnUpcomingChange`** -- Schedule timers for event A (in 120s). Update
`calendar.upcoming` to contain event B (in 60s) and remove event A. Trigger the
upcoming-mirror observer. Verify the old timer for A was cancelled (advancing 120s does not fire
A). Verify the new timer for B fires at 60s.

**`calendarTimerSuppressedWhileRecording`** -- Start a recording. Advance the scheduler past a
scheduled calendar-start timer. Verify the notification was NOT presented (the
`handleCalendarTimerFired` guard on `runState` suppresses it).

**`calendarTimerSkipsAlreadyStartedEvents`** -- Set `upcoming` to contain an event whose `start`
is in the past. Call `scheduleCalendarTimers()`. Verify no timer is created for it (the
`delay > 0` guard).

#### Recording with C4 association

**`startRecordingAutoAssociatesBestMatch`** -- Configure `bestMatchResult` to return an event.
Call `startRecording(eventKey: nil)`. Verify `store.setSnapshot` and `store.setParticipants` were
called for the meeting. Verify the meeting's calendar context is populated.

**`startRecordingExplicitKeyOverridesBestMatch`** -- Configure both `bestMatchResult` and
`event(forKey: "explicit-key")`. Call `startRecording(eventKey: "explicit-key")`. Verify the
explicit event was used (not bestMatch).

**`startRecordingNoMatchProceedsUnlinked`** -- Configure `bestMatchResult = nil`. Call
`startRecording(eventKey: nil)`. Verify no snapshot/participants calls were made. Verify the
recording started successfully with `runState == .recording`.

**`associationFailureContinuesRecording`** -- Configure `snapshot(forKey:)` to return a valid
snapshot but `store.setSnapshot` to throw. Verify the recording continues (`runState == .recording`)
and no crash occurs.

#### Onboarding gate

**`onboardingGateRoutesToOnboardingWhenIncomplete`** -- DataStore `settings().onboardingComplete ==
false`. Call `onLaunch()`. Verify `route == .onboarding`. Verify `detector.start()` was NOT called.
Verify no calendar-start timers are scheduled.

**`onboardingGateRoutesToHomeWhenComplete`** -- DataStore `settings().onboardingComplete == true`.
Call `onLaunch()`. Verify `route == .home`. Verify `detector.start()` was called. Verify calendar
timers are scheduled.

**`completeOnboardingStartsBackgroundServices`** -- Call `completeOnboarding()`. Verify
`store.updateSettings` was called with `onboardingComplete = true`. Verify `calendar.startObserving`
was called. Verify `detector.start()` was called. Verify `route == .home`.

#### Search return route

**`searchReturnRouteRestores`** -- Set `route = .meeting(someID)`. Call `presentSearch()`. Verify
`route == .search` and `searchReturnRoute == .meeting(someID)`. Call `dismissSearch()`. Verify
`route == .meeting(someID)` and `searchReturnRoute == nil`.

**`searchReturnRouteDefaultsToHome`** -- Set `searchReturnRoute = nil` directly (edge case). Call
`dismissSearch()`. Verify `route == .home`.

#### Run state transitions

**`runStateTransitionsManualFlow`** -- Start from `.idle`. Call `startRecording(eventKey: nil)`.
Verify `.recording(id)`. Call `stopRecording()`. Verify `.idle`.

**`runStateTransitionsDetectionFlow`** -- Start from `.idle`. Emit detection `.started`. Verify
`.detectedPending`. Push `.openAndRecord(eventKey: nil)`. Verify `.recording(id)`. Emit detection
`.stopped`. Advance countdown to 0. Verify `.idle`.

**`oneRecordingAtATimeRejectsSecondStart`** -- Start a recording. Call
`startRecording(eventKey: nil)` again. Verify the second call is a no-op (`runState` unchanged,
`recording.start()` not called a second time).

#### Quit-while-recording

**`quitWhileRecordingStopsAndSaves`** -- Start a recording. Simulate the app-target quit path by
calling `await appCore.stopRecording()`. Verify `recording.stop()` was called. Verify the
meeting is in `summaries`. Verify `runState == .idle`. (The transcription task may be pending;
verify it was spawned but do not await completion -- mirrors the real quit behavior.)

#### Vocabulary integration (cross-module)

**`effectiveVocabularyUsedOnTranscribe`** -- This test may live in `TranscriptionServiceTests`
rather than `AppCoreTests`, since AppCore does not directly pass vocabulary. Verify that after
`stopRecording()` triggers `transcription.transcribe(meetingID:)`, the `TranscriptionService`
internally calls `vocabulary.effectiveVocabulary(meetingID:)` and passes the result to the engine.
Uses an in-memory DataStore with app-wide vocabulary set and a calendar snapshot with attendees.

### Clock seam requirements

The following tests require `FakeScheduler`:
- `autoStopCountsDownAndStops`
- `keepRecordingCancelsCountdown`
- `calendarStartTimerPresentsAtStart`
- `reschedulesTimersOnUpcomingChange`
- `calendarTimerSuppressedWhileRecording`
- `calendarTimerSkipsAlreadyStartedEvents`
- `runStateTransitionsDetectionFlow` (the countdown portion)

All other tests can use `LiveAppScheduler` (they don't exercise timed behavior) but may also use
`FakeScheduler` for uniformity.

### What is NOT tested here

- **Real `UNUserNotificationCenter` / `EKEventStore` / `AudioActivityMonitor`** -- these are
  integration/hardware tests validated manually.
- **UI rendering** -- tested in the respective UI module test targets with fake AppCore/DTOs.
- **`NSApplicationDelegate` quit handling** -- tested as a unit test on AppCore (`stopRecording()`
  called directly), not via AppKit lifecycle simulation.
- **Actual clock precision** -- `FakeScheduler` is perfectly deterministic; real-world timer jitter
  is acceptable and does not affect correctness (a 15.05s countdown is fine).

---

## Contract Gaps and Risks

1. **`RecordingController.start()` does not accept an `eventKey` parameter.** The Stage B
   `RecordingController.start()` creates the meeting internally (auto-title). For C4 association,
   AppCore needs the `meetingID` back before it can call `store.setSnapshot`. The current contract
   returns `meetingID` only from `stop()`. **Resolution:** either (a) extend `RecordingController`
   to expose the in-flight `meetingID` on `state` (it already has `state.meetingID: UUID?`), or
   (b) have `start()` return the meeting ID. The existing `state.meetingID` on `RecordingState`
   suffices -- AppCore reads `recording.state.meetingID` after a successful `start()`. **No
   protocol change needed**, but confirm `RecordingState.meetingID` is set before `start()` returns.

2. **Window activation from notification action.** `recordDetectedEvent` needs to bring the app
   window to the front. AppCore is `@MainActor` but does not hold a window reference. **Resolution
   options:** (a) `NSApp.activate(ignoringOtherApps: true)` directly in AppCore (simple, no seam);
   (b) inject a `WindowActivator` protocol (testable, but over-engineered for a single call).
   Recommend option (a) for V1 with a `// TODO` for the seam if tests need it. The app target's
   `WindowGroup` will re-appear when the app activates.

3. **`calendar.upcoming` observation.** The mirroring uses `withObservationTracking` in a polling
   loop. This is the standard Swift Observation pattern for non-SwiftUI contexts, but it requires
   the observation closure to capture `self.calendar.upcoming` to register the tracking. If
   `CalendarService.upcoming` is replaced (array identity changes), the observation fires. If only
   array elements change, it also fires (value-type `@Observable` property replacement). **No gap
   if `CalendarService` replaces the whole `upcoming` array on each refresh** (which it does per
   the calendar component doc).

4. **`detectedPending` -> `idle` transition.** If a detection `.stopped` event arrives while
   `runState == .detectedPending` (the user never acted on the notification), the state should
   revert to `.idle`. The current design handles this in `handleDetectionStopped`: if
   `runState == .detectedPending` and the stopped app matches the one that triggered the pending
   state, reset to `.idle`. **Ensure `activeDetectedBundleID` is set in `handleDetectionStarted`
   even before recording starts**, so the stopped-matching logic works for pending detections too.

5. **`TranscriptionService` vocabulary dependency.** The architecture (section 10) says
   `TranscriptionService` gains a `VocabularyService` dependency. The existing `TranscriptionService`
   init is `init(store:engine:)`. Stage C extends it to `init(store:engine:vocabulary:)`. This is a
   **source-breaking change** to the existing init -- all callers (AppCore, PreviewAppCore, tests)
   must be updated. **Not a design gap, but a migration note for the coding agent.**

import Calendar
import DataStore
import Foundation
import MeetingCatalog
import MeetingDetection
import Notifications
import os
import Permissions
import Recording
import TranscriptionService

// MARK: - Cross-module notification names

public extension Notification.Name {
    /// Posted after the "exit app on window close" setting is persisted.
    /// The app delegate observes this to refresh its cached lifecycle
    /// policy for the synchronous
    /// `applicationShouldTerminateAfterLastWindowClosed` callback.
    /// Defined here (not in SettingsUI) so the app target can observe it
    /// without importing SettingsUI directly.
    static let exitOnWindowCloseDidChange = Notification.Name(
        "net.scosman.biscotti.exitOnWindowCloseDidChange"
    )

    /// Posted after the "menu bar lead time" setting is persisted.
    /// `MenuBarViewModel` observes this to refresh its cached lead time
    /// so `iconState` reflects the new threshold without restart.
    static let menuBarLeadTimeDidChange = Notification.Name(
        "net.scosman.biscotti.menuBarLeadTimeDidChange"
    )

    /// Posted after the "global record shortcut" setting is toggled.
    /// The app delegate observes this to register/unregister the Carbon
    /// hotkey live without requiring a restart.
    static let globalRecordShortcutDidChange = Notification.Name(
        "net.scosman.biscotti.globalRecordShortcutDidChange"
    )
}

// MARK: - Deep-link jump state

/// A pending transcript jump parsed from a `biscotti://meeting/{id}?time=…` URL.
///
/// Set by `handleDeepLink(_:)` and consumed by `MeetingDetailViewModel` once
/// the target meeting's detail view has applied the jump (tab switch + seek).
public struct TranscriptJump: Sendable, Equatable {
    public let meetingID: UUID
    public let time: TimeInterval

    public init(meetingID: UUID, time: TimeInterval) {
        self.meetingID = meetingID
        self.time = time
    }
}

// MARK: - Recording startup state

/// Observable state for the recording startup phase.
///
/// Lets the UI show a loading spinner immediately when the user clicks
/// "Record", decoupled from the heavy async startup (audio engine init,
/// calendar association, etc.).
public enum RecordingStartupState: Sendable, Equatable {
    /// The recording pane is showing but the audio pipeline hasn't started yet.
    case loading
    /// The audio pipeline started successfully; the pane shows live recording UI.
    case started
    /// Startup failed; the pane shows an error with the given message.
    case failed(String)
}

// MARK: - Auto-stop observable state

/// Observable state published while an auto-stop countdown is active.
///
/// The view layer reads `deadline` against a `TimelineView` clock to
/// derive the remaining time and bar fraction. `total` is the original
/// duration so the bar starts full and decreases to zero.
public struct AutoStopState: Sendable, Equatable {
    public let meetingID: UUID
    public let deadline: Date
    public let total: TimeInterval

    public init(meetingID: UUID, deadline: Date, total: TimeInterval) {
        self.meetingID = meetingID
        self.deadline = deadline
        self.total = total
    }
}

/// Thin MVP coordinator that wires Recording, TranscriptionService,
/// CalendarService, MeetingDetector, NotificationService, Permissions,
/// and DataStore into a single observable surface for the UI.
///
/// The UI observes `route`, `summaries`, `upcoming`, and `runState` to
/// drive navigation and lists. Heavy work is delegated to the injected
/// services; this class owns coordination logic (launch recovery,
/// start/stop sequencing, auto-transcribe on stop, routing, C4
/// auto-association, detection -> notification -> record flow,
/// calendar-start timers, auto-stop countdown).
@MainActor @Observable
public final class AppCore {
    // MARK: - Published state

    /// The current navigation destination.
    public private(set) var route: Route = .home

    /// All meetings, newest first (uncapped — the Meetings list uses lazy rendering).
    public package(set) var summaries: [MeetingSummary] = []

    /// Monotonically increasing token that increments every time
    /// `reloadSummaries()` runs. Observers (e.g. `RecordingViewModel`)
    /// watch this to trigger a detail reload after any summaries refresh,
    /// regardless of whether the count or content changed. More robust
    /// than watching `summaries.count` which misses same-count changes
    /// like title updates from calendar association.
    public private(set) var summariesVersion: Int = 0

    // MARK: - Meetings screen state

    /// The selected meetings shown in the detail pane. Empty = no selection
    /// (placeholder). Exactly one = detail view. More than one = multi-select
    /// placeholder with delete affordance.
    public private(set) var meetingsSelection: Set<UUID> = []

    /// The search query. Empty = browse mode, non-empty = search mode.
    public private(set) var meetingsQuery: String = ""

    /// The search results (flat, ranked). Empty when in browse mode.
    public private(set) var meetingsResults: [SearchHit] = []

    /// Whether a search query is currently in flight.
    public private(set) var isSearchingMeetings = false

    /// Monotonically increasing token that signals the UI to focus the
    /// search field. Incremented by `focusSearch()`, observed by
    /// `SearchFieldFocuser` (an `NSViewRepresentable`) which calls
    /// `window.makeFirstResponder` on the toolbar's `NSTextField`.
    public private(set) var searchFocusToken: UInt = 0

    /// Meeting-like upcoming calendar events, mirrored from CalendarService.
    public package(set) var upcoming: [CalendarEvent] = []

    /// Clock-minute-aligned tick used to refresh upcoming event filtering
    /// and relative-time labels. Updated every minute at :00 of the wall
    /// clock. Driven by the `AppScheduler` seam for testability.
    public private(set) var minuteTick: Date = .init()

    /// Upcoming events filtered to exclude those whose end < `minuteTick`.
    /// The sidebar, menu bar, and home screen should use this instead of
    /// `upcoming` directly.
    public var displayedUpcoming: [CalendarEvent] {
        upcoming.filter { $0.end > minuteTick }
    }

    /// The current run state. UI + menu bar observe this.
    public private(set) var runState: RunState = .idle

    /// Recording startup progress. Non-nil from the moment the user
    /// clicks Record until the pane dismisses or transitions to live.
    /// Drives loading/error states on the recording pane.
    public private(set) var recordingStartup: RecordingStartupState?

    /// Observable auto-stop countdown state. Non-nil while a countdown
    /// is active; the view layer renders a countdown card from this.
    public private(set) var autoStop: AutoStopState?

    /// A pending transcript jump from a deep link. Set by
    /// `handleDeepLink(_:)`, consumed by `MeetingDetailViewModel`
    /// after applying the tab switch + seek.
    public private(set) var pendingTranscriptJump: TranscriptJump?

    /// Cached menu bar lead time setting. Drives how far before a meeting
    /// the menu bar shows the detailed "next meeting" text.
    public private(set) var menuBarLeadTime: MenuBarLeadTime = .oneHour

    // MARK: - Child services (publicly readable for the UI layer)

    /// The persistent store.
    public let store: DataStore

    /// Mic + system-audio + calendar + notifications permission state.
    public let permissions: Permissions

    /// Recording lifecycle controller.
    public let recording: RecordingController

    /// Transcription orchestration.
    public let transcription: TranscriptionService

    /// Read-only bridge to EventKit for calendar data.
    public let calendar: CalendarService

    /// Audio-activity-based meeting detector.
    public let detector: MeetingDetector

    /// System notification presenter and action stream.
    public let notifications: NotificationService

    // MARK: - Private

    private let scheduler: any AppScheduler
    private var meetingsSearchTask: Task<Void, Never>?

    /// The bundle ID of the detected app that triggered the current recording.
    private var activeDetectedBundleID: String?

    /// Timestamp of the most recent calendar-start notification, for de-dup.
    private var lastCalendarNotificationDate: Date?

    /// Monotonic generation counter for recording startup. Incremented
    /// on cancel/retry/stop so an in-flight `completeRecordingStartup`
    /// can detect that its generation is stale and bail out.
    private var startupGeneration: UInt = 0

    /// The eventKey passed to `startRecording(eventKey:)`. Stashed so
    /// `retryRecordingStartup()` can re-attempt with the original key.
    private var pendingStartupEventKey: String?

    /// The auto-stop countdown task. Cancelled on keepRecording or manual stop.
    private var countdownTask: Task<Void, Never>?

    /// Calendar-start notification timer tasks, keyed by event composite key.
    private var calendarTimerTasks: [String: Task<Void, Never>] = [:]

    /// Background tasks for consuming detector events and notification actions.
    private var detectorConsumerTask: Task<Void, Never>?
    private var notificationConsumerTask: Task<Void, Never>?

    /// Task that mirrors calendar.upcoming into self.upcoming.
    private var upcomingMirrorTask: Task<Void, Never>?

    /// Task that fires at each clock-minute boundary to refresh
    /// `minuteTick`, driving displayed-upcoming filtering and
    /// relative-time label recomputation.
    private var minuteTickTask: Task<Void, Never>?

    /// The fire-and-forget transcription task spawned by `stopRecording()`.
    package var pendingTranscriptionTask: Task<Void, Never>?

    /// Observes `.menuBarLeadTimeDidChange` to refresh the cached lead time.
    private var menuBarLeadTimeObserverTask: Task<Void, Never>?

    /// Auto-stop countdown duration in seconds.
    private let autoStopSeconds = 10

    /// De-dup suppression window for ad-hoc detections after calendar prompts.
    private let calendarSuppressionInterval: TimeInterval = 600 // 10 minutes

    /// Whether `onLaunch()` has already executed. Guards against
    /// double-firing when SwiftUI re-creates the window (and its
    /// `.task` modifier) while the same AppCore instance persists.
    private var hasLaunched = false

    private let logger = Logger(
        subsystem: "net.scosman.biscotti",
        category: "AppCore"
    )

    private let detectionLogger = Logger(
        subsystem: "net.scosman.biscotti",
        category: "Detection"
    )

    // MARK: - Init

    /// Creates an `AppCore` from pre-built services (used by tests and the
    /// `live` factory).
    public init(
        store: DataStore,
        permissions: Permissions,
        recording: RecordingController,
        transcription: TranscriptionService,
        calendar: CalendarService,
        detector: MeetingDetector,
        notifications: NotificationService,
        scheduler: any AppScheduler = LiveAppScheduler()
    ) {
        self.store = store
        self.permissions = permissions
        self.recording = recording
        self.transcription = transcription
        self.calendar = calendar
        self.detector = detector
        self.notifications = notifications
        self.scheduler = scheduler
    }

    // MARK: - Lifecycle

    /// Called once at app launch. Recovers orphaned recordings, checks
    /// onboarding state, starts background services, and loads the sidebar.
    /// Idempotent: subsequent calls are no-ops (guards against SwiftUI
    /// re-creating the window and its `.task` modifier while the same
    /// long-lived AppCore instance persists).
    public func onLaunch() async {
        guard !hasLaunched else {
            logger.debug("onLaunch: skipped (already launched)")
            return
        }
        hasLaunched = true
        logger.info("onLaunch: enter")

        logger.info("onLaunch: recoverOrphans starting")
        await recording.recoverOrphans()
        logger.info("onLaunch: recoverOrphans done")

        // Check onboarding gate and load cached settings
        logger.info("onLaunch: reading settings")
        let onboardingComplete: Bool
        do {
            let settings = try await store.settings()
            onboardingComplete = settings.onboardingComplete
            loadMenuBarLeadTime(from: settings)
        } catch {
            onboardingComplete = false
        }
        startMenuBarLeadTimeObserver()

        if !onboardingComplete {
            logger.info("onLaunch: routing to onboarding")
            route = .onboarding
            await reloadSummaries()
            logger.info("onLaunch: done (onboarding)")
            return
        }

        logger.info("onLaunch: routing to home")
        route = .home

        await startBackgroundServices()

        logger.info("onLaunch: reloadSummaries starting")
        await reloadSummaries()
        logger.info("onLaunch: done")
    }

    /// Starts calendar observation, detection, consumer tasks, and timers.
    /// Extracted from `onLaunch` to stay within the function body length
    /// lint limit.
    private func startBackgroundServices() async {
        logger.info("startBackgroundServices: calendar startObserving")
        calendar.startObserving()
        logger.info("startBackgroundServices: calendar refreshUpcoming")
        let now = Date()
        await calendar.refreshUpcoming(
            window: DateInterval(
                start: now,
                end: now.addingTimeInterval(
                    CalendarService.upcomingWindowSeconds
                )
            )
        )
        upcoming = calendar.upcoming
        logger.info("startBackgroundServices: calendar done")

        logger.info("startBackgroundServices: detector start")
        detector.start()

        logger.info("startBackgroundServices: consumer tasks")
        detectorConsumerTask = Task { [weak self] in
            await self?.consumeDetectorEvents()
        }
        notificationConsumerTask = Task { [weak self] in
            await self?.consumeNotificationActions()
        }

        logger.info("startBackgroundServices: timers")
        scheduleCalendarTimers()
        startUpcomingMirrorTask()
        startMinuteTickTask()
        logger.info("startBackgroundServices: done")
    }

    // MARK: - Recording coordination

    /// Starts a new recording session, optionally associated with a
    /// specific calendar event.
    ///
    /// Navigation to the recording pane happens synchronously so the UI
    /// is responsive. The heavy startup (audio engine init, calendar
    /// association, summaries reload) runs asynchronously; the recording
    /// pane observes `recordingStartup` to show loading/started/failed.
    public func startRecording(eventKey: String? = nil) async {
        // One-recording-at-a-time guard
        guard runState == .idle || runState == .detectedPending else {
            return
        }

        // Stash the eventKey so retry can re-use it.
        pendingStartupEventKey = eventKey

        // Navigate instantly -- the recording pane shows a loading state.
        startupGeneration &+= 1
        recordingStartup = .loading
        route = .recording

        // Heavy startup runs in-line (callers already `await` this).
        await completeRecordingStartup(
            eventKey: eventKey,
            generation: startupGeneration
        )
    }

    /// Stops the current recording, reloads the sidebar, routes to the
    /// meeting detail, and auto-enqueues transcription.
    @discardableResult
    public func stopRecording() async -> UUID? {
        // Cancel any auto-stop countdown
        if case let .recording(meetingID) = runState {
            cancelAutoStopCountdown(meetingID: meetingID)
        }

        guard let meetingID = await recording.stop() else {
            return nil
        }

        // Clear detection tracking and startup state
        activeDetectedBundleID = nil
        pendingStartupEventKey = nil
        startupGeneration &+= 1
        recordingStartup = nil

        await reloadSummaries()
        runState = .idle
        select(meetingID)

        pendingTranscriptionTask = Task { @MainActor [transcription] in
            await transcription.transcribe(meetingID: meetingID)
        }

        return meetingID
    }

    /// Toggles recording: stops if currently recording, starts if idle.
    /// Used by the global hotkey so a single shortcut can both start and
    /// stop a session.
    @discardableResult
    public func toggleRecording() async -> UUID? {
        if recording.state.isRecording {
            return await stopRecording()
        } else {
            await startRecording()
            return nil
        }
    }

    /// Records a detected event (from a notification action). Starts
    /// recording, optionally associated with the given calendar event.
    public func recordDetectedEvent(eventKey: String?) async {
        await startRecording(eventKey: eventKey)
    }

    // MARK: - Navigation

    /// Opens a specific meeting from OUTSIDE the list (menu bar, Home recent,
    /// stopRecording, "open this meeting"). Clears any active search, sets
    /// a single-element selection, and routes to the Meetings screen.
    public func select(_ meetingID: UUID) {
        cancelMeetingsSearch()
        meetingsQuery = ""
        meetingsResults = []
        meetingsSelection = [meetingID]
        route = .meetings
    }

    /// Set selection from WITHIN the list (`List(selection:)` setter).
    /// Preserves the current mode (keeps the query if searching).
    /// Empty set = placeholder (no selection).
    public func selectFromList(_ ids: Set<UUID>) {
        meetingsSelection = ids
    }

    /// "Past Meetings" (sidebar) and "See all" (Home): browse mode,
    /// KEEP selection (D4).
    public func showMeetings() {
        cancelMeetingsSearch()
        meetingsQuery = ""
        meetingsResults = []
        route = .meetings
    }

    /// Routes to the recording screen (sidebar recording indicator tap).
    public func navigateToRecording() {
        guard recording.state.isRecording else { return }
        route = .recording
    }

    /// Routes to the Home screen.
    public func showHome() {
        route = .home
    }

    /// Routes to in-window Settings.
    public func showSettings() {
        route = .settings
    }

    /// Routes to Onboarding (re-run from Settings).
    public func showOnboardingReplay() {
        route = .onboarding
    }

    /// Requests focus on the search field. Increments the focus token
    /// so `SearchFieldFocuser` (an `NSViewRepresentable` on the toolbar
    /// `TextField`) detects the change and calls
    /// `window.makeFirstResponder` on the backing `NSTextField`.
    /// Called from the Cmd+F menu command.
    public func focusSearch() {
        searchFocusToken &+= 1
    }

    /// Routes to the read-only preview for an upcoming calendar event.
    public func selectEvent(_ key: String) {
        route = .event(key)
    }

    /// Marks onboarding complete and transitions to Home.
    public func completeOnboarding() async {
        do {
            try await store.updateSettings { settings in
                settings.onboardingComplete = true
            }
        } catch {
            logger.error("Failed to persist onboarding flag: \(error)")
        }

        route = .home

        // Start background services deferred during onboarding
        await startBackgroundServices()
        await reloadSummaries()
    }

    // MARK: - Permission refresh

    /// Refreshes all permission statuses from their live system sources.
    ///
    /// Microphone uses its injected seam. Calendar reads the live status
    /// from `CalendarService` (which queries EventKit directly). Notifications
    /// reads the live status from `NotificationService`. System audio has no
    /// public TCC API so its status is unchanged here.
    public func refreshAllPermissions() async {
        // Refresh mic (and any injected cal/notif seams)
        await permissions.refresh()

        // Sync calendar status from CalendarService (ground truth)
        let calStatus: PermissionState = switch calendar.auth {
        case .authorized: .authorized
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        }
        permissions.noteCalendar(calStatus)

        // Sync notification status from NotificationService (ground truth)
        if await notifications.isCurrentlyAuthorized() {
            permissions.noteNotifications(.authorized)
        } else if await notifications.isDenied() {
            permissions.noteNotifications(.denied)
        }
        // else: leave as .notDetermined
    }

    // MARK: - Onboarding support

    /// Triggers the system-audio permission prompt by exercising the
    /// capture probe and infers the permission state. Used by the
    /// onboarding wizard's system-audio step.
    public func requestSystemAudioPermission() async {
        // Use the recording controller's start flow to probe system audio.
        // We create a temporary recorder, probe it, and read back the
        // inferred state from permissions.
        await recording.probeSystemAudioAndInferState()
    }

    // MARK: - Data refresh

    /// Reloads all meeting summaries from the store (uncapped).
    ///
    /// Increments `summariesVersion` on every call so observers
    /// (e.g. `RecordingViewModel`) detect the refresh even when the
    /// count or content is unchanged.
    public func reloadSummaries() async {
        do {
            summaries = try await store.meetingSummaries()
        } catch {
            summaries = []
        }
        summariesVersion &+= 1
    }
}

// MARK: - Recording startup lifecycle

extension AppCore {
    /// The async heavy-lift portion of `startRecording`. Separated so
    /// the route/loading state are set synchronously before this runs.
    ///
    /// Checks `startupGeneration` after each `await` to detect a
    /// concurrent cancel/retry/stop. If the generation is stale, any
    /// partially-started recording is torn down and the method bails.
    private func completeRecordingStartup(
        eventKey: String? = nil,
        generation: UInt
    ) async {
        // Resolve the calendar event before starting
        let resolvedEvent: CalendarEvent? = if let eventKey {
            calendar.event(forKey: eventKey)
        } else {
            calendar.bestMatch(at: Date())
        }

        await recording.start()

        // Bail if cancelled/retried/stopped while start() was in flight.
        guard generation == startupGeneration else {
            await tearDownPartialRecording()
            return
        }

        guard recording.state.isRecording,
              let meetingID = recording.state.meetingID
        else {
            // Startup failed -- surface the error in the pane.
            let message = recording.lastError.map {
                Self.startupErrorMessage(for: $0)
            } ?? "Recording failed to start."
            recordingStartup = .failed(message)
            return
        }

        runState = .recording(meetingID)
        recordingStartup = .started
        pendingStartupEventKey = nil

        // Associate with the calendar event if resolved
        if let resolvedEvent {
            await associateEvent(resolvedEvent, with: meetingID)
        }

        guard generation == startupGeneration else {
            // Stale after association -- stop the orphan recording.
            await tearDownPartialRecording()
            return
        }

        // Reload summaries so the recording VM picks up the calendar
        // context and the sidebar/home titles are fresh.
        await reloadSummaries()
    }

    /// Stops and discards a recording that was started by a now-stale
    /// startup generation (cancel or retry raced with the in-flight start).
    private func tearDownPartialRecording() async {
        if recording.state.isRecording {
            _ = await recording.stop()
        }
    }

    /// Maps `RecordingError` to a user-facing message for the startup
    /// failure pane.
    nonisolated static func startupErrorMessage(
        for error: RecordingError
    ) -> String {
        switch error {
        case .permissionDenied(.microphone):
            "Microphone access is required to record."
        case .permissionDenied(.systemAudio):
            "System audio access is required."
        case let .permissionDenied(kind):
            "\(kind) permission is required."
        case let .engineFailed(detail):
            "Audio engine error: \(detail)"
        case let .storageFailed(detail):
            "Storage error: \(detail)"
        case .alreadyRecording:
            "A recording is already in progress."
        }
    }

    /// Cancels a pending recording startup and returns to the previous
    /// screen. Called when the user dismisses a failed startup.
    public func cancelRecordingStartup() {
        startupGeneration &+= 1
        pendingStartupEventKey = nil
        recordingStartup = nil
        // Only revert route if we're still on the recording screen
        // and no actual recording is running.
        if route == .recording, !recording.state.isRecording {
            route = .home
            runState = .idle
        }
    }

    /// Retries a failed recording startup from scratch, re-using the
    /// original eventKey from the initial `startRecording` call.
    public func retryRecordingStartup() async {
        let eventKey = pendingStartupEventKey
        startupGeneration &+= 1
        recordingStartup = .loading
        await completeRecordingStartup(
            eventKey: eventKey,
            generation: startupGeneration
        )
    }
}

// MARK: - Menu bar lead time

extension AppCore {
    /// Updates the cached `menuBarLeadTime` from a settings snapshot.
    func loadMenuBarLeadTime(from settings: AppSettingsData) {
        menuBarLeadTime = MenuBarLeadTime(
            seconds: settings.menuBarLeadTimeSeconds
        )
    }

    /// Starts an async observer that refreshes `menuBarLeadTime` when
    /// the setting is changed from SettingsUI.
    func startMenuBarLeadTimeObserver() {
        menuBarLeadTimeObserverTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .menuBarLeadTimeDidChange
            ) {
                guard let self else { return }
                let settings = try? await store.settings()
                if let settings {
                    loadMenuBarLeadTime(from: settings)
                }
            }
        }
    }
}

// MARK: - Deep-link handling

public extension AppCore {
    /// Handles a `biscotti://meeting/{id}?time={seconds}` deep link.
    ///
    /// Validates the URL components: scheme must be `biscotti`, host must
    /// be `meeting`, the path must contain a valid UUID, the `time` query
    /// parameter must parse as a number, and the meeting must exist in
    /// the store. On success, navigates to the meeting and sets
    /// `pendingTranscriptJump` for the detail VM to consume. Invalid
    /// or unresolvable URLs are silently ignored (no-op).
    func handleDeepLink(_ url: URL) async {
        guard url.scheme == "biscotti",
              url.host == "meeting"
        else { return }

        // Path is "/{uuid}" — strip the leading slash.
        let pathID = url.path.hasPrefix("/")
            ? String(url.path.dropFirst())
            : url.path
        guard let meetingID = UUID(uuidString: pathID) else { return }

        // Parse the `time` query parameter.
        guard let components = URLComponents(
            url: url, resolvingAgainstBaseURL: false
        ),
            let timeString = components.queryItems?
            .first(where: { $0.name == "time" })?.value,
            let seconds = Double(timeString)
        else { return }

        // Verify the meeting exists.
        let exists = await (try? store.meetingExists(id: meetingID)) ?? false
        guard exists else { return }

        select(meetingID)
        pendingTranscriptJump = TranscriptJump(
            meetingID: meetingID, time: seconds
        )
    }

    /// Clears the pending transcript jump after the detail VM has applied it.
    func consumeTranscriptJump() {
        pendingTranscriptJump = nil
    }
}

// MARK: - Test support

package extension AppCore {
    /// Waits for any pending fire-and-forget transcription task spawned by
    /// `stopRecording()` to finish.
    func awaitPendingTranscription() async {
        await pendingTranscriptionTask?.value
        pendingTranscriptionTask = nil
    }

    /// Injects an `AutoStopState` for tests that need to verify the
    /// view model guard against mismatched meeting IDs.
    func setAutoStopForTesting(_ state: AutoStopState?) {
        autoStop = state
    }
}

// MARK: - Meetings search

extension AppCore {
    /// Called when the toolbar query changes (bound from AppShellViewModel).
    /// Debounces 300ms via the `scheduler` seam before running the search.
    public func setMeetingsQuery(_ query: String) {
        meetingsQuery = query
        cancelMeetingsSearch()
        guard !query.isEmpty else {
            meetingsResults = []
            isSearchingMeetings = false
            return
        }
        route = .meetings
        isSearchingMeetings = true
        meetingsResults = []
        let sched = scheduler
        let currentStore = store
        meetingsSearchTask = Task { [weak self] in
            do {
                try await sched.sleep(for: .milliseconds(300))
            } catch {
                return // cancelled
            }
            guard let self,
                  !Task.isCancelled,
                  meetingsQuery == query
            else { return }
            let hits = await (try? currentStore.searchHits(
                query, limit: 50
            )) ?? []
            guard !Task.isCancelled, meetingsQuery == query
            else { return }
            meetingsResults = hits
            isSearchingMeetings = false
            autoSelectTopResult()
        }
    }

    /// Always selects the top search result (or empty if no results).
    /// Ensures the user sees the first match after every search, rather
    /// than a stale selection that might be below the fold.
    private func autoSelectTopResult() {
        if let topID = meetingsResults.first?.id {
            meetingsSelection = [topID]
        } else {
            meetingsSelection = []
        }
    }

    private func cancelMeetingsSearch() {
        meetingsSearchTask?.cancel()
        meetingsSearchTask = nil
        isSearchingMeetings = false
    }

    /// Non-debounced search for the current query. Used after delete
    /// to refresh results immediately.
    private func rerunMeetingsSearchNow() async {
        let currentQuery = meetingsQuery
        guard !currentQuery.isEmpty else { return }
        let hits = await (try? store.searchHits(
            currentQuery, limit: 50
        )) ?? []
        guard meetingsQuery == currentQuery else { return }
        meetingsResults = hits
        isSearchingMeetings = false
    }
}

// MARK: - Detection handling

extension AppCore {
    private func consumeDetectorEvents() async {
        for await event in detector.events() {
            switch event {
            case let .started(app):
                await handleDetectionStarted(app: app)
            case let .stopped(app):
                handleDetectionStopped(app: app)
            case .allMicUsersStopped:
                handleAllMicUsersStopped()
            }
        }
    }

    private func handleDetectionStarted(
        app: DetectedApp
    ) async {
        detectionLogger.info(
            "Received .started for \(app.bundleID)"
        )

        // Suppress if already recording
        if case .recording = runState {
            detectionLogger.info(
                "Suppressed: already recording"
            )
            return
        }

        // Suppress if a calendar notification was recently presented (de-dup)
        if let lastCal = lastCalendarNotificationDate {
            let elapsed = Date().timeIntervalSince(lastCal)
            let window = calendarSuppressionInterval
            if elapsed < window {
                detectionLogger.info(
                    "Suppressed: calendar prompt \(Int(elapsed))s ago (window \(Int(window))s)"
                )
                return
            }
        }

        detectionLogger.info(
            "Presenting ad-hoc notification for \(app.bundleID)"
        )

        // Present notification
        await notifications.present(
            .adHocDetected(
                bundleID: app.bundleID,
                appName: app.displayName
            )
        )

        // Track the detected app for stop matching
        activeDetectedBundleID = app.bundleID
        runState = .detectedPending
    }

    private func handleDetectionStopped(app: DetectedApp) {
        // If pending detection and the stopped app matches, revert to idle
        if runState == .detectedPending,
           activeDetectedBundleID == app.bundleID
        {
            runState = .idle
            activeDetectedBundleID = nil
        }
    }

    /// When all non-Biscotti mic users stop (>=1 -> 0 transition),
    /// begin auto-stop countdown regardless of how the recording started.
    private func handleAllMicUsersStopped() {
        guard case let .recording(meetingID) = runState else { return }
        beginAutoStopCountdown(meetingID: meetingID)
    }
}

// MARK: - Auto-stop countdown

extension AppCore {
    /// Cancels the active auto-stop countdown (if any) so recording
    /// continues. Called from both the notification action and the
    /// on-screen "Keep Recording" button.
    public func keepRecording() {
        if case let .recording(id) = runState {
            cancelAutoStopCountdown(meetingID: id)
        }
    }

    private func beginAutoStopCountdown(meetingID: UUID) {
        countdownTask?.cancel()

        let seconds = autoStopSeconds
        let sched = scheduler
        let notif = notifications

        // Publish observable state so the recording pane can render
        // the countdown card alongside the existing notification.
        autoStop = AutoStopState(
            meetingID: meetingID,
            deadline: Date().addingTimeInterval(TimeInterval(seconds)),
            total: TimeInterval(seconds)
        )

        countdownTask = Task { [weak self] in
            // Present a single static notification (no per-second updates).
            await notif.present(
                .stopCountdown(
                    meetingID: meetingID,
                    secondsRemaining: seconds
                )
            )

            do {
                try await sched.sleep(for: .seconds(seconds))
            } catch {
                return // cancelled (keepRecording or manual stop)
            }
            guard !Task.isCancelled else { return }

            // Timer reached 0 -- auto-stop
            guard let self else { return }
            await stopRecording()
        }
    }

    private func cancelAutoStopCountdown(meetingID: UUID) {
        countdownTask?.cancel()
        countdownTask = nil
        autoStop = nil
        // Fire-and-forget: removing the countdown notification is a
        // best-effort UI cleanup (remove pending + delivered banners).
        // If this races with quit-while-recording, the app terminates
        // before the notification is removed, which is acceptable --
        // the banner simply expires naturally on the next reboot or
        // notification-center clear.
        Task {
            await notifications.cancelCountdown(meetingID: meetingID)
        }
    }
}

// MARK: - Notification action handling

extension AppCore {
    private func consumeNotificationActions() async {
        for await action in notifications.actions() {
            switch action {
            case let .openAndRecord(eventKey):
                await recordDetectedEvent(eventKey: eventKey)

            case .join:
                // NOTE: Join URL opening is handled exclusively by the app
                // target's UNUserNotificationCenterDelegate (AppDelegate),
                // which reads the URL from userInfo and calls
                // NSWorkspace.shared.open(url) BEFORE the action reaches
                // this stream. AppCore intentionally does nothing here to
                // stay AppKit-free and testable. If the delegate is ever
                // refactored to only call handleResponseValues (removing
                // its direct URL open), this case must be updated to open
                // the URL or forward to a callback.
                break

            case .keepRecording:
                keepRecording()
                route = .recording
            }
        }
    }
}

// MARK: - Calendar-start timers

extension AppCore {
    private func scheduleCalendarTimers() {
        // Cancel all existing timers
        for (_, task) in calendarTimerTasks {
            task.cancel()
        }
        calendarTimerTasks.removeAll()

        for event in upcoming where event.isMeetingLike {
            let delay = event.start.timeIntervalSinceNow
            guard delay > 0 else { continue } // already started

            let key = event.id
            let sched = scheduler
            calendarTimerTasks[key] = Task { [weak self] in
                do {
                    try await sched.sleep(for: .seconds(delay))
                } catch {
                    return // cancelled
                }
                guard let self, !Task.isCancelled else { return }
                await self.handleCalendarTimerFired(event: event)
            }
        }
    }

    private func handleCalendarTimerFired(
        event: CalendarEvent
    ) async {
        // Suppress if already recording
        guard runState == .idle || runState == .detectedPending
        else { return }

        lastCalendarNotificationDate = Date()

        await notifications.present(
            .meetingStarting(
                eventKey: event.id,
                title: event.title,
                joinURL: event.conferenceURL
            )
        )
    }

    /// Mirrors `calendar.upcoming` into `self.upcoming` and reschedules
    /// calendar-start timers whenever the upstream changes.
    ///
    /// NOTE: The `[weak self]` closure captures self weakly, but the
    /// `while let self` loop holds a strong reference for the duration
    /// of each iteration. If `calendar.upcoming` never changes, the
    /// task blocks in `withCheckedContinuation` holding self strongly.
    /// This is acceptable because AppCore is process-lifetime -- it is
    /// never deallocated while the app is running.
    private func startUpcomingMirrorTask() {
        upcomingMirrorTask?.cancel()
        upcomingMirrorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // Register tracking on the calendar's upcoming property.
                // onChange fires when the property changes; we then read
                // the new value on the MainActor.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.calendar.upcoming
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                upcoming = calendar.upcoming
                scheduleCalendarTimers()
            }
        }
    }

    /// Fires at each wall-clock minute boundary to update `minuteTick`.
    ///
    /// Computes the delay to the next :00 second mark, sleeps via the
    /// scheduler seam (deterministic in tests), then reschedules. The
    /// `minuteTick` update triggers `displayedUpcoming` recomputation
    /// and re-renders any view reading relative-time labels from it.
    private func startMinuteTickTask() {
        minuteTickTask?.cancel()
        let sched = scheduler
        minuteTickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // Compute delay to the next minute boundary.
                let now = Date()
                let cal = Foundation.Calendar.current
                let nextMinute = cal.nextDate(
                    after: now,
                    matching: DateComponents(second: 0),
                    matchingPolicy: .nextTime
                ) ?? now.addingTimeInterval(60)
                let delay = max(
                    nextMinute.timeIntervalSince(now), 0.1
                )

                do {
                    try await sched.sleep(
                        for: .milliseconds(Int(delay * 1000))
                    )
                } catch {
                    return // cancelled
                }
                guard !Task.isCancelled else { return }
                minuteTick = Date()
            }
        }
    }

    /// Test-only: directly sets `minuteTick` to a specific date so
    /// tests can verify filtering/label recomputation without real delays.
    package func setMinuteTick(_ date: Date) {
        minuteTick = date
    }
}

// MARK: - Association

extension AppCore {
    /// Fetches calendar events near a given date for the association
    /// picker. Delegates to `CalendarService.eventsNear(_:)` which
    /// uses a +/- 1.5h window and caches DTOs for snapshot resolution.
    public func eventsNear(_ date: Date) async -> [CalendarEvent] {
        await calendar.eventsNear(date)
    }

    /// Corrects the calendar association for a meeting. Pass `nil` to
    /// remove the association entirely.
    ///
    /// Non-destructive: fetches/builds the new snapshot FIRST. Only
    /// after success does it clear the old association and persist the
    /// new one. A failed lookup leaves the existing association intact.
    public func correctAssociation(
        meetingID: UUID,
        eventKey: String?
    ) async {
        do {
            if let eventKey {
                // Fetch the new snapshot BEFORE clearing the old one.
                // If this fails, the existing association is preserved.
                guard let input = await calendar.snapshot(forKey: eventKey)
                else {
                    logger.warning(
                        "Association correction: snapshot lookup failed for key \(eventKey); existing association preserved"
                    )
                    return
                }
                try await store.clearSnapshot(for: meetingID)
                try await store.setParticipants(
                    [], organizer: nil, for: meetingID
                )
                try await persistSnapshot(input, for: meetingID)
            } else {
                // Explicit unlink: clear the association.
                try await store.clearSnapshot(for: meetingID)
                try await store.setParticipants(
                    [], organizer: nil, for: meetingID
                )
            }
        } catch {
            logger.error("Association correction failed: \(error)")
        }
    }

    private func associateEvent(
        _ event: CalendarEvent,
        with meetingID: UUID
    ) async {
        guard let input = await calendar.snapshot(forKey: event.id)
        else { return }

        do {
            try await persistSnapshot(input, for: meetingID)
        } catch {
            logger.error("Calendar association failed: \(error)")
        }
    }

    /// Builds a `CalendarSnapshot` from a `CalendarSnapshotInput`, persists
    /// it and any associated participants for the given meeting.
    ///
    /// NOTE: Field-by-field coupling -- `CalendarSnapshotInput` and
    /// `CalendarSnapshot` live in separate modules (Calendar vs DataStore)
    /// with deliberately no shared dependency. When either type gains a
    /// new field, this mapping must be updated manually.
    private func persistSnapshot(
        _ input: CalendarSnapshotInput,
        for meetingID: UUID
    ) async throws {
        let snapshot = CalendarSnapshot(
            eventIdentifier: input.eventIdentifier,
            calendarItemIdentifier: input.calendarItemIdentifier,
            calendarItemExternalIdentifier: input
                .calendarItemExternalIdentifier,
            occurrenceStartDate: input.occurrenceStartDate,
            compositeKey: input.compositeKey,
            title: input.title,
            startDate: input.startDate,
            endDate: input.endDate,
            isAllDay: input.isAllDay,
            location: input.location,
            url: input.url,
            timeZone: input.timeZone,
            eventNotes: input.eventNotes,
            status: input.status,
            availability: input.availability,
            calendarTitle: input.calendarTitle,
            calendarColorHex: input.calendarColorHex,
            conferenceURL: input.conferenceURL,
            conferencePlatform: input.conferencePlatform
        )

        try await store.setSnapshot(snapshot, for: meetingID)

        var personIDs: [UUID] = []
        var organizerID: UUID?

        if let org = input.organizer {
            let pid = try await store.findOrCreatePerson(
                name: org.name ?? "Unknown",
                email: org.email
            )
            organizerID = pid
        }
        for attendee in input.attendees {
            let pid = try await store.findOrCreatePerson(
                name: attendee.name ?? "Unknown",
                email: attendee.email
            )
            personIDs.append(pid)
        }

        try await store.setParticipants(
            personIDs,
            organizer: organizerID,
            for: meetingID
        )

        // Apply the event title to the meeting (unless the user
        // has manually edited the title).
        if !input.title.isEmpty {
            try await store.applyEventTitle(
                input.title, for: meetingID
            )
        }
    }
}

// MARK: - Delete

extension AppCore {
    /// Deletes a meeting's on-disk recording files and its DataStore row.
    ///
    /// **Order:** files are deleted first (best-effort), then the DB row.
    /// Rationale: if the DB delete fails after files are removed, the
    /// meeting row lingers but its audio refs already show `isPresent ==
    /// false` on next reconciliation -- a recoverable state. The reverse
    /// (DB deleted, files orphaned) is unrecoverable without a separate
    /// storage scan.
    ///
    /// After deletion, reloads summaries, computes the nearest neighbor
    /// in the active order (browse or search), and selects it so the
    /// user sees the next meeting instead of a dead detail pane.
    public func deleteMeeting(meetingID: UUID) async {
        // Recording guard is in deleteSingleMeetingInternal; if it
        // refuses (returns false), return early so route/selection
        // stay unchanged (e.g. route stays .recording).
        let deleted = await deleteSingleMeetingInternal(meetingID: meetingID)
        guard deleted else { return }

        // 4. Compute neighbor before refresh.
        let activeOrder: [UUID] = meetingsQuery.isEmpty
            ? summaries.map(\.id)
            : meetingsResults.map(\.id)
        let neighbor = Self.neighborID(
            in: activeOrder, removing: meetingID
        )

        // 5. Refresh UI.
        await reloadSummaries()
        if !meetingsQuery.isEmpty {
            await rerunMeetingsSearchNow()
        }

        // 6. Validate neighbor still exists, else empty (placeholder).
        let refreshed: [UUID] = meetingsQuery.isEmpty
            ? summaries.map(\.id)
            : meetingsResults.map(\.id)
        if let neighbor, refreshed.contains(neighbor) {
            meetingsSelection = [neighbor]
        } else {
            meetingsSelection = []
        }
        route = .meetings
    }

    /// Batch-deletes multiple meetings' on-disk recording files and DB rows.
    ///
    /// Computes the post-delete neighbor from the first selected meeting in
    /// the active order (browse or search), then deletes all selected
    /// meetings. Resilient: individual failures are logged but do not abort
    /// the batch.
    public func deleteMeetings(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }

        // Compute a surviving neighbor: the first element after the last
        // deleted item in active order that is NOT itself being deleted,
        // falling back to the first element before the first deleted item.
        let activeOrder: [UUID] = meetingsQuery.isEmpty
            ? summaries.map(\.id)
            : meetingsResults.map(\.id)
        let neighbor: UUID? = Self.batchNeighborID(
            in: activeOrder, removing: ids
        )

        // Delete each meeting (files + DB row). Skip actively-recording
        // meetings (the single-delete guard handles this per call).
        var deletedAny = false
        for id in ids {
            let deleted = await deleteSingleMeetingInternal(meetingID: id)
            if deleted { deletedAny = true }
        }

        // If every requested id was refused, return early without
        // changing route or selection.
        guard deletedAny else { return }

        // Refresh UI.
        await reloadSummaries()
        if !meetingsQuery.isEmpty {
            await rerunMeetingsSearchNow()
        }

        // Resolve post-delete selection.
        let refreshed: [UUID] = meetingsQuery.isEmpty
            ? summaries.map(\.id)
            : meetingsResults.map(\.id)
        if let neighbor, refreshed.contains(neighbor) {
            meetingsSelection = [neighbor]
        } else {
            meetingsSelection = []
        }
        route = .meetings
    }

    /// Deletes a single meeting's files and DB row without touching
    /// selection or refreshing summaries. Used by both `deleteMeeting`
    /// and `deleteMeetings` to avoid duplicated file/DB logic.
    ///
    /// - Returns: `true` if the meeting was deleted, `false` if deletion
    ///   was refused (e.g. the meeting is actively recording).
    @discardableResult
    private func deleteSingleMeetingInternal(meetingID: UUID) async -> Bool {
        // Guard: refuse to delete a meeting that is actively recording.
        if recording.state.isRecording,
           recording.state.meetingID == meetingID
        {
            logger.warning(
                "deleteSingleMeetingInternal: refusing to delete actively-recording meeting \(meetingID)"
            )
            return false
        }

        // 1. Collect on-disk paths from the store BEFORE deleting the row.
        let filePaths: [String]
        do {
            filePaths = try await store.audioFilePaths(
                meetingID: meetingID
            )
        } catch {
            filePaths = []
            logger.warning(
                "deleteSingleMeetingInternal: failed to read audio paths for \(meetingID): \(error)"
            )
        }

        // 2. Delete files best-effort (missing files are fine).
        deleteRecordingFiles(filePaths)

        // 3. Delete the DB row.
        do {
            try await store.delete(meetingID: meetingID)
        } catch {
            logger.error(
                "deleteSingleMeetingInternal: DB delete failed for \(meetingID): \(error)"
            )
        }

        return true
    }

    /// The element AFTER `id` (next/older), or the one BEFORE if `id`
    /// was last, or nil if `id` was the only element / not found.
    /// Pure and unit-tested.
    static func neighborID(
        in ordered: [UUID], removing id: UUID
    ) -> UUID? {
        guard let idx = ordered.firstIndex(of: id) else { return nil }
        if idx + 1 < ordered.count { return ordered[idx + 1] }
        if idx - 1 >= 0 { return ordered[idx - 1] }
        return nil
    }

    /// Finds the best surviving neighbor after a batch removal.
    ///
    /// Prefers the nearest survivor after the last removed index, then
    /// the nearest before the first removed index, then any survivor at
    /// all (handles non-contiguous gaps like ⌘-click skip-selection).
    static func batchNeighborID(
        in ordered: [UUID], removing ids: Set<UUID>
    ) -> UUID? {
        guard !ids.isEmpty else { return nil }
        let removedIndices = ordered.indices.filter { ids.contains(ordered[$0]) }
        guard let firstRemoved = removedIndices.first,
              let lastRemoved = removedIndices.last
        else { return nil }

        // Prefer: nearest after the last removed element
        let afterSlice = ordered.suffix(from: min(lastRemoved + 1, ordered.count))
        if let neighbor = afterSlice.first(where: { !ids.contains($0) }) {
            return neighbor
        }
        // Then: nearest before the first removed element
        let beforeSlice = ordered.prefix(firstRemoved)
        if let neighbor = beforeSlice.last(where: { !ids.contains($0) }) {
            return neighbor
        }
        // Fallback: any survivor (covers non-contiguous gaps)
        return ordered.first(where: { !ids.contains($0) })
    }

    /// Best-effort removal of audio files and their per-meeting directory.
    private func deleteRecordingFiles(_ paths: [String]) {
        let fileManager = FileManager.default
        var parentDirectories: Set<String> = []

        for path in paths {
            let url = URL(fileURLWithPath: path)
            do {
                try fileManager.removeItem(at: url)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                && error.code == NSFileNoSuchFileError
            {
                // File already gone -- not an error.
            } catch {
                logger.warning(
                    "deleteMeeting: failed to remove \(path): \(error)"
                )
            }
            parentDirectories.insert(
                url.deletingLastPathComponent().path
            )
        }

        // Remove empty per-meeting directories.
        for dirPath in parentDirectories {
            let dirURL = URL(fileURLWithPath: dirPath)
            if let contents = try? fileManager.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: nil
            ), contents.isEmpty {
                try? fileManager.removeItem(at: dirURL)
            }
        }
    }
}

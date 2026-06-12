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

    // MARK: - Meetings screen state

    /// The selected meeting shown in the detail pane, or nil (placeholder).
    public private(set) var meetingsSelection: UUID?

    /// The search query. Empty = browse mode, non-empty = search mode.
    public private(set) var meetingsQuery: String = ""

    /// The search results (flat, ranked). Empty when in browse mode.
    public private(set) var meetingsResults: [SearchHit] = []

    /// Whether a search query is currently in flight.
    public private(set) var isSearchingMeetings = false

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

    /// Whether the active recording was started due to detection (vs manual).
    /// Determines whether auto-stop applies.
    private var isDetectionDriven = false

    /// The bundle ID of the detected app that triggered the current recording.
    private var activeDetectedBundleID: String?

    /// Timestamp of the most recent calendar-start notification, for de-dup.
    private var lastCalendarNotificationDate: Date?

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

    /// Auto-stop countdown duration in seconds.
    private let autoStopSeconds = 15

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

        // Check onboarding gate
        logger.info("onLaunch: reading settings")
        let onboardingComplete: Bool
        do {
            let settings = try await store.settings()
            onboardingComplete = settings.onboardingComplete
        } catch {
            onboardingComplete = false
        }

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
                end: now.addingTimeInterval(24 * 60 * 60)
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
    public func startRecording(eventKey: String? = nil) async {
        // One-recording-at-a-time guard
        guard runState == .idle || runState == .detectedPending else {
            return
        }

        // Resolve the calendar event before starting
        let resolvedEvent: CalendarEvent? = if let eventKey {
            calendar.event(forKey: eventKey)
        } else {
            calendar.bestMatch(at: Date())
        }

        await recording.start()
        guard recording.state.isRecording,
              let meetingID = recording.state.meetingID
        else {
            return
        }

        runState = .recording(meetingID)
        route = .recording

        // Associate with the calendar event if resolved
        if let resolvedEvent {
            await associateEvent(resolvedEvent, with: meetingID)
        }
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

        // Clear detection tracking
        isDetectionDriven = false
        activeDetectedBundleID = nil

        await reloadSummaries()
        runState = .idle
        select(meetingID)

        pendingTranscriptionTask = Task { @MainActor [transcription] in
            await transcription.transcribe(meetingID: meetingID)
        }

        return meetingID
    }

    /// Records a detected event (from a notification action). Sets
    /// detection-driven flag and starts recording.
    public func recordDetectedEvent(eventKey: String?) async {
        isDetectionDriven = true
        await startRecording(eventKey: eventKey)
    }

    // MARK: - Navigation

    /// Opens a specific meeting from OUTSIDE the list (menu bar, Home recent,
    /// stopRecording, "open this meeting"). Clears any active search, sets
    /// selection, and routes to the Meetings screen.
    public func select(_ meetingID: UUID) {
        cancelMeetingsSearch()
        meetingsQuery = ""
        meetingsResults = []
        meetingsSelection = meetingID
        route = .meetings
    }

    /// Row selection from WITHIN the list (`List(selection:)` setter).
    /// Preserves the current mode (keeps the query if searching).
    /// nil = placeholder (no selection).
    public func selectFromList(_ meetingID: UUID?) {
        meetingsSelection = meetingID
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
    public func reloadSummaries() async {
        do {
            summaries = try await store.meetingSummaries()
        } catch {
            summaries = []
        }
    }

    // MARK: - Test support

    /// Waits for any pending fire-and-forget transcription task spawned by
    /// `stopRecording()` to finish.
    package func awaitPendingTranscription() async {
        await pendingTranscriptionTask?.value
        pendingTranscriptionTask = nil
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

    /// Always selects the top search result (or nil if no results).
    /// Ensures the user sees the first match after every search, rather
    /// than a stale selection that might be below the fold.
    private func autoSelectTopResult() {
        meetingsSelection = meetingsResults.first?.id
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
            }
        }
    }

    private func handleDetectionStarted(
        app: DetectedApp
    ) async {
        // Suppress if already recording
        if case .recording = runState { return }

        // Suppress if a calendar notification was recently presented (de-dup)
        if let lastCal = lastCalendarNotificationDate,
           Date().timeIntervalSince(lastCal) < calendarSuppressionInterval
        {
            logger.debug(
                "Suppressing ad-hoc detection; calendar prompt within window"
            )
            return
        }

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
            return
        }

        // If recording and detection-driven, begin auto-stop
        if case let .recording(meetingID) = runState,
           isDetectionDriven,
           activeDetectedBundleID == app.bundleID
        {
            beginAutoStopCountdown(meetingID: meetingID)
        }
    }
}

// MARK: - Auto-stop countdown

extension AppCore {
    private func beginAutoStopCountdown(meetingID: UUID) {
        countdownTask?.cancel()

        let seconds = autoStopSeconds
        let sched = scheduler
        let notif = notifications

        countdownTask = Task { [weak self] in
            await notif.present(
                .stopCountdown(
                    meetingID: meetingID,
                    secondsRemaining: seconds
                )
            )

            for remaining in stride(
                from: seconds - 1, through: 0, by: -1
            ) {
                do {
                    try await sched.sleep(for: .seconds(1))
                } catch {
                    return // cancelled
                }
                guard !Task.isCancelled else { return }

                if remaining > 0 {
                    await notif.updateCountdown(
                        meetingID: meetingID,
                        secondsRemaining: remaining
                    )
                }
            }

            // Timer reached 0 -- auto-stop
            guard let self, !Task.isCancelled else { return }
            await stopRecording()
        }
    }

    private func cancelAutoStopCountdown(meetingID: UUID) {
        countdownTask?.cancel()
        countdownTask = nil
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

            case let .keepRecording(meetingID):
                cancelAutoStopCountdown(meetingID: meetingID)
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
        // Guard: refuse to delete a meeting that is actively recording.
        // Deleting files mid-write would corrupt the recording. Callers
        // should stop the recording first.
        if recording.state.isRecording,
           recording.state.meetingID == meetingID
        {
            logger.warning(
                "deleteMeeting: refusing to delete actively-recording meeting \(meetingID)"
            )
            return
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
                "deleteMeeting: failed to read audio paths for \(meetingID): \(error)"
            )
        }

        // 2. Delete files best-effort (missing files are fine).
        deleteRecordingFiles(filePaths)

        // 3. Delete the DB row (cascade handles snapshot, audio refs,
        //    transcripts).
        do {
            try await store.delete(meetingID: meetingID)
        } catch {
            logger.error(
                "deleteMeeting: DB delete failed for \(meetingID): \(error)"
            )
        }

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

        // 6. Validate neighbor still exists, else nil (placeholder).
        let refreshed: [UUID] = meetingsQuery.isEmpty
            ? summaries.map(\.id)
            : meetingsResults.map(\.id)
        meetingsSelection = neighbor.flatMap {
            refreshed.contains($0) ? $0 : nil
        }
        route = .meetings
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

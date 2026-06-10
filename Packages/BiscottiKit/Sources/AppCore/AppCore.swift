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

    /// The sidebar meeting list (newest first).
    public private(set) var summaries: [MeetingSummary] = []

    /// Meeting-like upcoming calendar events, mirrored from CalendarService.
    public private(set) var upcoming: [CalendarEvent] = []

    /// The current run state. UI + menu bar observe this.
    public private(set) var runState: RunState = .idle

    /// Saved route for Search "Back" restoration.
    public private(set) var searchReturnRoute: Route?

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

    private let summaryLimit: Int
    private let scheduler: any AppScheduler

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

    /// The fire-and-forget transcription task spawned by `stopRecording()`.
    package var pendingTranscriptionTask: Task<Void, Never>?

    /// Auto-stop countdown duration in seconds.
    private let autoStopSeconds = 15

    /// De-dup suppression window for ad-hoc detections after calendar prompts.
    private let calendarSuppressionInterval: TimeInterval = 600 // 10 minutes

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
        scheduler: any AppScheduler = LiveAppScheduler(),
        summaryLimit: Int = 50
    ) {
        self.store = store
        self.permissions = permissions
        self.recording = recording
        self.transcription = transcription
        self.calendar = calendar
        self.detector = detector
        self.notifications = notifications
        self.scheduler = scheduler
        self.summaryLimit = summaryLimit
    }

    // MARK: - Lifecycle

    /// Called once at app launch. Recovers orphaned recordings, checks
    /// onboarding state, starts background services, and loads the sidebar.
    public func onLaunch() async {
        await recording.recoverOrphans()

        // Check onboarding gate
        let onboardingComplete: Bool
        do {
            let settings = try await store.settings()
            onboardingComplete = settings.onboardingComplete
        } catch {
            onboardingComplete = false
        }

        if !onboardingComplete {
            route = .onboarding
            await reloadSummaries()
            return
        }

        route = .home

        // Start calendar observation and refresh upcoming
        calendar.startObserving()
        let now = Date()
        await calendar.refreshUpcoming(
            window: DateInterval(
                start: now,
                end: now.addingTimeInterval(24 * 60 * 60)
            )
        )
        upcoming = calendar.upcoming

        // Start detection
        detector.start()

        // Start consumer tasks
        detectorConsumerTask = Task { [weak self] in
            await self?.consumeDetectorEvents()
        }
        notificationConsumerTask = Task { [weak self] in
            await self?.consumeNotificationActions()
        }

        // Schedule calendar-start timers
        scheduleCalendarTimers()
        startUpcomingMirrorTask()

        await reloadSummaries()
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
        route = .meeting(meetingID)

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

    /// Selects a meeting in the sidebar and routes to its detail.
    public func select(_ meetingID: UUID) {
        route = .meeting(meetingID)
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

    /// Enters search mode, saving the current route for Back restoration.
    public func presentSearch() {
        searchReturnRoute = route
        route = .search
    }

    /// Exits search mode, restoring the saved route.
    public func dismissSearch() {
        route = searchReturnRoute ?? .home
        searchReturnRoute = nil
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
        calendar.startObserving()
        let now = Date()
        await calendar.refreshUpcoming(
            window: DateInterval(
                start: now,
                end: now.addingTimeInterval(24 * 60 * 60)
            )
        )
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

    // MARK: - Association correction

    /// Corrects the calendar association for a meeting. Pass `nil` to
    /// remove the association entirely.
    public func correctAssociation(
        meetingID: UUID,
        eventKey: String?
    ) async {
        do {
            try await store.clearSnapshot(for: meetingID)
            try await store.setParticipants(
                [], organizer: nil, for: meetingID
            )

            if let eventKey,
               let input = await calendar.snapshot(forKey: eventKey)
            {
                try await persistSnapshot(input, for: meetingID)
            }
        } catch {
            logger.error("Association correction failed: \(error)")
        }
    }

    // MARK: - Data refresh

    /// Reloads the sidebar summaries from the store.
    public func reloadSummaries() async {
        do {
            summaries = try await store.meetingSummaries(
                limit: summaryLimit
            )
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
}

// MARK: - Association

extension AppCore {
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
    }
}

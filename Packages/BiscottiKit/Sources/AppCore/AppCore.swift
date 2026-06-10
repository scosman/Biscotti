import Calendar
import DataStore
import Foundation
import MeetingCatalog
import os
import Permissions
import Recording
import TranscriptionService

/// Thin MVP coordinator that wires Recording, TranscriptionService,
/// CalendarService, Permissions, and DataStore into a single observable
/// surface for the UI.
///
/// The UI observes `route`, `summaries`, `upcoming`, and `runState` to
/// drive navigation and lists. Heavy work is delegated to the injected
/// services; this class owns coordination logic (launch recovery,
/// start/stop sequencing, auto-transcribe on stop, routing, C4
/// auto-association).
@MainActor @Observable
public final class AppCore {
    // MARK: - Published state

    /// The current navigation destination.
    public private(set) var route: Route = .home

    /// The sidebar meeting list (newest first).
    public private(set) var summaries: [MeetingSummary] = []

    /// Meeting-like upcoming calendar events, mirrored from CalendarService.
    public private(set) var upcoming: [CalendarEvent] = []

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

    // MARK: - Private

    /// Maximum number of meetings to load for the sidebar. Capped to avoid
    /// unbounded memory growth; older meetings are still queryable via search.
    private let summaryLimit: Int

    /// The fire-and-forget transcription task spawned by `stopRecording()`.
    package var pendingTranscriptionTask: Task<Void, Never>?

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
        summaryLimit: Int = 50
    ) {
        self.store = store
        self.permissions = permissions
        self.recording = recording
        self.transcription = transcription
        self.calendar = calendar
        self.summaryLimit = summaryLimit
    }

    // MARK: - Lifecycle

    /// Called once at app launch. Recovers orphaned recordings, checks
    /// onboarding state, refreshes calendar, and loads the sidebar.
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

        await reloadSummaries()
    }

    // MARK: - Recording coordination

    /// Starts a new recording session, optionally associated with a
    /// specific calendar event.
    ///
    /// - Parameter eventKey: Composite key for explicit association (from
    ///   an `.event(key)` preview or notification). `nil` = auto-match via
    ///   `calendar.bestMatch(at: now)` (C4).
    public func startRecording(eventKey: String? = nil) async {
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
        guard let meetingID = await recording.stop() else {
            return nil
        }

        await reloadSummaries()
        route = .meeting(meetingID)

        pendingTranscriptionTask = Task { @MainActor [transcription] in
            await transcription.transcribe(meetingID: meetingID)
        }

        return meetingID
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
            try await store.setParticipants([], organizer: nil, for: meetingID)

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
            summaries = try await store.meetingSummaries(limit: summaryLimit)
        } catch {
            summaries = []
        }
    }

    // MARK: - Private

    private func associateEvent(
        _ event: CalendarEvent,
        with meetingID: UUID
    ) async {
        guard let input = await calendar.snapshot(forKey: event.id)
        else { return }

        do {
            try await persistSnapshot(input, for: meetingID)
        } catch {
            // Non-fatal: recording continues without calendar context.
            logger.error("Calendar association failed: \(error)")
        }
    }

    /// Builds a `CalendarSnapshot` from a `CalendarSnapshotInput`, persists
    /// it and any associated participants for the given meeting.
    ///
    /// NOTE: Field-by-field coupling — `CalendarSnapshotInput` and
    /// `CalendarSnapshot` live in separate modules (Calendar vs DataStore)
    /// with deliberately no shared dependency. When either type gains a
    /// new field, this mapping must be updated manually. A compile error
    /// in `CalendarSnapshot.init` will catch added fields, but removed
    /// or renamed fields require review.
    private func persistSnapshot(
        _ input: CalendarSnapshotInput,
        for meetingID: UUID
    ) async throws {
        let snapshot = CalendarSnapshot(
            eventIdentifier: input.eventIdentifier,
            calendarItemIdentifier: input.calendarItemIdentifier,
            calendarItemExternalIdentifier: input.calendarItemExternalIdentifier,
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

    // MARK: - Test support

    /// Waits for any pending fire-and-forget transcription task spawned by
    /// `stopRecording()` to finish.
    package func awaitPendingTranscription() async {
        await pendingTranscriptionTask?.value
        pendingTranscriptionTask = nil
    }
}

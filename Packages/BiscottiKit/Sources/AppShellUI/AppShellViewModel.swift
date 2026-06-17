import AppCore
import AppKit
import Calendar
import DataStore
import DesignSystem
import Foundation
import HomeUI
import MeetingDetailUI
import MeetingListUI
import OnboardingUI
import RecordingUI
import SettingsUI

/// View model for the app shell (NavigationSplitView wrapper).
///
/// Owns the sidebar state (upcoming, settings), the toolbar recording
/// button state, and routes the detail pane based on `AppCore.route`.
///
/// Child view models are created once and cached so they survive SwiftUI
/// re-evaluations.
@MainActor @Observable
public final class AppShellViewModel {
    private let core: AppCore

    // MARK: - Stable child view models

    /// The meeting-list view model (created once, never replaced).
    public let meetingListViewModel: MeetingListViewModel

    /// The recording-screen view model (created once, never replaced).
    public let recordingViewModel: RecordingViewModel

    /// The home view model (created once, never replaced).
    public let homeViewModel: HomeViewModel

    /// The settings view model (created once, never replaced).
    public let settingsViewModel: SettingsViewModel

    /// The onboarding view model (created once, never replaced).
    public let onboardingViewModel: OnboardingViewModel

    /// Cached meeting-detail view model, keyed by meeting ID.
    private var cachedDetailMeetingID: UUID?
    private var cachedDetailViewModel: MeetingDetailViewModel?

    /// Cached event-preview view model, keyed by event composite key.
    private var cachedEventPreviewKey: String?
    private var cachedEventPreviewViewModel: EventPreviewViewModel?

    public init(core: AppCore) {
        self.core = core
        meetingListViewModel = MeetingListViewModel(core: core)
        recordingViewModel = RecordingViewModel(core: core)
        homeViewModel = HomeViewModel(
            core: core,
            urlOpener: { NSWorkspace.shared.open($0) }
        )
        settingsViewModel = SettingsViewModel(core: core)
        onboardingViewModel = OnboardingViewModel(core: core)
    }

    /// Returns a stable `MeetingDetailViewModel` for the given meeting ID.
    /// Re-creates only when the ID changes.
    public func meetingDetailViewModel(
        for meetingID: UUID
    ) -> MeetingDetailViewModel {
        if let cached = cachedDetailViewModel,
           cachedDetailMeetingID == meetingID
        {
            return cached
        }
        let viewModel = MeetingDetailViewModel(
            core: core, meetingID: meetingID,
            urlOpener: { url in NSWorkspace.shared.open(url) }
        )
        cachedDetailMeetingID = meetingID
        cachedDetailViewModel = viewModel
        return viewModel
    }

    /// Returns a stable `EventPreviewViewModel` for the given event key.
    /// Re-creates only when the key changes.
    public func eventPreviewViewModel(
        for eventKey: String
    ) -> EventPreviewViewModel {
        if let cached = cachedEventPreviewViewModel,
           cachedEventPreviewKey == eventKey
        {
            return cached
        }
        let viewModel = EventPreviewViewModel(
            core: core,
            eventKey: eventKey,
            urlOpener: { url in NSWorkspace.shared.open(url) }
        )
        cachedEventPreviewKey = eventKey
        cachedEventPreviewViewModel = viewModel
        return viewModel
    }

    /// Whether the onboarding wizard is active (full-window takeover).
    public var showOnboarding: Bool {
        core.route == .onboarding
    }

    // MARK: - Recording state (toolbar button + sidebar)

    /// Whether a recording is currently in progress.
    public var isRecording: Bool {
        core.recording.state.isRecording
    }

    /// Formatted elapsed time for the toolbar recording button (e.g. "1:53"
    /// or "1:02:14" for recordings over an hour).
    public var recordingElapsedText: String {
        Self.formatElapsed(core.recording.state.elapsed)
    }

    /// The title of the meeting currently being recorded, for the sidebar
    /// "RECORDING NOW" row. Falls back to "Untitled Meeting" when not
    /// recording or when the summary is not yet loaded.
    public var recordingMeetingTitle: String {
        Self.deriveRecordingMeetingTitle(
            meetingID: core.recording.state.meetingID,
            summaries: core.summaries
        )
    }

    /// Pure derivation of the recording meeting title from meeting ID and
    /// summaries. Extracted for testability.
    nonisolated static func deriveRecordingMeetingTitle(
        meetingID: UUID?,
        summaries: [MeetingSummary]
    ) -> String {
        guard let id = meetingID,
              let summary = summaries.first(where: { $0.id == id })
        else {
            return "Untitled Meeting"
        }
        return summary.title
    }

    /// Formats a time interval as "M:SS" (under an hour) or "H:MM:SS".
    nonisolated static func formatElapsed(_ elapsed: TimeInterval) -> String {
        let totalSeconds = Int(elapsed)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Upcoming meeting-like calendar events for the sidebar (capped at 6).
    /// Uses `displayedUpcoming` which filters out ended events and
    /// refreshes every minute via the minute-tick.
    public var upcomingEvents: [CalendarEvent] {
        Array(core.displayedUpcoming.prefix(6))
    }

    /// Whether the calendar has been authorized (shows/hides upcoming section).
    public var hasCalendarAccess: Bool {
        core.calendar.auth == .authorized
    }

    // MARK: - Detail routing

    /// The current route determining which detail view to show.
    public var route: Route {
        core.route
    }

    /// The currently selected meeting (for Meetings screen detail pane).
    public var meetingsSelection: UUID? {
        core.meetingsSelection
    }

    /// The current meetings search query (for two-way sync with toolbar).
    public var meetingsQuery: String {
        core.meetingsQuery
    }

    /// Whether the current route is Home (used to disable the toolbar Home button).
    public var isHome: Bool {
        core.route == .home
    }

    /// Token that increments when the search field should gain focus
    /// (e.g. Cmd+F). The view observes this via `.onChange`.
    public var searchFocusToken: UInt {
        core.searchFocusToken
    }

    // MARK: - Actions

    /// Starts a new recording session.
    public func startRecording() async {
        await core.startRecording()
    }

    /// Navigates to the recording screen (toolbar recording button tap).
    public func showRecording() {
        core.navigateToRecording()
    }

    /// Routes to Home.
    public func showHome() {
        core.showHome()
    }

    /// Routes to the Meetings screen (browse mode, keep selection).
    public func showMeetings() {
        core.showMeetings()
    }

    /// Routes to Settings.
    public func showSettings() {
        core.showSettings()
    }

    /// Requests focus on the search field (Cmd+F).
    public func focusSearch() {
        core.focusSearch()
    }

    /// Routes to an upcoming event preview.
    public func selectEvent(_ key: String) {
        core.selectEvent(key)
    }

    /// Forwards toolbar search text to AppCore's meetings search.
    public func setMeetingsQuery(_ query: String) {
        core.setMeetingsQuery(query)
    }

    /// Called on app launch to run recovery and load data.
    public func onLaunch() async {
        await core.onLaunch()
    }

    // MARK: - Time formatting for upcoming events

    /// Formats a CalendarEvent's start time as coarse relative text
    /// ("in 2 days", "in 5h", "in 12m") or "now".
    /// Delegates to `TimeFormatting.coarseRelativeTimeText` (shared helper).
    public static func timeText(
        for event: CalendarEvent,
        relativeTo now: Date = Date()
    ) -> String {
        TimeFormatting.coarseRelativeTimeText(event.start, relativeTo: now)
    }

    /// Formats a CalendarEvent's start time relative to the
    /// minute-tick, ensuring the label refreshes every minute.
    public func tickTimeText(for event: CalendarEvent) -> String {
        TimeFormatting.coarseRelativeTimeText(
            event.start, relativeTo: core.minuteTick
        )
    }
}

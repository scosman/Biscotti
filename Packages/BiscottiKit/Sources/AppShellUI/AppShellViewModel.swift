import AppCore
import AppKit
import Calendar
import DesignSystem
import Foundation
import HomeUI
import MeetingDetailUI
import MeetingListUI
import OnboardingUI
import RecordingUI
import SearchUI
import SettingsUI

/// View model for the app shell (NavigationSplitView wrapper).
///
/// Owns the sidebar state (Record button, recording indicator, upcoming,
/// settings) and routes the detail pane based on `AppCore.route`.
///
/// Child view models are created once and cached so they survive SwiftUI
/// re-evaluations.
@MainActor @Observable
public final class AppShellViewModel {
    private let core: AppCore

    // MARK: - Stable child view models

    /// The sidebar meeting-list view model (created once, never replaced).
    public let meetingListViewModel: MeetingListViewModel

    /// The recording-screen view model (created once, never replaced).
    public let recordingViewModel: RecordingViewModel

    /// The home view model (created once, never replaced).
    public let homeViewModel: HomeViewModel

    /// The search view model (created once, never replaced).
    public let searchViewModel: SearchViewModel

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

    /// The toolbar search text.
    public var searchText: String = ""

    public init(core: AppCore) {
        self.core = core
        meetingListViewModel = MeetingListViewModel(core: core)
        recordingViewModel = RecordingViewModel(core: core)
        homeViewModel = HomeViewModel(core: core)
        searchViewModel = SearchViewModel(core: core)
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
            core: core, meetingID: meetingID
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

    // MARK: - Sidebar state

    /// Whether the Record button should be disabled (recording in progress).
    public var recordButtonDisabled: Bool {
        core.recording.state.isRecording
    }

    /// Whether to show the recording indicator in the sidebar.
    public var showRecordingIndicator: Bool {
        core.recording.state.isRecording
    }

    /// Formatted elapsed time for the sidebar recording indicator.
    public var recordingElapsedText: String {
        let elapsed = core.recording.state.elapsed
        let totalSeconds = Int(elapsed)
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Upcoming meeting-like calendar events for the sidebar.
    public var upcomingEvents: [CalendarEvent] {
        core.upcoming
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

    // MARK: - Actions

    /// Starts a new recording session.
    public func startRecording() async {
        await core.startRecording()
    }

    /// Navigates to the recording screen (when tapping the recording indicator).
    public func showRecording() {
        core.navigateToRecording()
    }

    /// Routes to Home.
    public func showHome() {
        core.showHome()
    }

    /// Routes to Settings.
    public func showSettings() {
        core.showSettings()
    }

    /// Routes to an upcoming event preview.
    public func selectEvent(_ key: String) {
        core.selectEvent(key)
    }

    /// Called when the toolbar search text changes.
    public func onSearchTextChange(_ text: String) {
        if !text.isEmpty {
            core.presentSearch()
            searchViewModel.updateQuery(text)
        } else if core.route == .search {
            searchViewModel.updateQuery("")
            core.dismissSearch()
        }
    }

    /// Clears the search and restores the previous route.
    public func clearSearch() {
        searchText = ""
        searchViewModel.updateQuery("")
        core.dismissSearch()
    }

    /// Called on app launch to run recovery and load data.
    public func onLaunch() async {
        await core.onLaunch()
    }

    // MARK: - Time formatting for upcoming events

    /// Formats a CalendarEvent's start time as relative text.
    /// Delegates to `TimeFormatting.relativeTimeText` (shared helper).
    public static func timeText(
        for event: CalendarEvent,
        relativeTo now: Date = Date()
    ) -> String {
        TimeFormatting.relativeTimeText(event.start, relativeTo: now)
    }
}

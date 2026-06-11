import AppCore
import Calendar
import DataStore
import DesignSystem
import Foundation

/// View model for the Home screen.
///
/// Provides the welcome/start/upcoming/recent state and actions.
/// All data is derived from `AppCore` observable properties; no
/// direct DataStore queries.
@MainActor @Observable
public final class HomeViewModel {
    private let core: AppCore

    public init(core: AppCore) {
        self.core = core
    }

    // MARK: - State (derived from core)

    /// The upcoming meeting-like events to show as a preview list (max 5).
    /// Uses `displayedUpcoming` which filters out ended events.
    public var upcomingPreview: [CalendarEvent] {
        Array(core.displayedUpcoming.prefix(5))
    }

    /// The most recent meetings (max 4, newest-first).
    public var recentMeetings: [MeetingSummary] {
        Array(core.summaries.prefix(4))
    }

    /// Whether the Start Recording button should be disabled.
    public var startDisabled: Bool {
        core.runState != .idle
    }

    /// Calendar access state for empty/connect display.
    public var calendarAccess: CalendarAuthStatus {
        core.calendar.auth
    }

    /// Show "No meetings coming up" when authorized but no upcoming events
    /// (including events that have since ended).
    public var showNoUpcoming: Bool {
        calendarAccess == .authorized && upcomingPreview.isEmpty
    }

    /// Show "Connect your calendar" when not authorized.
    public var showConnectCalendar: Bool {
        calendarAccess != .authorized
    }

    /// Show the "No recordings yet" empty state when there are no meetings.
    public var showNoRecent: Bool {
        core.summaries.isEmpty
    }

    // MARK: - Actions

    /// Start a new recording session.
    public func startRecording() async {
        await core.startRecording()
    }

    /// Request calendar access (from the "Connect" empty state).
    public func requestCalendarAccess() async {
        _ = await core.calendar.requestAccess()
    }

    /// Select an upcoming event to preview its detail.
    public func selectEvent(_ key: String) {
        core.selectEvent(key)
    }

    /// Select a recent meeting to view its detail.
    public func selectMeeting(_ id: UUID) {
        core.select(id)
    }

    // MARK: - Formatting

    /// Formats a CalendarEvent's start time as relative ("in 12m") or "now".
    /// Delegates to `TimeFormatting.relativeTimeText` (shared helper).
    public nonisolated static func timeText(
        for event: CalendarEvent,
        relativeTo now: Date = Date()
    ) -> String {
        TimeFormatting.relativeTimeText(event.start, relativeTo: now)
    }

    /// Formats a CalendarEvent's start time relative to the
    /// minute-tick, ensuring the label refreshes every minute.
    public func tickTimeText(for event: CalendarEvent) -> String {
        TimeFormatting.relativeTimeText(
            event.start, relativeTo: core.minuteTick
        )
    }

    /// Builds the second-line text for a recent meeting row (date + duration).
    /// Uses `TimeFormatting.meetingSecondLine` so it is byte-identical
    /// to the sidebar's meeting rows.
    public static func recentSecondLine(
        for meeting: MeetingSummary
    ) -> String {
        TimeFormatting.meetingSecondLine(
            date: meeting.date,
            duration: meeting.recordingDuration
        )
    }
}

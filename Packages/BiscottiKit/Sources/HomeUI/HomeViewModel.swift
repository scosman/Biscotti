import AppCore
import Calendar
import DataStore
import DesignSystem
import Foundation

/// View model for the Home screen.
///
/// Provides the welcome/start/upcoming preview state and actions.
/// All data is derived from `AppCore` observable properties; no
/// direct DataStore queries.
@MainActor @Observable
public final class HomeViewModel {
    private let core: AppCore

    public init(core: AppCore) {
        self.core = core
    }

    // MARK: - State (derived from core)

    /// The upcoming meeting-like events to show as a preview list (max 3).
    public var upcomingPreview: [CalendarEvent] {
        Array(core.upcoming.prefix(3))
    }

    /// Whether the Start Recording button should be disabled.
    public var startDisabled: Bool {
        core.runState != .idle
    }

    /// Calendar access state for empty/connect display.
    public var calendarAccess: CalendarAuthStatus {
        core.calendar.auth
    }

    /// Show "No meetings coming up" when authorized but no upcoming events.
    public var showNoUpcoming: Bool {
        calendarAccess == .authorized && upcomingPreview.isEmpty
    }

    /// Show "Connect your calendar" when not authorized.
    public var showConnectCalendar: Bool {
        calendarAccess != .authorized
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

    // MARK: - Formatting

    /// Formats a CalendarEvent's start time as relative ("in 12m") or "now".
    /// Delegates to `TimeFormatting.relativeTimeText` (shared helper).
    public nonisolated static func timeText(
        for event: CalendarEvent,
        relativeTo now: Date = Date()
    ) -> String {
        TimeFormatting.relativeTimeText(event.start, relativeTo: now)
    }
}

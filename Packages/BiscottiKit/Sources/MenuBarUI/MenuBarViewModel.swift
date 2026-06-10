import AppCore
import AppKit
import Calendar
import DataStore
import Foundation

/// View model for the `MenuBarExtra` content and label views.
///
/// Reads `AppCore` state (run state, upcoming events, recent meetings,
/// recording elapsed time) and projects it into display-ready values.
/// Actions delegate to `AppCore` methods.
@MainActor @Observable
public final class MenuBarViewModel {
    private let core: AppCore

    public init(core: AppCore) {
        self.core = core
    }

    // MARK: - Icon state

    /// The icon/label state for the MenuBarExtra.
    public enum IconState: Equatable {
        /// No recording, no imminent meeting.
        case idle
        /// A meeting-like event is within 2 hours.
        case nextMeeting(title: String, timeText: String)
        /// Recording is active.
        case recording
    }

    /// The current icon state, derived from core state.
    public var iconState: IconState {
        if case .recording = core.runState {
            return .recording
        }
        if core.recording.state.isRecording {
            return .recording
        }
        if let next = core.upcoming.first,
           Self.isWithin2Hours(next.start)
        {
            let title = Self.truncateTitle(
                next.title, maxLength: 20
            )
            let time = Self.relativeTimeText(next.start)
            return .nextMeeting(title: title, timeText: time)
        }
        return .idle
    }

    // MARK: - Body state

    /// Whether a recording is in progress.
    public var isRecording: Bool {
        core.recording.state.isRecording
    }

    /// Elapsed recording time formatted as "MM:SS".
    public var elapsedText: String {
        Self.formatElapsed(core.recording.state.elapsed)
    }

    /// The next 2 upcoming meeting-like events.
    public var upcomingEvents: [CalendarEvent] {
        Array(core.upcoming.prefix(2))
    }

    /// The last 2 recorded meetings.
    public var recentMeetings: [MeetingSummary] {
        Array(core.summaries.prefix(2))
    }

    // MARK: - Actions

    /// Start a new recording from the menu bar.
    public func startRecording() async {
        await core.startRecording()
    }

    /// Stop the current recording from the menu bar.
    public func stopRecording() async {
        await core.stopRecording()
    }

    /// Open the main window and optionally navigate to a meeting.
    /// Activates the app to bring it to front (NSApplication is
    /// acceptable here since this is a macOS-only menu bar module).
    public func openApp(meetingID: UUID? = nil) {
        if let meetingID {
            core.select(meetingID)
        } else {
            core.showHome()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Open the main window showing all meetings.
    /// Activates the app to bring the window to front.
    public func seeAll() {
        core.showHome()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Quit the application. Called from the menu bar Quit button.
    /// The app target handles quit-while-recording via
    /// NSApplicationDelegate; this just triggers termination.
    public func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Formatting helpers (pure, testable)

    /// Truncates a title to maxLength, preserving word boundaries,
    /// appending ellipsis if truncated. The time portion is never
    /// truncated (it's a separate field).
    public nonisolated static func truncateTitle(
        _ title: String, maxLength: Int
    ) -> String {
        guard title.count > maxLength else { return title }
        let truncated = String(title.prefix(maxLength))
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(
                truncated[truncated.startIndex ..< lastSpace]
            ) + "\u{2026}"
        }
        return truncated + "\u{2026}"
    }

    /// Formats a future date as relative text: "in 5m", "in 1h 12m".
    public nonisolated static func relativeTimeText(
        _ date: Date, relativeTo now: Date = Date()
    ) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "now" }
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "in \(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "in \(hours)h"
        }
        return "in \(hours)h \(remainingMinutes)m"
    }

    /// Whether a date is within 2 hours from now.
    public nonisolated static func isWithin2Hours(
        _ date: Date, relativeTo now: Date = Date()
    ) -> Bool {
        let interval = date.timeIntervalSince(now)
        return interval > 0 && interval <= 2 * 3600
    }

    /// Formats a time interval as "MM:SS" or "H:MM:SS".
    public nonisolated static func formatElapsed(
        _ elapsed: TimeInterval
    ) -> String {
        let totalSeconds = Int(elapsed)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d", hours, minutes, seconds
            )
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

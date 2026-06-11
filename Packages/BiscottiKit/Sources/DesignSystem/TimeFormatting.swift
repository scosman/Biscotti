import Foundation

/// Shared time-formatting helpers used across HomeUI, AppShellUI,
/// and MenuBarUI for displaying relative times of upcoming events.
public enum TimeFormatting {
    /// Formats a future date as relative text: "in 5m", "in 1h 12m",
    /// "in 2h", or "now" (for past/current dates).
    ///
    /// Used by sidebar upcoming rows, home screen previews, and menu bar
    /// next-meeting labels.
    public static func relativeTimeText(
        _ date: Date, relativeTo now: Date = Date()
    ) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "now" }
        let totalMinutes = Int(ceil(interval / 60))
        if totalMinutes < 60 {
            return "in \(totalMinutes)m"
        }
        let hours = totalMinutes / 60
        let remainingMinutes = totalMinutes % 60
        if remainingMinutes == 0 {
            return "in \(hours)h"
        }
        return "in \(hours)h \(remainingMinutes)m"
    }

    /// Formats a recording duration in seconds as a compact string.
    /// Examples: "34m", "1h 12m", "2h", "<1m".
    public static func compactDuration(
        _ seconds: TimeInterval
    ) -> String {
        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 1 { return "<1m" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    /// Short date formatter for sidebar meeting rows (e.g. "Jun 9, 2026").
    public static func shortDate(
        _ date: Date
    ) -> String {
        shortDateFormatter.string(from: date)
    }

    /// Builds the second-line text for a meeting row: "Jun 9, 2026 \u{00B7} 34m"
    /// (date + middot + duration), or just "Jun 9, 2026" when no recording
    /// duration is available (nil or zero).
    ///
    /// Shared between the sidebar (`MeetingListViewModel`) and the Home
    /// screen's recent-meetings section so the format is byte-identical.
    public static func meetingSecondLine(
        date: Date,
        duration: TimeInterval?
    ) -> String {
        let dateStr = shortDate(date)
        guard let duration, duration > 0 else {
            return dateStr
        }
        return "\(dateStr) \u{00B7} \(compactDuration(duration))"
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

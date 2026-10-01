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

    /// Formats a future date as coarse relative text for upcoming countdowns.
    ///
    /// Tiers:
    /// - >= 1 day: "in 1 day" / "in N days" (whole days, no hours/minutes)
    /// - > 3 hours (and < 1 day): "in Nh" (whole hours, no minutes)
    /// - <= 3 hours: same as `relativeTimeText` ("in 2h 15m", "in 45m")
    /// - past/current: "now"
    public static func coarseRelativeTimeText(
        _ date: Date, relativeTo now: Date = Date()
    ) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "now" }

        let totalMinutes = Int(ceil(interval / 60))

        // >= 1 day (1440 minutes)
        if totalMinutes >= 1440 {
            let days = totalMinutes / 1440
            return days == 1 ? "in 1 day" : "in \(days) days"
        }

        // > 3 hours (strictly over 180 minutes): whole hours only
        if totalMinutes > 180 {
            let totalHours = totalMinutes / 60
            return "in \(totalHours)h"
        }

        // <= 3 hours: full precision (delegates to existing formatter)
        return relativeTimeText(date, relativeTo: now)
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

    /// Formats a playback time interval as "M:SS" or "H:MM:SS".
    ///
    /// Used by the audio transport scrubber and transcript timestamps.
    /// Nonisolated so it can be called from pure builders outside
    /// `@MainActor`.
    public static func formatPlaybackTime(
        _ interval: TimeInterval
    ) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours, minutes, seconds
            )
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Formats a date range as "Mon, Jun 11 · 4:18 - 4:50 PM" (same day)
    /// or "Mon, Jun 11 4:18 PM - Tue, Jun 12 5:00 PM" (cross-day).
    ///
    /// Returns `nil` when `start` is nil. When `end` is nil, shows just
    /// the start date and time.
    ///
    /// Shared across MeetingDetailViewModel and EventPreviewViewModel.
    public static func whenText(start: Date?, end: Date?) -> String? {
        guard let start else { return nil }

        guard let end else {
            return whenDateFormatter.string(from: start) + " \u{00B7} "
                + whenEndTimeFormatter.string(from: start)
        }

        let cal = Foundation.Calendar.current
        if cal.isDate(start, inSameDayAs: end) {
            return whenDateFormatter.string(from: start) + " \u{00B7} "
                + whenTimeFormatter.string(from: start) + " \u{2013} "
                + whenEndTimeFormatter.string(from: end)
        }

        return whenDateFormatter.string(from: start) + " "
            + whenEndTimeFormatter.string(from: start)
            + " \u{2013} " + whenDateFormatter.string(from: end) + " "
            + whenEndTimeFormatter.string(from: end)
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// Locale-aware short date with weekday (e.g. "Wed, Jun 11" in en_US).
    private static let whenDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()

    /// Locale-aware start time for same-day ranges (before the en-dash).
    private static let whenTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter
    }()

    /// Locale-aware end time (e.g. "4:50 PM" in en_US, "16:50" in de_DE).
    private static let whenEndTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j:mm a")
        return formatter
    }()
}

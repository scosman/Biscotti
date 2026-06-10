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
}

import Foundation

/// Builds URLs for opening calendar events in Calendar.app.
///
/// Single source of truth for the `ical://` deep-link URL scheme.
/// All screens that open events in Calendar.app (Home, EventPreview,
/// MeetingDetail) call through here to avoid duplicating URL logic.
public enum CalendarDeepLink {
    /// Builds the best URL to open a calendar event in Calendar.app.
    ///
    /// Strategy (highest fidelity first):
    /// 1. `ical://ekevent/<eventIdentifier>?method=show&options=more`
    ///    — opens the specific event directly.
    /// 2. `ical://<integerEpoch>` — opens Calendar.app at that date
    ///    (integer seconds since 2001-01-01, no fractional component).
    /// 3. `ical://` — just opens Calendar.app.
    ///
    /// Returns `nil` only if URL construction fails entirely (shouldn't
    /// happen in practice since `ical://` is always valid).
    public static func calendarAppURL(
        eventIdentifier: String?,
        startDate: Date?
    ) -> URL? {
        // Best: open by EKEvent identifier
        if let eventID = eventIdentifier, !eventID.isEmpty,
           let url = URL(
               string: "ical://ekevent/\(eventID)?method=show&options=more"
           )
        {
            return url
        }

        // Fallback: open Calendar.app at the event's date
        if let date = startDate {
            let epoch = Int(date.timeIntervalSinceReferenceDate)
            if let url = URL(string: "ical://\(epoch)") {
                return url
            }
        }

        // Last resort: just open Calendar.app
        return URL(string: "ical://")
    }
}

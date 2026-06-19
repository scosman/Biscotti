import Foundation

/// Which calendar events trigger pre-meeting notifications.
///
/// Backed by a stored `String` in `AppSettings.calendarNotificationModeRaw`.
/// Shape mirrors `MenuBarLeadTime` (String rawValue, CaseIterable, Identifiable).
public enum CalendarNotificationMode: String, CaseIterable, Sendable, Identifiable {
    case allMeetings
    case videoConferencing
    case never

    public var id: String {
        rawValue
    }

    /// Human-readable label for the picker.
    public var displayText: String {
        switch self {
        case .allMeetings: "All Meetings"
        case .videoConferencing: "Meetings with Video Conferencing"
        case .never: "Never"
        }
    }

    /// Stored-string -> enum, defaulting to `.allMeetings` for unknown values.
    public init(raw: String) {
        self = Self(rawValue: raw) ?? .allMeetings
    }
}

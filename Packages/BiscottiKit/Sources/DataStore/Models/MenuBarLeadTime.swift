import Foundation

/// How far before a meeting's start time the menu bar shows the
/// detailed "next meeting" text. Backed by a stored `Int` (seconds)
/// in `AppSettings.menuBarLeadTimeSeconds`.
public enum MenuBarLeadTime: Int, CaseIterable, Sendable, Identifiable {
    /// Never show the detailed meeting text.
    case never = 0
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case sixHours = 21600
    case twelveHours = 43200
    case twentyFourHours = 86400

    public var id: Int {
        rawValue
    }

    /// Human-readable label for the picker.
    public var displayText: String {
        switch self {
        case .never: "Never"
        case .fiveMinutes: "5 minutes before"
        case .tenMinutes: "10 minutes before"
        case .fifteenMinutes: "15 minutes before"
        case .thirtyMinutes: "30 minutes before"
        case .oneHour: "1 hour before"
        case .twoHours: "2 hours before"
        case .sixHours: "6 hours before"
        case .twelveHours: "12 hours before"
        case .twentyFourHours: "24 hours before"
        }
    }

    /// The duration window after a meeting starts during which the
    /// detailed text is still shown (for people running late).
    /// All non-never options share the same 5-minute grace period.
    public static let postStartGraceSeconds: TimeInterval = 5 * 60

    /// Creates a `MenuBarLeadTime` from a stored seconds value,
    /// falling back to `.oneHour` if the value doesn't match a known case.
    public init(seconds: Int) {
        self = Self(rawValue: seconds) ?? .oneHour
    }

    /// Whether a meeting starting at `meetingStart` should show the
    /// detailed text in the menu bar at time `now`.
    ///
    /// Returns `true` when `self != .never` AND `now` is within
    /// `[meetingStart - leadTime, meetingStart + 5 min]`.
    public func shouldShowDetailedText(
        meetingStart: Date,
        now: Date
    ) -> Bool {
        guard self != .never else { return false }
        let interval = meetingStart.timeIntervalSince(now)
        let leadSeconds = TimeInterval(rawValue)
        // now is before meeting: interval > 0, must be <= leadSeconds
        // now is after meeting start: interval < 0, must be within grace
        return interval <= leadSeconds
            && interval >= -Self.postStartGraceSeconds
    }
}

import Foundation

/// The three notification kinds the app can present.
public enum NotificationKind: Sendable, Equatable {
    /// A calendar-driven meeting is starting (or imminent).
    case meetingStarting(eventKey: String, title: String, joinURL: URL?)

    /// An ad-hoc meeting was detected in a meeting app.
    case adHocDetected(bundleID: String, appName: String)

    /// An active detection-driven recording's audio stopped; auto-stop countdown is running.
    case stopCountdown(meetingID: UUID, secondsRemaining: Int)
}

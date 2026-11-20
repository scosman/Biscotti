import Foundation

/// The notification kinds the app can present.
public enum NotificationKind: Sendable, Equatable {
    /// A calendar-driven meeting is starting (or imminent).
    case meetingStarting(eventKey: String, title: String, joinURL: URL?, start: Date)

    /// An ad-hoc meeting was detected in a meeting app.
    case adHocDetected(bundleID: String, appName: String)

    /// An active detection-driven recording's audio stopped; auto-stop countdown is running.
    case stopCountdown(meetingID: UUID, secondsRemaining: Int)

    /// A recording was started automatically. Offers Stop and Discard.
    case autoRecordingStarted(meetingID: UUID, appName: String)

    /// An automatic export was written (or failed). Quiet,
    /// informational: says what happened to the file.
    case exportUpdated(meetingID: UUID, meetingTitle: String, detail: String)

    /// A call window has live captions off. Offers Turn On
    /// Captions, Skip Till Next Meeting and No.
    case captionsOff(bundleID: String, appName: String)
}

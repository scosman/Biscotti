import Foundation

/// Typed user intent extracted from a raw notification delegate response.
public enum NotificationAction: Sendable, Equatable {
    /// User wants to open the app and start recording.
    /// `eventKey` is non-nil for calendar-driven starts, nil for ad-hoc detections.
    case openAndRecord(eventKey: String?)

    /// User tapped Keep Recording on a stop-countdown notification.
    case keepRecording(meetingID: UUID)
}

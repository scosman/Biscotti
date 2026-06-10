import Foundation

// MARK: - Category IDs

/// UNNotificationCategory identifiers.
enum CategoryID {
    static let meetingStarting = "biscotti.meeting-starting"
    static let meetingStartingWithJoin = "biscotti.meeting-starting-with-join"
    static let adHocDetected = "biscotti.ad-hoc-detected"
    static let stopCountdown = "biscotti.stop-countdown"
}

// MARK: - Action IDs

/// UNNotificationAction identifiers.
enum ActionID {
    static let openAndRecord = "biscotti.action.open-and-record"
    static let join = "biscotti.action.join"
    static let record = "biscotti.action.record"
    static let keepRecording = "biscotti.action.keep-recording"
}

// MARK: - UserInfo keys

/// Keys stored in `UNNotificationRequest.content.userInfo` for delegate response typing.
enum UserInfoKey {
    static let kind = "biscotti.kind"
    static let eventKey = "biscotti.eventKey"
    static let bundleID = "biscotti.bundleID"
    static let joinURL = "biscotti.joinURL"
    static let meetingID = "biscotti.meetingID"
}

// MARK: - Kind string values stored in userInfo

enum KindValue {
    static let meetingStarting = "meeting-starting"
    static let adHoc = "ad-hoc"
    static let countdown = "countdown"
}

// MARK: - Request identifier construction

/// Builds the stable request identifier for a notification kind.
///
/// Using a stable identifier per-event/app/meeting ensures re-posting replaces the previous
/// notification in-place (UNNotificationRequest semantics).
func requestIdentifier(for kind: NotificationKind) -> String {
    switch kind {
    case let .meetingStarting(eventKey, _, _):
        "biscotti.notif.meeting-start.\(eventKey)"
    case let .adHocDetected(bundleID, _):
        "biscotti.notif.adhoc.\(bundleID)"
    case let .stopCountdown(meetingID, _):
        countdownRequestIdentifier(meetingID: meetingID)
    }
}

/// Standalone countdown ID builder for `updateCountdown` / `cancelCountdown` which
/// don't receive a full `NotificationKind`.
func countdownRequestIdentifier(meetingID: UUID) -> String {
    "biscotti.notif.countdown.\(meetingID.uuidString)"
}

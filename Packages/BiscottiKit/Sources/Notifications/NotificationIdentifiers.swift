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
    static let recordAndJoin = "biscotti.action.record-and-join"
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
    static let eventStart = "biscotti.eventStart"
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
    case let .meetingStarting(eventKey, _, _, _):
        meetingStartRequestIdentifier(eventKey: eventKey)
    case let .adHocDetected(bundleID, _):
        adHocRequestIdentifier(bundleID: bundleID)
    case let .stopCountdown(meetingID, _):
        countdownRequestIdentifier(meetingID: meetingID)
    }
}

/// Standalone meeting-start ID builder for cancel methods that
/// don't receive a full `NotificationKind`.
func meetingStartRequestIdentifier(eventKey: String) -> String {
    "biscotti.notif.meeting-start.\(eventKey)"
}

/// Standalone ad-hoc ID builder for cancel methods that
/// don't receive a full `NotificationKind`.
func adHocRequestIdentifier(bundleID: String) -> String {
    "biscotti.notif.adhoc.\(bundleID)"
}

/// Standalone countdown ID builder for `cancelCountdown` which
/// doesn't receive a full `NotificationKind`.
func countdownRequestIdentifier(meetingID: UUID) -> String {
    "biscotti.notif.countdown.\(meetingID.uuidString)"
}

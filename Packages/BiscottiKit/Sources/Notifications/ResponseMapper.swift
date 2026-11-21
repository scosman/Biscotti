import Foundation
import UserNotifications

/// Pure mapping function: extracts a typed `NotificationAction` from the raw
/// delegate response values (category ID, action ID, userInfo).
///
/// Separated from `NotificationService` so the logic is testable without
/// constructing a `UNNotificationResponse` (which has no public initializer).
/// Returns `nil` for dismiss or unrecognized actions.
func mapResponse(
    categoryID: String,
    actionID: String,
    userInfo: [AnyHashable: Any]
) -> NotificationAction? {
    // Dismiss is never enqueued.
    if actionID == UNNotificationDismissActionIdentifier {
        return nil
    }

    switch categoryID {
    case CategoryID.meetingStarting,
         CategoryID.meetingStartingWithJoin:
        return mapMeetingStartResponse(actionID: actionID, userInfo: userInfo)

    case CategoryID.adHocDetected:
        return mapAdHocResponse(actionID: actionID, userInfo: userInfo)

    case CategoryID.stopCountdown:
        return mapCountdownResponse(actionID: actionID, userInfo: userInfo)

    case CategoryID.autoRecording:
        return mapAutoRecordingResponse(actionID: actionID, userInfo: userInfo)

    case CategoryID.captions:
        return mapCaptionsResponse(actionID: actionID, userInfo: userInfo)

    default:
        return nil
    }
}

// MARK: - Per-category mappers

private func mapMeetingStartResponse(
    actionID: String,
    userInfo: [AnyHashable: Any]
) -> NotificationAction? {
    let eventKey = userInfo[UserInfoKey.eventKey] as? String

    switch actionID {
    case ActionID.recordAndJoin,
         ActionID.record,
         UNNotificationDefaultActionIdentifier:
        return .openAndRecord(eventKey: eventKey)

    default:
        return nil
    }
}

private func mapAdHocResponse(
    actionID: String,
    userInfo _: [AnyHashable: Any]
) -> NotificationAction? {
    switch actionID {
    case ActionID.record,
         UNNotificationDefaultActionIdentifier:
        .openAndRecord(eventKey: nil)
    default:
        nil
    }
}

private func mapCountdownResponse(
    actionID: String,
    userInfo: [AnyHashable: Any]
) -> NotificationAction? {
    switch actionID {
    case ActionID.keepRecording,
         UNNotificationDefaultActionIdentifier:
        guard let idString = userInfo[UserInfoKey.meetingID] as? String,
              let meetingID = UUID(uuidString: idString)
        else {
            return nil
        }
        return .keepRecording(meetingID: meetingID)
    default:
        return nil
    }
}

/// Tapping the banner body does nothing (recording continues);
/// only the explicit buttons act.
private func mapAutoRecordingResponse(
    actionID: String,
    userInfo: [AnyHashable: Any]
) -> NotificationAction? {
    guard let idString = userInfo[UserInfoKey.meetingID] as? String,
          let meetingID = UUID(uuidString: idString)
    else {
        return nil
    }
    switch actionID {
    case ActionID.stopRecording:
        return .stopRecording(meetingID: meetingID)
    case ActionID.discardRecording:
        return .discardRecording(meetingID: meetingID)
    default:
        return nil
    }
}

/// Tapping the banner body does nothing.
func mapCaptionsResponse(actionID: String, userInfo: [AnyHashable: Any]) -> NotificationAction? {
    guard let bundleID = userInfo[UserInfoKey.bundleID] as? String else { return nil }
    switch actionID {
    case ActionID.turnOnCaptions: return .turnOnCaptions(bundleID: bundleID)
    case ActionID.skipCaptions: return .skipCaptions(bundleID: bundleID)
    case ActionID.noCaptions: return .neverOfferCaptions
    default: return nil
    }
}

import os
import UserNotifications

/// Production wrapper around `UNUserNotificationCenter.current()`.
///
/// Thin forwarding — no interesting logic. Exists purely so the seam is injectable.
public struct LiveNotificationCenter: NotificationCenterProviding, Sendable {
    private let logger = Logger(
        subsystem: "net.scosman.biscotti",
        category: "LiveNotificationCenter"
    )

    public init() {}

    public func requestAuthorization() async throws -> Bool {
        logger.info(
            "requestAuthorization: calling UNUserNotificationCenter.current().requestAuthorization(options: [.alert])"
        )
        let granted = try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert])
        logger.info(
            "requestAuthorization: UNUserNotificationCenter returned granted=\(granted)"
        )
        return granted
    }

    public func setCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    public func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    public func removePendingRequests(withIdentifiers ids: [String]) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ids)
    }

    public func removeDeliveredNotifications(withIdentifiers ids: [String]) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ids)
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        logger.info(
            "authorizationStatus: \(settings.authorizationStatus.rawValue)"
        )
        return settings.authorizationStatus
    }

    public func alertStyle() async -> UNAlertStyle {
        await UNUserNotificationCenter.current().notificationSettings().alertStyle
    }
}

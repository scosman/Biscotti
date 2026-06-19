import UserNotifications

/// Test seam over `UNUserNotificationCenter`.
///
/// The live implementation wraps `UNUserNotificationCenter.current()`.
/// Tests inject a fake that records calls and can script authorization results.
public protocol NotificationCenterProviding: Sendable {
    /// Request alert+sound authorization. Returns `true` if granted.
    func requestAuthorization() async throws -> Bool

    /// Register notification categories (called once at init).
    func setCategories(_ categories: Set<UNNotificationCategory>)

    /// Add (or replace) a notification request.
    func add(_ request: UNNotificationRequest) async throws

    /// Remove pending notifications matching identifiers.
    func removePendingRequests(withIdentifiers ids: [String])

    /// Remove delivered notifications matching identifiers.
    func removeDeliveredNotifications(withIdentifiers ids: [String])

    /// Current authorization status.
    func authorizationStatus() async -> UNAuthorizationStatus

    /// Current on-screen alert style (banner vs. alert vs. none).
    func alertStyle() async -> UNAlertStyle
}

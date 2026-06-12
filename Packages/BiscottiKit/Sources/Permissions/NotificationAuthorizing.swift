/// Seam over notification (UserNotifications) authorization.
///
/// The live implementation imports UserNotifications and wraps
/// `UNUserNotificationCenter`. Tests inject a fake. The protocol lives
/// in `Permissions` so the module stays free of UserNotifications imports.
public protocol NotificationAuthorizing: Sendable {
    /// Returns the current notification authorization state.
    func status() async -> PermissionState

    /// Requests notification authorization. Returns `true` if granted.
    func request() async -> Bool
}

/// The macOS notification alert style for Biscotti, as reported by
/// `UNNotificationSettings.alertStyle`.
///
/// Wraps `UNAlertStyle` as a plain Sendable enum so callers don't
/// need to import UserNotifications.
public enum NotificationAlertStyle: Sendable, Equatable {
    /// Notifications are disabled (style set to "None" in System Settings).
    case none
    /// Banners: notifications appear briefly then auto-dismiss (~5 seconds).
    case banner
    /// Alerts: notifications stay on screen until the user dismisses them.
    case alert
}

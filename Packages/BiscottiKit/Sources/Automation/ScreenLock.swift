import Foundation

/// The macOS screen-lock signal.
public enum ScreenLock {
    /// Posted on the distributed notification center when the screen locks.
    public static let lockedNotification = Notification.Name("com.apple.screenIsLocked")

    #if os(macOS)
        /// The center that carries `lockedNotification`.
        public static var center: NotificationCenter {
            DistributedNotificationCenter.default()
        }
    #else
        public static var center: NotificationCenter {
            .default
        }
    #endif
}

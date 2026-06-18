import AppKit
import Foundation

/// Unified, testable view of the system permissions the app needs.
///
/// Fully owns **microphone** (public TCC API via the `MicAuthorizing` seam).
/// **System audio** has no public status API; its state is persisted via
/// `SystemAudioPermissionStore` and updated by the tone-probe flow via
/// `setSystemAudio(_:)`.
/// **Calendar** and **notifications** are reported by their respective
/// services via `noteCalendar(_:)` / `noteNotifications(_:)`, or can be
/// requested through the injected seams.
@MainActor @Observable
public final class Permissions {
    /// Current microphone permission state.
    public private(set) var microphone: PermissionState

    /// Current system-audio permission state (persisted via `SystemAudioPermissionStore`).
    /// Uses a dedicated state type -- no `.denied` exists; see `SystemAudioPermissionState`.
    public private(set) var systemAudio: SystemAudioPermissionState

    /// Current calendar permission state.
    public private(set) var calendar: PermissionState

    /// Current notifications permission state.
    public private(set) var notifications: PermissionState

    private let mic: any MicAuthorizing
    private let cal: (any CalendarAuthorizing)?
    private var notif: (any NotificationAuthorizing)?
    private let systemAudioStore: any SystemAudioPermissionStore

    /// Creates a Permissions instance.
    /// - Parameters:
    ///   - mic: The microphone authorization seam (defaults to the live implementation).
    ///   - cal: The calendar authorization seam (nil = status stays `.notDetermined`
    ///     until reported externally via `noteCalendar`).
    ///   - notif: The notification authorization seam (nil = status stays `.notDetermined`
    ///     until reported externally via `noteNotifications`).
    ///   - systemAudioStore: Persistence seam for system-audio permission state.
    ///     Defaults to `UserDefaultsSystemAudioPermissionStore` (device-local UserDefaults).
    public init(
        mic: any MicAuthorizing = LiveMicAuthorizer(),
        cal: (any CalendarAuthorizing)? = nil,
        notif: (any NotificationAuthorizing)? = nil,
        systemAudioStore: any SystemAudioPermissionStore = UserDefaultsSystemAudioPermissionStore()
    ) {
        self.mic = mic
        self.cal = cal
        self.notif = notif
        self.systemAudioStore = systemAudioStore
        microphone = mic.status()
        systemAudio = systemAudioStore.load()
        calendar = cal?.status() ?? .notDetermined
        notifications = .notDetermined
    }

    /// Sets the notification authorization seam after construction.
    ///
    /// Used by `AppCore.live` where `NotificationService` is created
    /// after `Permissions` but before any notification requests.
    public func setNotificationAuthorizer(
        _ authorizer: any NotificationAuthorizing
    ) {
        notif = authorizer
    }

    /// Re-reads statuses from the system.
    ///
    /// Call on app activation / window focus so the UI reflects
    /// permission changes made in System Settings.
    public func refresh() async {
        microphone = mic.status()
        if let cal {
            calendar = cal.status()
        }
        if let notif {
            notifications = await notif.status()
        }
    }

    // MARK: - Microphone

    /// Requests microphone permission. Returns `true` if granted.
    @discardableResult
    public func requestMicrophone() async -> Bool {
        switch microphone {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            let granted = await mic.request()
            microphone = granted ? .authorized : .denied
            return granted
        }
    }

    /// Updates the system-audio permission state and persists it.
    ///
    /// Called by `RecordingController.probeSystemAudioPermission()` after
    /// the tone-probe completes. Never sets a "denied" state (the enum
    /// has no such case).
    public func setSystemAudio(_ state: SystemAudioPermissionState) {
        systemAudio = state
        systemAudioStore.save(state)
    }

    // MARK: - Calendar

    /// Requests calendar permission through the seam. Returns the resulting state.
    @discardableResult
    public func requestCalendar() async -> PermissionState {
        guard let cal else { return calendar }
        let result = await cal.request()
        calendar = result
        return result
    }

    /// Called by the Calendar module to report authorization state.
    public func noteCalendar(_ state: PermissionState) {
        calendar = state
    }

    // MARK: - Notifications

    /// Requests notification authorization through the seam. Returns `true` if granted.
    @discardableResult
    public func requestNotifications() async -> Bool {
        guard let notif else { return false }
        let granted = await notif.request()
        notifications = granted ? .authorized : .denied
        return granted
    }

    /// Called by the Notifications module to report authorization state.
    public func noteNotifications(_ state: PermissionState) {
        notifications = state
    }

    // MARK: - Settings deep links

    /// Returns a URL that opens the correct System Settings pane for the given permission.
    public func settingsURL(for kind: PermissionKind) -> URL {
        let string =
            switch kind {
            case .microphone:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .systemAudio:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case .calendar:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
            case .notifications:
                // Notifications live under their own pane, not Privacy & Security.
                "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            }
        // The strings above are static and always parse; the fallback only exists
        // to keep this non-optional without a force unwrap (it opens Settings.app).
        return URL(string: string) ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
    }
}

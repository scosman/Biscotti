import AppCore
import AppKit
import Calendar
import DataStore
import Foundation
import Permissions
import ServiceManagement

/// A group of calendars from the same source for the settings UI.
public struct CalendarGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let sourceTitle: String
    public let calendars: [CalendarInfo]

    public init(
        id: String,
        sourceTitle: String,
        calendars: [CalendarInfo]
    ) {
        self.id = id
        self.sourceTitle = sourceTitle
        self.calendars = calendars
    }
}

// TODO(vocab): re-add a Custom Vocabulary settings section once the deferred Phase 9 SDK vocab support lands

/// View model for the Settings screen: calendar include/exclude, permissions
/// overview with inline request actions, and general preferences.
@MainActor @Observable
public final class SettingsViewModel {
    private let core: AppCore

    /// Seam for reading the system launch-at-login status. Defaults to
    /// `SMAppService.mainApp.status == .enabled`. Injected in tests.
    private let readLaunchAtLoginStatus: @MainActor () -> Bool

    // MARK: - General

    /// Launch at login toggle state. Reflects `SMAppService.mainApp.status`
    /// as the source of truth, reconciled on `load()`.
    public private(set) var launchAtLogin: Bool = true

    /// When true, closing the last window or pressing Cmd+Q terminates the
    /// app. When false (default), those actions just hide the window and the
    /// app stays alive in the menu bar.
    public private(set) var exitOnWindowClose: Bool = false

    // MARK: - Calendar state

    /// All calendars grouped by source, for the include/exclude toggles.
    public private(set) var calendarGroups: [CalendarGroup] = []

    /// The set of enabled calendar IDs. nil = all enabled.
    public private(set) var enabledCalendarIDs: Set<String>?

    // MARK: - Permissions

    /// Permission states for each kind.
    public var microphoneState: PermissionState {
        core.permissions.microphone
    }

    public var systemAudioState: PermissionState {
        core.permissions.systemAudio
    }

    public var calendarState: PermissionState {
        core.permissions.calendar
    }

    public var notificationsState: PermissionState {
        core.permissions.notifications
    }

    // MARK: - Init

    /// - Parameters:
    ///   - core: The application core coordinator.
    ///   - readLaunchAtLoginStatus: Closure returning the system's
    ///     launch-at-login state. Defaults to `SMAppService.mainApp.status`.
    ///     Override in tests for determinism.
    public init(
        core: AppCore,
        readLaunchAtLoginStatus: (@MainActor () -> Bool)? = nil
    ) {
        self.core = core
        self.readLaunchAtLoginStatus = readLaunchAtLoginStatus ?? {
            #if canImport(ServiceManagement)
                ServiceManagement.SMAppService.mainApp.status == .enabled
            #else
                false
            #endif
        }
    }

    // MARK: - General actions

    /// Toggles launch at login on/off. Persists to settings and updates
    /// `SMAppService` registration.
    public func setLaunchAtLogin(_ enabled: Bool) async {
        launchAtLogin = enabled
        do {
            try await core.store.updateSettings { settings in
                settings.launchAtLogin = enabled
            }
        } catch {
            // Revert on failure
            launchAtLogin = !enabled
        }

        // Update SMAppService (best-effort)
        #if canImport(ServiceManagement)
            updateLaunchAtLoginService(enabled)
        #endif
    }

    /// Toggles the "exit app on window close" setting. Persists to the store
    /// and posts `.exitOnWindowCloseDidChange` (defined in AppCore) so the
    /// app delegate can refresh its cached lifecycle policy.
    public func setExitOnWindowClose(_ enabled: Bool) async {
        exitOnWindowClose = enabled
        do {
            try await core.store.updateSettings { settings in
                settings.exitOnWindowClose = enabled
            }
            NotificationCenter.default.post(
                name: .exitOnWindowCloseDidChange,
                object: nil
            )
        } catch {
            // Revert on failure
            exitOnWindowClose = !enabled
        }
    }

    #if canImport(ServiceManagement)
        private func updateLaunchAtLoginService(_ enabled: Bool) {
            let service = ServiceManagement.SMAppService.mainApp
            do {
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                // Non-fatal: service management may fail in
                // sandboxed/debug environments.
            }
        }
    #endif

    // MARK: - Calendar actions

    /// Whether a calendar is enabled (checked).
    public func isCalendarEnabled(_ calendarID: String) -> Bool {
        guard let enabled = enabledCalendarIDs else { return true }
        return enabled.contains(calendarID)
    }

    /// Toggle a calendar on/off. Persists to settings and refreshes upcoming.
    public func toggleCalendar(_ calendarID: String) async {
        let allCalendarIDs = calendarGroups
            .flatMap(\.calendars)
            .map(\.id)

        var newSet: Set<String>
        if let current = enabledCalendarIDs {
            newSet = current
            if newSet.contains(calendarID) {
                newSet.remove(calendarID)
            } else {
                newSet.insert(calendarID)
            }
        } else {
            // Was nil (all enabled) -> switching one off means all-except-one
            newSet = Set(allCalendarIDs)
            newSet.remove(calendarID)
        }

        // If all are now enabled, store nil for simplicity
        if newSet.count == allCalendarIDs.count {
            enabledCalendarIDs = nil
        } else {
            enabledCalendarIDs = newSet
        }

        do {
            let updated = enabledCalendarIDs
            try await core.store.updateSettings { settings in
                settings.enabledCalendarIDs = updated
            }
            // Refresh upcoming to reflect the change
            let now = Date()
            await core.calendar.refreshUpcoming(
                window: DateInterval(
                    start: now,
                    end: now.addingTimeInterval(
                        CalendarService.upcomingWindowSeconds
                    )
                )
            )
        } catch {
            // Revert UI on failure
            enabledCalendarIDs = nil
        }
    }

    // MARK: - Permission actions

    /// Open System Settings to the appropriate privacy pane.
    public func openPermissionSettings(for kind: PermissionKind) {
        let url = core.permissions.settingsURL(for: kind)
        NSWorkspace.shared.open(url)
    }

    /// Request access for a specific permission. Only effective when the
    /// permission is `.notDetermined` (macOS won't re-prompt after denial).
    /// After the request completes, the permission state updates automatically
    /// through the observable `core.permissions` properties.
    public func requestPermission(for kind: PermissionKind) async {
        switch kind {
        case .microphone:
            await core.permissions.requestMicrophone()
        case .systemAudio:
            await core.requestSystemAudioPermission()
        case .calendar:
            let result = await core.calendar.requestAccess()
            let mapped: PermissionState = switch result {
            case .authorized: .authorized
            case .denied, .restricted: .denied
            case .notDetermined: .notDetermined
            }
            core.permissions.noteCalendar(mapped)
        case .notifications:
            let granted = await core.permissions.requestNotifications()
            // noteNotifications is called inside requestNotifications
            _ = granted
        }
    }

    // MARK: - Lifecycle

    /// Load initial data (calendars, settings, launch-at-login, and
    /// live permission statuses).
    ///
    /// Launch-at-login reads `SMAppService.mainApp.status` as the source
    /// of truth (the user can toggle it in System Settings > Login Items,
    /// so the stored bool may drift). Permission statuses are refreshed
    /// from their live system sources so the overview reflects reality.
    public func load() async {
        // Refresh all permission statuses from the system
        await core.refreshAllPermissions()

        do {
            let settings = try await core.store.settings()
            enabledCalendarIDs = settings.enabledCalendarIDs
            exitOnWindowClose = settings.exitOnWindowClose
        } catch {
            enabledCalendarIDs = nil
        }

        // SMAppService is the source of truth for launch-at-login
        launchAtLogin = readLaunchAtLoginStatus()

        let infos = await core.calendar.calendars()
        calendarGroups = Self.groupCalendars(infos)
    }

    // MARK: - Grouping (pure, testable)

    /// Groups CalendarInfo items by sourceTitle.
    public static func groupCalendars(
        _ infos: [CalendarInfo]
    ) -> [CalendarGroup] {
        let grouped = Dictionary(grouping: infos, by: \.sourceTitle)
        return grouped
            .sorted { $0.key < $1.key }
            .map { source, calendars in
                CalendarGroup(
                    id: source,
                    sourceTitle: source,
                    calendars: calendars.sorted { $0.title < $1.title }
                )
            }
    }
}

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

/// View model for the Settings screen (first slice: calendar include/exclude
/// + permissions overview).
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

    // MARK: - Calendar state

    /// All calendars grouped by source, for the include/exclude toggles.
    public private(set) var calendarGroups: [CalendarGroup] = []

    /// The set of enabled calendar IDs. nil = all enabled.
    public private(set) var enabledCalendarIDs: Set<String>?

    // MARK: - Custom Vocabulary (stubbed -- Phase 9 deferred)

    /// TODO(Phase 9 deferred): wire to VocabularyService once SDK vocab support lands
    /// Vocabulary editing is deferred until the SDK supports custom vocabulary.
    /// This property exists for the UI to show a "Coming soon" placeholder.
    public let vocabularyDeferred: Bool = true

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
                    end: now.addingTimeInterval(24 * 60 * 60)
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

    // MARK: - Navigation

    /// Re-run onboarding from Settings.
    public func rerunOnboarding() {
        core.showOnboardingReplay()
    }

    // MARK: - Lifecycle

    /// Load initial data (calendars, settings, and launch-at-login).
    /// Launch-at-login reads `SMAppService.mainApp.status` as the source
    /// of truth (the user can toggle it in System Settings > Login Items,
    /// so the stored bool may drift).
    public func load() async {
        do {
            let settings = try await core.store.settings()
            enabledCalendarIDs = settings.enabledCalendarIDs
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

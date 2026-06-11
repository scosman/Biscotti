import AppCore
import AppKit
import Calendar
import DataStore
import Foundation
import Permissions
import ServiceManagement
import TranscriptionService

/// A group of calendars from the same source, for the onboarding
/// calendar-selection step. Mirrors `SettingsUI.CalendarGroup`.
public struct OnboardingCalendarGroup: Identifiable, Sendable, Equatable {
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

/// View model for the onboarding wizard. Drives a linear step state
/// machine through Welcome -> permissions -> model download -> Done.
///
/// All permission requests, calendar selection, and model download are
/// delegated to `AppCore` services. Every step is skippable (C3).
@MainActor @Observable
public final class OnboardingViewModel { // swiftlint:disable:this type_body_length
    private let core: AppCore

    // MARK: - Step state machine

    /// The steps in the onboarding wizard.
    public enum Step: Int, CaseIterable, Sendable {
        case welcome = 0
        case microphone
        case systemAudio
        case calendar
        case calendarSelection
        case notifications
        case modelDownload
        case launchAtLogin
        case done
    }

    /// The current step.
    public private(set) var currentStep: Step = .welcome

    /// Total visible steps for the progress indicator (calendar
    /// selection is treated as part of the calendar step).
    public var totalSteps: Int {
        8
    }

    /// The 0-based progress index for the step indicator dots.
    public var progressIndex: Int {
        switch currentStep {
        case .welcome: 0
        case .microphone: 1
        case .systemAudio: 2
        case .calendar, .calendarSelection: 3
        case .notifications: 4
        case .modelDownload: 5
        case .launchAtLogin: 6
        case .done: 7
        }
    }

    // MARK: - Per-step state

    /// Permission results (updated after each request).
    public private(set) var microphoneResult: PermissionState = .notDetermined
    public private(set) var systemAudioResult: PermissionState = .notDetermined
    public private(set) var calendarResult: PermissionState = .notDetermined
    public private(set) var notificationsGranted: Bool = false

    /// Calendar selection (reuses the grouped pattern).
    public private(set) var calendarGroups: [OnboardingCalendarGroup] = []
    public private(set) var enabledCalendarIDs: Set<String>?

    /// Model download state.
    public private(set) var downloadStatus: String?
    public private(set) var isDownloading: Bool = false
    public private(set) var downloadComplete: Bool = false

    // MARK: - Granted-state derivation

    /// Whether the microphone permission has been granted in this session.
    public var microphoneGranted: Bool {
        microphoneResult == .authorized
    }

    /// Whether the system audio permission has been granted in this session.
    public var systemAudioGranted: Bool {
        systemAudioResult == .authorized
    }

    /// Whether calendar access has been granted in this session.
    public var calendarGranted: Bool {
        calendarResult == .authorized
    }

    /// The footer button to display for a given step.
    public enum FooterButton: Equatable, Sendable {
        /// Show the primary "Continue" button (step action is done).
        case continueButton
        /// Show the secondary "Skip" button (step action is not done).
        case skip
        /// Show a custom footer (e.g. No/Yes for Launch at Login).
        case custom
    }

    /// Returns the footer button state for the given step.
    ///
    /// Gated permission/download steps show "Skip" before their
    /// action is completed and "Continue" after. Non-gated steps
    /// (welcome, calendar selection, done) always show Continue.
    /// The launch-at-login step uses a custom No/Yes footer.
    public func footerButton(for step: Step) -> FooterButton {
        switch step {
        case .welcome, .calendarSelection, .done:
            .continueButton
        case .microphone:
            microphoneGranted ? .continueButton : .skip
        case .systemAudio:
            systemAudioGranted ? .continueButton : .skip
        case .calendar:
            calendarGranted ? .continueButton : .skip
        case .notifications:
            notificationsGranted ? .continueButton : .skip
        case .modelDownload:
            downloadComplete ? .continueButton : .skip
        case .launchAtLogin:
            .custom
        }
    }

    /// Whether the current step's gated action is complete.
    public var isCurrentStepComplete: Bool {
        footerButton(for: currentStep) == .continueButton
    }

    /// Disk space check for the model download step.
    public private(set) var hasSufficientDisk: Bool = true

    /// Approximate disk space required for models (MB).
    public static let requiredDiskSpaceMB: Int = 2000

    /// Seam for reading available disk bytes. Defaults to the real
    /// filesystem check. Override in tests for determinism.
    private let availableDiskBytes: @MainActor () -> Int64

    // MARK: - Init

    /// - Parameters:
    ///   - core: The application core coordinator.
    ///   - availableDiskBytes: Closure returning available disk space in
    ///     bytes. Defaults to reading
    ///     `volumeAvailableCapacityForImportantUsage`. Override in tests.
    public init(
        core: AppCore,
        availableDiskBytes: (@MainActor () -> Int64)? = nil
    ) {
        self.core = core
        self.availableDiskBytes = availableDiskBytes ?? {
            let home = FileManager.default
                .homeDirectoryForCurrentUser
            if let values = try? home.resourceValues(
                forKeys: [
                    .volumeAvailableCapacityForImportantUsageKey
                ]
            ),
                let available = values
                .volumeAvailableCapacityForImportantUsage
            {
                return available
            }
            return Int64.max // Assume OK if check fails
        }
    }

    // MARK: - Actions

    /// Advance to the next step. Called by the Continue button.
    public func advance() async {
        switch currentStep {
        case .welcome:
            currentStep = .microphone
        case .microphone:
            currentStep = .systemAudio
        case .systemAudio:
            currentStep = .calendar
        case .calendar:
            if calendarResult == .authorized {
                let infos = await core.calendar.calendars()
                calendarGroups = Self.groupCalendars(infos)
                currentStep = .calendarSelection
            } else {
                currentStep = .notifications
            }
        case .calendarSelection:
            currentStep = .notifications
        case .notifications:
            checkDiskSpace()
            currentStep = .modelDownload
        case .modelDownload:
            currentStep = .launchAtLogin
        case .launchAtLogin:
            currentStep = .done
        case .done:
            await completeOnboarding()
        }
        syncLivePermissionState()
    }

    /// Skip the current step without performing its action.
    public func skip() async {
        switch currentStep {
        case .welcome:
            currentStep = .microphone
        case .microphone:
            currentStep = .systemAudio
        case .systemAudio:
            currentStep = .calendar
        case .calendar:
            currentStep = .notifications
        case .calendarSelection:
            currentStep = .notifications
        case .notifications:
            checkDiskSpace()
            currentStep = .modelDownload
        case .modelDownload:
            currentStep = .launchAtLogin
        case .launchAtLogin:
            currentStep = .done
        case .done:
            await completeOnboarding()
        }
        syncLivePermissionState()
    }

    /// Request the permission for the current step.
    public func requestPermission() async {
        switch currentStep {
        case .microphone:
            let granted = await core.permissions.requestMicrophone()
            microphoneResult = granted ? .authorized : .denied
        case .systemAudio:
            await core.requestSystemAudioPermission()
            systemAudioResult = core.permissions.systemAudio
        case .calendar:
            // Request through CalendarService (which owns the EventKit
            // seam) and map to PermissionState for the UI.
            let authResult = await core.calendar.requestAccess()
            switch authResult {
            case .authorized:
                calendarResult = .authorized
            case .denied, .restricted:
                calendarResult = .denied
            case .notDetermined:
                calendarResult = .notDetermined
            }
            // Also update Permissions so the settings pane stays consistent
            core.permissions.noteCalendar(calendarResult)
        case .notifications:
            // TODO(notifications): onboarding notification permission request not functioning on-device -- revisit
            let granted = await core.permissions
                .requestNotifications()
            notificationsGranted = granted
        default:
            break
        }
    }

    /// Whether a calendar is enabled (checked).
    public func isCalendarEnabled(_ calendarID: String) -> Bool {
        guard let enabled = enabledCalendarIDs else { return true }
        return enabled.contains(calendarID)
    }

    /// Toggle a calendar on/off. Persists to settings.
    public func toggleCalendar(_ calendarID: String) async {
        let allIDs = calendarGroups
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
            newSet = Set(allIDs)
            newSet.remove(calendarID)
        }

        if newSet.count == allIDs.count {
            enabledCalendarIDs = nil
        } else {
            enabledCalendarIDs = newSet
        }

        do {
            let updated = enabledCalendarIDs
            try await core.store.updateSettings { settings in
                settings.enabledCalendarIDs = updated
            }
        } catch {
            // Revert on failure
            enabledCalendarIDs = nil
        }
    }

    /// Start the model download (on the model download step).
    public func startDownload() async {
        isDownloading = true
        downloadStatus = "Preparing\u{2026}"
        do {
            try await core.transcription
                .ensureModelsReady { [weak self] message in
                    Task { @MainActor in
                        self?.downloadStatus = message
                    }
                }
            downloadComplete = true
        } catch {
            downloadStatus =
                "Download failed. You can retry or skip."
        }
        isDownloading = false
    }

    /// Open System Settings for a denied permission.
    public func openSettings(for kind: PermissionKind) {
        let url = core.permissions.settingsURL(for: kind)
        NSWorkspace.shared.open(url)
    }

    /// Set the launch-at-login preference. Persists to settings and
    /// updates `SMAppService` registration (same path as SettingsViewModel).
    public func setLaunchAtLogin(_ enabled: Bool) async {
        do {
            try await core.store.updateSettings { settings in
                settings.launchAtLogin = enabled
            }
        } catch {
            // Non-fatal: best-effort persistence
        }

        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try await service.unregister()
            }
        } catch {
            // Non-fatal: service management may fail in
            // sandboxed/debug environments.
        }
    }

    /// Complete onboarding: persist the flag and navigate to Home.
    public func completeOnboarding() async {
        await core.completeOnboarding()
    }

    // MARK: - Private

    /// Reads the live system permission state for the current step
    /// so that already-granted permissions show the checkmark
    /// immediately (e.g. when re-running onboarding or when the
    /// user granted the permission outside the wizard).
    private func syncLivePermissionState() {
        switch currentStep {
        case .microphone:
            microphoneResult = core.permissions.microphone
        case .systemAudio:
            systemAudioResult = core.permissions.systemAudio
        case .calendar:
            switch core.calendar.auth {
            case .authorized:
                calendarResult = .authorized
            case .denied, .restricted:
                calendarResult = .denied
            case .notDetermined:
                calendarResult = .notDetermined
            }
        case .notifications:
            notificationsGranted =
                core.permissions.notifications == .authorized
        default:
            break
        }
    }

    private func checkDiskSpace() {
        let requiredBytes = Int64(Self.requiredDiskSpaceMB)
            * 1_048_576
        let available = availableDiskBytes()
        hasSufficientDisk = available >= requiredBytes
    }

    /// Groups CalendarInfo items by sourceTitle (same logic as SettingsVM).
    public static func groupCalendars(
        _ infos: [CalendarInfo]
    ) -> [OnboardingCalendarGroup] {
        let grouped = Dictionary(grouping: infos, by: \.sourceTitle)
        return grouped
            .sorted { $0.key < $1.key }
            .map { source, calendars in
                OnboardingCalendarGroup(
                    id: source,
                    sourceTitle: source,
                    calendars: calendars.sorted { $0.title < $1.title }
                )
            }
    }
}

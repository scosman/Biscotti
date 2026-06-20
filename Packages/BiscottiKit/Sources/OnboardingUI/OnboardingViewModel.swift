import AppCore
import AppKit
import Calendar
import DataStore
import Foundation
import Permissions
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
/// machine through Welcome -> Grant access -> Calendar selection ->
/// Download models -> Done.
///
/// All permission requests, calendar selection, and model download are
/// delegated to `AppCore` services. Every step is skippable.
@MainActor @Observable
public final class OnboardingViewModel {
    private let core: AppCore

    // MARK: - Step state machine

    /// The screens in the onboarding wizard. Raw values provide the
    /// fixed progress-bar positions (0-4 -> 20/40/60/80/100%).
    public enum Step: Int, CaseIterable, Sendable {
        case welcome = 0
        case permissions
        case calendarSelection
        case modelDownload
        case done
    }

    /// The current step.
    public private(set) var currentStep: Step = .welcome

    /// Total visible steps for the progress indicator.
    public var totalSteps: Int {
        Step.allCases.count
    }

    /// The 0-based progress index derived from the step's raw value.
    public var progressIndex: Int {
        currentStep.rawValue
    }

    // MARK: - Per-step state

    /// Permission results (updated after each request).
    public private(set) var microphoneResult: PermissionState = .notDetermined
    public private(set) var systemAudioResult: SystemAudioPermissionState = .notRequested
    public private(set) var calendarResult: PermissionState = .notDetermined
    public private(set) var notificationsGranted: Bool = false

    /// True while a system-audio tone-probe is running.
    public private(set) var isValidatingSystemAudio: Bool = false

    /// True when the "Fix permissions" alert should be presented.
    public var showFixPermissionsAlert: Bool = false

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
        systemAudioResult == .approved
    }

    /// Whether calendar access has been granted in this session.
    public var calendarGranted: Bool {
        calendarResult == .authorized
    }

    /// Whether all four permissions have been granted.
    public var allPermissionsGranted: Bool {
        microphoneGranted && systemAudioGranted && calendarGranted && notificationsGranted
    }

    /// The footer button to display for a given step.
    public enum FooterButton: Equatable, Sendable {
        /// Show the primary "Continue" button (step action is done).
        case continueButton
        /// Show the secondary "Skip" button (step action is not done).
        case skip
    }

    /// Returns the footer button state for the given step.
    ///
    /// The Grant access screen shows "Skip" until all four permissions
    /// are granted, then "Continue". Model download shows "Skip"
    /// until download completes. Other screens always show Continue.
    public func footerButton(for step: Step) -> FooterButton {
        switch step {
        case .welcome, .calendarSelection, .done:
            .continueButton
        case .permissions:
            allPermissionsGranted ? .continueButton : .skip
        case .modelDownload:
            downloadComplete ? .continueButton : .skip
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
        await proceed()
    }

    /// Skip the current step without performing its action.
    public func skip() async {
        await proceed()
    }

    /// Request microphone permission. Called by the mic row's Grant control.
    public func requestMicrophone() async {
        let granted = await core.permissions.requestMicrophone()
        microphoneResult = granted ? .authorized : .denied
    }

    /// Request system audio permission with tone-probe validation.
    /// Called by the system audio row's Grant/Retry control.
    public func requestSystemAudio() async {
        isValidatingSystemAudio = true
        await core.requestSystemAudioPermission()
        systemAudioResult = core.permissions.systemAudio
        isValidatingSystemAudio = false
    }

    /// Request calendar access. Called by the calendar row's Grant control.
    public func requestCalendar() async {
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
    }

    /// Request notification permission. Called by the notifications row's Grant control.
    public func requestNotifications() async {
        let granted = await core.permissions
            .requestNotifications()
        notificationsGranted = granted
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

    /// Opens System Settings to the system-audio privacy pane.
    /// Delegates to the shared deeplink helper on `Permissions`.
    public func openSystemAudioSettings() {
        core.permissions.openSystemAudioSettings()
    }

    /// Complete onboarding: persist the flag and navigate to Home.
    public func completeOnboarding() async {
        await core.completeOnboarding()
    }

    /// Resets the wizard to the welcome step so it can be replayed
    /// from the beginning (e.g. via the debug "Replay Onboarding"
    /// button in Settings).
    public func resetForReplay() {
        currentStep = .welcome
        microphoneResult = .notDetermined
        systemAudioResult = .notRequested
        calendarResult = .notDetermined
        notificationsGranted = false
        isValidatingSystemAudio = false
        showFixPermissionsAlert = false
        calendarGroups = []
        enabledCalendarIDs = nil
        downloadStatus = nil
        isDownloading = false
        downloadComplete = false
        hasSufficientDisk = true
    }

    // MARK: - Private

    /// State-based forward navigation. Both `advance()` and `skip()`
    /// delegate here -- the destination depends only on `currentStep`
    /// and permission state, not on the user's button choice.
    private func proceed() async {
        switch currentStep {
        case .welcome:
            currentStep = .permissions
        case .permissions:
            if calendarResult == .authorized {
                let infos = await core.calendar.calendars()
                calendarGroups = Self.groupCalendars(infos)
                currentStep = .calendarSelection
            } else {
                checkDiskSpace()
                currentStep = .modelDownload
            }
        case .calendarSelection:
            checkDiskSpace()
            currentStep = .modelDownload
        case .modelDownload:
            currentStep = .done
        case .done:
            await completeOnboarding()
        }
        syncLivePermissionState()
    }

    /// Reads the live system permission state for the current step
    /// so that already-granted permissions show the checkmark
    /// immediately (e.g. when re-running onboarding or when the
    /// user granted the permission outside the wizard).
    private func syncLivePermissionState() {
        switch currentStep {
        case .permissions:
            microphoneResult = core.permissions.microphone
            systemAudioResult = core.permissions.systemAudio
            switch core.calendar.auth {
            case .authorized:
                calendarResult = .authorized
            case .denied, .restricted:
                calendarResult = .denied
            case .notDetermined:
                calendarResult = .notDetermined
            }
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

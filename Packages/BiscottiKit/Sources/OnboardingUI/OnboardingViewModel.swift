import AppCore
import AppKit
import Calendar
import DataStore
import Foundation
import Intelligence
import LocalLLM
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
    /// Setters are internal so calendar-related extensions within the
    /// module can mutate them.
    public internal(set) var calendarGroups: [OnboardingCalendarGroup] = []
    public internal(set) var enabledCalendarIDs: Set<String>?

    /// Model download state (transcription).
    public private(set) var downloadStatus: String?
    public internal(set) var isDownloading: Bool = false
    public private(set) var downloadComplete: Bool = false
    public private(set) var downloadFailed: Bool = false

    /// True when transcription models were already on disk when the step
    /// was entered (set by `prepareModelStep()`).
    public private(set) var transcriptionDownloaded: Bool = false

    /// True while `prepareModelStep()` is probing readiness/disk in the
    /// background. Model rows show a spinner while set.
    public internal(set) var isPreparingModelStep: Bool = false

    /// Presentation state for the "See all options" Manage Models sheet.
    public var showVariantSheet: Bool = false

    /// Presentation state for the "Connect a calendar" how-to sheet.
    public var showConnectCalendarSheet: Bool = false

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

    // MARK: - AppCore exposure (for sheet construction)

    /// Read-only access to the application core, used by the view to
    /// construct `ManageModelsViewModel(core:)` for the variant sheet.
    public var appCore: AppCore {
        core
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
            bothModelsStarted ? .continueButton : .skip
        }
    }

    /// Whether the current step's gated action is complete.
    public var isCurrentStepComplete: Bool {
        footerButton(for: currentStep) == .continueButton
    }

    /// Disk space check for the model download step.
    public private(set) var hasSufficientDisk: Bool = true

    /// Approximate disk space required for the transcription model (MB).
    /// Aligned with the ~1.5 GB WhisperKit model bundle.
    public static let requiredDiskSpaceMB: Int = 1500

    /// Pre-warm task that runs model probes early (on the permissions
    /// screen) so the model-download screen arrives spinner-free when
    /// probes finish in time. Nil until `beginModelPrep()` is called.
    private var modelPrepTask: Task<Void, Never>?

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

    /// Start the transcription model download.
    public func startTranscriptionDownload() async {
        isDownloading = true
        downloadFailed = false
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
            downloadFailed = true
            downloadStatus =
                "Download failed. You can retry or skip."
        }
        isDownloading = false
    }

    /// Start the language model download for the current target model.
    public func startLanguageDownload() {
        guard let targetID = languageTargetModelID else { return }
        Task {
            await core.modelManager.downloadModel(id: targetID)
        }
    }

    /// Reload the calendar list from EventKit. Called when the app
    /// returns to the foreground while on the calendar-selection step,
    /// so newly added accounts appear without restarting.
    public func reloadCalendars() async {
        guard currentStep == .calendarSelection else { return }
        let infos = await core.calendar.calendars()
        calendarGroups = Self.groupCalendars(infos)
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
        modelPrepTask?.cancel()
        modelPrepTask = nil
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
        downloadFailed = false
        transcriptionDownloaded = false
        isPreparingModelStep = false
        showVariantSheet = false
        showConnectCalendarSheet = false
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
            beginModelPrep()
        case .permissions:
            if calendarResult == .authorized {
                let infos = await core.calendar.calendars()
                calendarGroups = Self.groupCalendars(infos)
                currentStep = .calendarSelection
            } else {
                currentStep = .modelDownload
                beginModelPrep()
                await modelPrepTask?.value
            }
        case .calendarSelection:
            currentStep = .modelDownload
            beginModelPrep()
            await modelPrepTask?.value
        case .modelDownload:
            currentStep = .done
        case .done:
            await completeOnboarding()
        }
        syncLivePermissionState()
    }

    /// Idempotently starts background model probes. The pre-warm begins
    /// on the permissions screen (`.welcome -> .permissions` transition)
    /// so that by the time the user reaches the model-download screen the
    /// probes are usually finished and rows show final state immediately.
    ///
    /// If the model-download screen is reached before the task completes,
    /// the transition `await`s `modelPrepTask?.value` so the screen
    /// paints with spinners (the `currentStep` is already set before
    /// the await) and the caller does not return until probes finish.
    private func beginModelPrep() {
        guard modelPrepTask == nil else { return }
        isPreparingModelStep = true
        modelPrepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isPreparingModelStep = false }
            await runModelProbes()
        }
    }

    /// Runs the actual model probes: ModelManager refresh, read-only
    /// transcription presence check, and disk space check.
    private func runModelProbes() async {
        await core.modelManager.refresh()
        transcriptionDownloaded = await core.transcription.modelsArePresent()
        checkDiskSpace()
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
}

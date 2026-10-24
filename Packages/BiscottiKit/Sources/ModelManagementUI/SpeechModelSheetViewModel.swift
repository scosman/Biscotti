import AppCore
import DataStore
import Foundation
import TranscriptionService

/// Presentation state for a pending Apple action blocked by the vocabulary alert.
enum PendingAppleAction {
    case choose
    case download
}

/// View model for the Speech to Text Model sheet.
///
/// Delegates all engine state to `SpeechEngineManager` via `AppCore` and
/// owns only ephemeral presentation state (alerts, pending actions).
@MainActor @Observable
public final class SpeechModelSheetViewModel {
    private let core: AppCore
    private var engines: SpeechEngineManager {
        core.speechEngines
    }

    // MARK: - Reads

    /// Row data for the sheet, built from the current engine snapshot.
    public var rows: [SpeechEngineRow] {
        SpeechEngineRowBuilder.rows(snapshot)
    }

    /// Supported Apple locales for the picker.
    public var localeOptions: [AppleLocaleOption] {
        engines.appleLocales
    }

    /// Currently resolved Apple locale.
    public var selectedLocale: String {
        engines.appleLocale
    }

    /// Whether the user's custom vocabulary preference is effectively on.
    /// Loaded in `onAppear` from persisted settings.
    public private(set) var vocabularyStoredOn = false

    // MARK: - Presentation state

    /// "Apple Speech requires macOS 26" alert.
    public var showLearnMore = false

    /// "Turn Off Custom Vocabulary?" alert.
    public var showTurnOffVocabulary = false

    /// "Delete Whisper?" confirmation dialog.
    public var showDeleteWhisper = false

    /// Stashed Apple action awaiting the vocabulary alert decision.
    private var pendingAppleAction: PendingAppleAction?

    // MARK: - Init

    public init(core: AppCore) {
        self.core = core
    }

    // MARK: - Lifecycle

    /// Refresh engine state and load the vocabulary preference.
    public func onAppear() async {
        await engines.refresh()
        let settings = await (try? core.store.settings()) ?? AppSettingsData()
        vocabularyStoredOn = settings.customVocabularyResolved
    }

    // MARK: - Actions

    /// Tap the Download button for an engine.
    public func tapDownload(_ engine: SpeechEngine) {
        if engine == .apple, shouldGuardVocabulary {
            pendingAppleAction = .download
            showTurnOffVocabulary = true
            return
        }
        Task { await engines.download(engine) }
    }

    /// Tap the Retry button (same as download).
    public func tapRetry(_ engine: SpeechEngine) {
        tapDownload(engine)
    }

    /// Tap the Choose Model button for an engine.
    public func tapChoose(_ engine: SpeechEngine) {
        if engine == .apple, shouldGuardVocabulary {
            pendingAppleAction = .choose
            showTurnOffVocabulary = true
            return
        }
        Task { await engines.choose(engine) }
    }

    /// Stage the Whisper delete confirmation.
    public func tapDelete() {
        showDeleteWhisper = true
    }

    /// Execute the Whisper deletion.
    public func confirmDelete() {
        showDeleteWhisper = false
        Task { await engines.deleteWhisper() }
    }

    /// Execute the stashed Apple action after the user confirms vocabulary off.
    public func confirmTurnOffVocabulary() {
        showTurnOffVocabulary = false
        guard let action = pendingAppleAction else { return }
        pendingAppleAction = nil
        switch action {
        case .download:
            Task { await engines.download(.apple) }
        case .choose:
            Task { await engines.choose(.apple) }
        }
    }

    /// Cancel the vocabulary alert without executing the action.
    public func cancelTurnOffVocabulary() {
        showTurnOffVocabulary = false
        pendingAppleAction = nil
    }

    /// Change the Apple locale.
    public func setLocale(_ id: String) {
        Task { await engines.setAppleLocale(id) }
    }

    // MARK: - Alert messages

    /// Message for the Whisper delete confirmation dialog.
    public var deleteMessage: String {
        var base = "This frees about 626 MB. You can download it again anytime."
        if vocabularyStoredOn, engines.appleAvailability == .available, engines.target == .whisper {
            base += " Custom vocabulary turns off until you switch back to Whisper."
        }
        return base
    }

    /// Message for the "Apple Speech requires macOS 26" learn-more alert.
    public var learnMoreMessage: String {
        "This Mac is running macOS \(engines.osMajorVersion). Update macOS to use Apple\u{2019}s built-in speech model. Whisper works on this Mac today."
    }

    // MARK: - Private

    /// Whether effective custom vocabulary is on and switching to Apple should show the alert.
    /// No alert when Apple is already the target (the toggle is already off).
    private var shouldGuardVocabulary: Bool {
        engines.effectiveCustomVocabulary(storedPreference: vocabularyStoredOn)
    }

    /// Builds a snapshot from the current engine manager state.
    private var snapshot: SpeechEngineSnapshot {
        SpeechEngineSnapshot(
            availability: engines.appleAvailability,
            recommended: engines.recommended,
            target: engines.target,
            apple: engines.apple,
            whisper: engines.whisper,
            hasEnoughDiskForWhisper: engines.hasEnoughDiskForWhisper,
            isAnyDownloadInFlight: engines.isAnyDownloadInFlight,
            isJobInFlight: core.transcription.isJobInFlight,
            osMajor: engines.osMajorVersion
        )
    }
}

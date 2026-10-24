import DataStore
import Foundation
import os
import Transcription

/// Single owner of speech-engine state in the app process.
///
/// Mirrors `Intelligence.ModelManager` for LLMs. Onboarding, the STT sheet,
/// and Settings all read and act through this. The manager uses its own
/// `Transcriber` (via the `Transcribing` seam) for downloads/presence/delete
/// so a job's `shutdown()` never cuts a sheet download.
@MainActor @Observable
public final class SpeechEngineManager {
    // MARK: - Observable state

    /// User's explicit engine choice. `nil` = no explicit choice (follow recommendation).
    public private(set) var selection: SpeechEngine?

    /// Current Apple Speech availability.
    public private(set) var appleAvailability: AppleSpeechAvailability = .requiresOSUpdate(
        currentMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    )

    /// Sorted list of supported Apple locales for the picker.
    public private(set) var appleLocales: [AppleLocaleOption] = []

    /// Resolved Apple locale (stored if valid, else computed default).
    public private(set) var appleLocale: String = "en_US"

    /// Apple asset download/install state.
    public package(set) var apple: EngineDownloadState = .notDownloaded

    /// Whisper model download state.
    public package(set) var whisper: EngineDownloadState = .notDownloaded

    /// Speaker ID model download state.
    public package(set) var speakerID: EngineDownloadState = .notDownloaded

    /// Whether enough disk space is available for Whisper (~750 MB).
    public private(set) var hasEnoughDiskForWhisper: Bool = true

    /// Whether Apple supports the current system language.
    public private(set) var languageSupported: Bool = false

    // MARK: - Derived

    /// The recommended engine based on availability and language support.
    public var recommended: SpeechEngine {
        SpeechEnginePolicy.recommended(
            availability: appleAvailability,
            languageSupported: languageSupported
        )
    }

    /// The engine that transcribes new meetings.
    /// Selection if set (and Apple is available when apple is selected), else recommended.
    public var target: SpeechEngine {
        if let selection {
            // If apple is selected but unavailable, fall back to whisper
            if selection == .apple, case .available = appleAvailability {
                return .apple
            } else if selection == .apple {
                return .whisper
            }
            return selection
        }
        return recommended
    }

    /// Whether the given engine is ready to transcribe.
    public func isReady(_ engine: SpeechEngine) -> Bool {
        switch engine {
        case .apple:
            if case .available = appleAvailability, apple == .downloaded {
                return true
            }
            return false
        case .whisper:
            return whisper == .downloaded
        }
    }

    /// Whether the current target engine is ready.
    public var targetReady: Bool {
        isReady(target)
    }

    /// Whether any download is in flight (apple, whisper, or speaker ID).
    public var isAnyDownloadInFlight: Bool {
        isDownloading(apple) || isDownloading(whisper) || isDownloading(speakerID)
    }

    /// The language name from the resolved locale.
    public var appleLanguageName: String {
        appleLocales.first(where: { $0.id == appleLocale })?.languageName
            ?? Locale.current.localizedString(
                forLanguageCode: Locale(identifier: appleLocale)
                    .language.languageCode?.identifier ?? ""
            )
            ?? "English"
    }

    /// Summary label for the current target engine (used in Settings/onboarding).
    /// Apple format: "Apple Speech ({Language} only)". Whisper: "Whisper".
    public var summaryLabel: String {
        switch target {
        case .apple:
            "Apple Speech (\(appleLanguageName) only)"
        case .whisper:
            "Whisper"
        }
    }

    /// Current macOS major version.
    public var osMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// Config for a transcription job using the current target engine.
    public func jobConfig() -> TranscriptionConfig {
        switch target {
        case .apple:
            .apple(locale: appleLocale)
        case .whisper:
            .whisper()
        }
    }

    /// Model components needed by the current target engine.
    public func jobComponents() -> Set<ModelComponent> {
        switch target {
        case .apple:
            [.speakerID]
        case .whisper:
            .all
        }
    }

    /// Whether custom vocabulary is effectively on.
    /// Returns true only when the stored preference is on AND target is Whisper.
    public func effectiveCustomVocabulary(storedPreference: Bool) -> Bool {
        storedPreference && target == .whisper
    }

    // MARK: - Dependencies

    private let store: DataStore
    private let transcriber: any Transcribing
    private let appleProvider: any AppleSpeechProviding
    private let diskProbe: @Sendable () -> Int64?
    private let isJobInFlightFn: @MainActor () -> Bool
    private let logger = Logger(
        subsystem: "net.scosman.biscotti",
        category: "SpeechEngineManager"
    )

    private static let whisperDiskMinimumBytes: Int64 = 750 * 1_048_576

    // MARK: - Init

    public init(
        store: DataStore,
        transcriber: any Transcribing,
        apple: any AppleSpeechProviding,
        diskProbe: @escaping @Sendable () -> Int64?,
        isJobInFlight: @escaping @MainActor () -> Bool
    ) {
        self.store = store
        self.transcriber = transcriber
        appleProvider = apple
        self.diskProbe = diskProbe
        isJobInFlightFn = isJobInFlight
    }

    // MARK: - Refresh

    /// Recomputes all state from live sources and persistence.
    /// Called on launch, Settings load, sheet open, onboarding model step.
    public func refresh() async {
        // 1. Apple availability + locales
        appleAvailability = appleProvider.availability()
        var supported: [String] = []
        if case .available = appleAvailability {
            supported = await appleProvider.supportedLocales()
            appleLocales = AppleLocalePolicy.options(for: supported)
            languageSupported = AppleLocalePolicy.languageSupported(
                current: .current, supported: supported
            )
        } else {
            appleLocales = []
            languageSupported = false
        }

        // 2. Load settings
        let settings = await (try? store.settings()) ?? AppSettingsData()
        selection = SpeechEngine(rawValue: settings.sttEngineSelection)

        // 3. Resolve apple locale
        let storedLocale = settings.appleSpeechLocale
        if !storedLocale.isEmpty, supported.contains(storedLocale) {
            appleLocale = storedLocale
        } else {
            let equivalent = await appleProvider.supportedLocale(
                equivalentTo: Locale.current.identifier
            )
            appleLocale = AppleLocalePolicy.defaultLocale(
                current: .current,
                supported: supported,
                equivalent: equivalent
            )
        }

        // 4. Download states (keep in-flight untouched)
        if !isDownloading(whisper) {
            whisper = await transcriber.modelsPresent([.whisper]) ? .downloaded : .notDownloaded
        }
        if !isDownloading(speakerID) {
            speakerID = await transcriber.modelsPresent([.speakerID]) ? .downloaded : .notDownloaded
        }
        if !isDownloading(apple), case .available = appleAvailability {
            apple = await appleProvider.assetsInstalled(locale: appleLocale)
                ? .downloaded : .notDownloaded
        } else if !isDownloading(apple) {
            apple = .notDownloaded
        }

        // 5. Disk probe
        hasEnoughDiskForWhisper = (diskProbe() ?? .max) >= Self.whisperDiskMinimumBytes

        // 6. Migration: existing user with Whisper -> pin selection
        if selection == nil, settings.onboardingComplete, whisper == .downloaded {
            await writeSelection(.whisper)
        }
    }

    // MARK: - Private

    /// Sets selection, persists `sttEngineSelection`. When the engine is
    /// `.apple`, also persists `appleSpeechLocale` if the stored value is empty.
    private func writeSelection(_ engine: SpeechEngine) async {
        selection = engine
        let locale = appleLocale
        do {
            try await store.updateSettings { settings in
                settings.sttEngineSelection = engine.rawValue
                if engine == .apple, settings.appleSpeechLocale.isEmpty {
                    settings.appleSpeechLocale = locale
                }
            }
        } catch {
            logger.error("Failed to persist engine selection: \(error)")
        }
    }

    private func isDownloading(_ state: EngineDownloadState) -> Bool {
        if case .downloading = state { return true }
        return false
    }
}

// MARK: - Actions (extracted for lint body-length + cyclomatic-complexity)

public extension SpeechEngineManager {
    /// Download an engine. Saves selection immediately before the download starts.
    func download(_ engine: SpeechEngine) async {
        guard !isAnyDownloadInFlight else { return }
        switch engine {
        case .whisper:
            guard hasEnoughDiskForWhisper else { return }
        case .apple:
            guard case .available = appleAvailability else { return }
        }
        await writeSelection(engine)
        switch engine {
        case .whisper: await downloadWhisperModels()
        case .apple: await downloadAppleAssets()
        }
    }

    /// Select an already-ready engine. Requires `isReady(engine)`.
    func choose(_ engine: SpeechEngine) async {
        guard isReady(engine) else { return }
        await writeSelection(engine)
    }

    /// Delete Whisper model files.
    func deleteWhisper() async {
        guard whisper == .downloaded, !isJobInFlightFn() else { return }
        do {
            try await transcriber.deleteModels([.whisper])
            whisper = .notDownloaded
        } catch {
            logger.error("deleteWhisper failed: \(error)")
            whisper = await transcriber.modelsPresent([.whisper]) ? .downloaded : .notDownloaded
            return
        }
        await transcriber.shutdown()
        // If Whisper was the target, fall back to Apple if available
        if selection == .whisper || (selection == nil && recommended == .whisper) {
            if case .available = appleAvailability {
                await writeSelection(.apple)
            }
        }
    }

    /// Change the Apple locale. Persists and re-checks assets.
    func setAppleLocale(_ id: String) async {
        guard appleLocales.contains(where: { $0.id == id }) else { return }
        appleLocale = id
        do {
            try await store.updateSettings { $0.appleSpeechLocale = id }
        } catch {
            logger.error("Failed to persist Apple locale: \(error)")
        }
        apple = await appleProvider.assetsInstalled(locale: id)
            ? .downloaded : .notDownloaded
    }

    /// Download Speaker ID models independently.
    func downloadSpeakerID() async {
        guard !isAnyDownloadInFlight else { return }
        speakerID = .downloading(fraction: nil)
        do {
            try await transcriber.ensureModelsDownloaded([.speakerID], status: nil)
            speakerID = .downloaded
        } catch is CancellationError {
            speakerID = .notDownloaded
        } catch {
            speakerID = .failed(message: error.localizedDescription)
        }
        await transcriber.shutdown()
    }

    /// Persist the target engine as the selection if no explicit choice was made.
    func persistTargetIfUnset() async {
        guard selection == nil else { return }
        await writeSelection(target)
    }

    /// Downloads Whisper models. Extracted from `download(_:)` for lint.
    internal func downloadWhisperModels() async {
        whisper = .downloading(fraction: nil)
        do {
            try await transcriber.ensureModelsDownloaded([.whisper], status: nil)
            whisper = .downloaded
        } catch is CancellationError {
            whisper = .notDownloaded
        } catch {
            whisper = .failed(message: error.localizedDescription)
        }
        await transcriber.shutdown()
    }

    /// Installs Apple assets. Extracted from `download(_:)` for lint.
    internal func downloadAppleAssets() async {
        apple = .downloading(fraction: nil)
        do {
            try await appleProvider.installAssets(
                locale: appleLocale
            ) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .downloading = apple {
                        apple = .downloading(fraction: fraction)
                    }
                }
            }
            apple = .downloaded
        } catch is CancellationError {
            apple = .notDownloaded
        } catch {
            apple = .failed(message: error.localizedDescription)
        }
    }
}

import Intelligence
import LocalLLM
import TranscriptionService

/// Progress style for a model download row.
enum RowDownloadProgress: Equatable {
    /// Indeterminate bar + optional status string (transcription).
    case indeterminate(status: String?)
    /// Determinate bar with optional fraction (language). Nil fraction
    /// falls back to an indeterminate spinner in the UI.
    case determinate(fraction: Double?)
}

/// The view-state for a single model download row. Computed by the
/// view model from observable state so SwiftUI re-renders on change.
enum ModelRowState: Equatable {
    /// Not yet downloaded, enough disk. Caption shows the approximate size.
    case idle(sizeCaption: String)
    /// Not enough free disk space to download this model.
    case insufficientDisk
    /// Download in progress.
    case downloading(RowDownloadProgress)
    /// Model is downloaded and ready to use. Optional caption (e.g. "Built in")
    /// renders below the READY tag.
    case ready(caption: String? = nil)
    /// Download failed; message describes the error.
    case failed(message: String)
    /// Probing readiness / disk space in the background.
    case checking
}

// MARK: - Model download derivation + row-state mappers

public extension OnboardingViewModel {
    // MARK: - Transcription row (engine-aware)

    /// Whether the target transcription engine is ready.
    var transcriptionReady: Bool {
        appCore.speechEngines.targetReady
    }

    /// Whether the transcription download has started (ready or downloading).
    var transcriptionStarted: Bool {
        if transcriptionReady { return true }
        let state = targetEngineState
        if case .downloading = state { return true }
        return false
    }

    // MARK: - Speaker ID row

    /// Whether Speaker ID models are ready.
    var speakerIDReady: Bool {
        appCore.speechEngines.speakerID == .downloaded
    }

    /// Whether the Speaker ID download has started (ready or downloading).
    var speakerIDStarted: Bool {
        if speakerIDReady { return true }
        if case .downloading = appCore.speechEngines.speakerID { return true }
        return false
    }

    // MARK: - Language row derivation

    /// The language model id the onboarding row targets, resolved in
    /// priority order so the row tracks the user's effective choice:
    ///
    /// 1. An actively **downloading** model (`.downloading`) -- the user's
    ///    current action, always wins.
    /// 2. `activeModelID` -- a downloaded + selected/fallback model. Checked
    ///    before `.failed` so a stale failure doesn't shadow a working model.
    /// 3. A **failed** download (`.failed`) -- shows the error for retry when
    ///    no active model exists yet.
    /// 4. `selectedModelID` if non-empty and a valid catalog model id
    ///    (explicit user selection, even if mid-state).
    /// 5. `recommendedModelID()` -- hardware-based default.
    var languageTargetModelID: String? {
        if let downloading = languageDownloadingModelID {
            return downloading
        }
        if let active = appCore.modelManager.activeModelID {
            return active
        }
        if let failed = languageFailedModelID {
            return failed
        }
        let sel = appCore.modelManager.selectedModelID
        if !sel.isEmpty, LLMModelCatalog.model(id: sel) != nil {
            return sel
        }
        return appCore.modelManager.recommendedModelID()
    }

    /// Display name of the target language model.
    var languageTargetDisplayName: String? {
        guard let id = languageTargetModelID else { return nil }
        return LLMModelCatalog.model(id: id)?.displayName
    }

    // MARK: - Private helpers

    /// The model id whose download is actively in progress (`.downloading`),
    /// if any. Iterates the catalog in display order for deterministic results
    /// (dictionary iteration order is not stable).
    private var languageDownloadingModelID: String? {
        for model in LLMModelCatalog.all {
            if case .downloading = appCore.modelManager.downloads[model.id] {
                return model.id
            }
        }
        return nil
    }

    /// The first model id in catalog order whose download has failed
    /// (`.failed`), if any. Deterministic via catalog-order iteration.
    private var languageFailedModelID: String? {
        for model in LLMModelCatalog.all {
            if case .failed = appCore.modelManager.downloads[model.id] {
                return model.id
            }
        }
        return nil
    }

    /// Whether a language model is downloaded and available.
    var languageReady: Bool {
        appCore.modelManager.isModelAvailable
    }

    /// Whether the language model has started (ready or actively downloading).
    ///
    /// Intentionally checks only `.downloading`, not `.failed`. A failed
    /// attempt should not flip the footer to "Continue" -- the user needs
    /// to retry or skip. Note that `languageTargetModelID` *can* resolve
    /// to a `.failed` model (priority 3), so the target and "started"
    /// may diverge; that is the desired behavior.
    var languageStarted: Bool {
        if languageReady { return true }
        guard let targetID = languageTargetModelID else { return false }
        if case .downloading = appCore.modelManager.downloads[targetID] {
            return true
        }
        return false
    }

    /// Whether all three model classes are ready.
    var allModelsReady: Bool {
        transcriptionReady && speakerIDReady && languageReady
    }

    /// Whether all three model downloads have at least started (each is
    /// either ready or actively downloading). Used by the footer to
    /// show "Continue" without waiting for completion.
    var allModelsStarted: Bool {
        transcriptionStarted && speakerIDStarted && languageStarted
    }

    // MARK: - Footer caption

    /// Caption shown beneath the footer button. Non-empty only on the
    /// model-download step when "Continue" is available (all models
    /// started) but at least one download is still in progress.
    var footerCaption: String {
        guard currentStep == .modelDownload, allModelsStarted, !allModelsReady else {
            return ""
        }
        return "Downloads will continue in the background"
    }

    // MARK: - Private engine state helper

    /// The download state of the current target engine.
    private var targetEngineState: EngineDownloadState {
        switch appCore.speechEngines.target {
        case .apple: appCore.speechEngines.apple
        case .whisper: appCore.speechEngines.whisper
        }
    }

    // MARK: - Row-state mappers

    /// Computes the view-state for the transcription model row.
    internal func transcriptionRowState() -> ModelRowState {
        let engines = appCore.speechEngines
        let target = engines.target

        if transcriptionReady {
            return .ready(caption: target == .apple ? "Built in" : nil)
        }

        let state = targetEngineState
        switch state {
        case let .downloading(fraction):
            if target == .apple {
                return .downloading(.determinate(fraction: fraction))
            }
            return .downloading(.indeterminate(status: "Downloading\u{2026}"))

        case let .failed(message):
            return .failed(message: message)

        default:
            break
        }

        if isPreparingModelStep {
            return .checking
        }

        // Whisper: check disk
        if target == .whisper, !engines.hasEnoughDiskForWhisper {
            return .insufficientDisk
        }

        return .idle(
            sizeCaption: target == .apple ? "System download" : "626 MB"
        )
    }

    /// Computes the view-state for the Speaker ID model row.
    internal func speakerIDRowState() -> ModelRowState {
        if speakerIDReady {
            return .ready()
        }

        let state = appCore.speechEngines.speakerID
        switch state {
        case .downloading:
            return .downloading(.indeterminate(status: "Downloading\u{2026}"))

        case let .failed(message):
            return .failed(message: message)

        default:
            break
        }

        if isPreparingModelStep {
            return .checking
        }

        return .idle(sizeCaption: "~11 MB")
    }

    /// Computes the view-state for the language model row.
    internal func languageRowState() -> ModelRowState {
        if languageReady {
            return .ready()
        }

        guard let targetID = languageTargetModelID else {
            return isPreparingModelStep ? .checking : .idle(sizeCaption: "")
        }

        // Check in-flight download state
        if let state = appCore.modelManager.downloads[targetID] {
            switch state {
            case let .downloading(fraction):
                return .downloading(.determinate(fraction: fraction))
            case let .failed(message):
                return .failed(message: message)
            case .downloaded, .notDownloaded, .unknown:
                break
            }
        }

        if isPreparingModelStep {
            return .checking
        }

        // Check disk block via model choices
        let choices = appCore.modelManager.modelChoices()
        if let choice = choices.first(where: { $0.id == targetID }),
           choice.blockedReason == .insufficientDisk
        {
            return .insufficientDisk
        }

        // Idle: show approximate download size
        let sizeCaption: String = if let model = LLMModelCatalog.model(id: targetID) {
            Self.formatBytes(model.approxDownloadBytes)
        } else {
            ""
        }
        return .idle(sizeCaption: sizeCaption)
    }

    /// Formats a byte count to a human-readable "~N.N GB" string.
    internal static func formatBytes(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes == gigabytes.rounded() {
            return "~\(Int(gigabytes)) GB"
        }
        return String(format: "~%.1f GB", gigabytes)
    }
}

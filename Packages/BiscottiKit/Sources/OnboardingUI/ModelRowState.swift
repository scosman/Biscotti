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
    /// Not yet downloaded. Caption shows the approximate size.
    case idle(sizeCaption: String)
    /// Download in progress.
    case downloading(RowDownloadProgress)
    /// Model is downloaded and ready to use.
    case ready
    /// Download failed; message describes the error.
    case failed(message: String)
    /// Probing readiness in the background.
    case checking
}

// MARK: - Model download derivation + row-state mappers

public extension OnboardingViewModel {
    // MARK: - Transcription row derivation

    /// Whether the transcription model is ready (already cached or just
    /// downloaded).
    var transcriptionReady: Bool {
        transcriptionDownloaded || downloadComplete
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

    /// Whether the current target is the hardware-recommended model.
    var languageTargetIsRecommended: Bool {
        languageTargetModelID == appCore.modelManager.recommendedModelID()
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

    /// Whether both model classes are ready (transcription + language).
    var bothModelsReady: Bool {
        transcriptionReady && languageReady
    }

    // MARK: - "Started" derivation (ready OR actively downloading)

    /// Whether the transcription model has started (ready or downloading).
    var transcriptionStarted: Bool {
        transcriptionReady || isDownloading
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

    /// Whether both model downloads have at least started (each is
    /// either ready or actively downloading). Used by the footer to
    /// show "Continue" without waiting for completion.
    var bothModelsStarted: Bool {
        transcriptionStarted && languageStarted
    }

    // MARK: - Footer caption

    /// Caption shown beneath the footer button. Non-empty only on the
    /// model-download step when "Continue" is available (both models
    /// started) but at least one download is still in progress.
    var footerCaption: String {
        guard currentStep == .modelDownload, bothModelsStarted, !bothModelsReady else {
            return ""
        }
        return "Downloads will continue in the background"
    }

    // MARK: - Row-state mappers

    /// Computes the view-state for the transcription model row.
    internal func transcriptionRowState() -> ModelRowState {
        if transcriptionReady {
            return .ready
        }
        if isDownloading {
            return .downloading(
                .indeterminate(status: downloadStatus)
            )
        }
        if isPreparingModelStep {
            return .checking
        }
        if downloadFailed, let status = downloadStatus {
            return .failed(message: status)
        }
        let estimatedBytes = appCore.transcription.estimatedModelDownloadBytes
        return .idle(sizeCaption: ModelDiskPolicy.formatBytes(estimatedBytes))
    }

    /// Computes the view-state for the language model row.
    internal func languageRowState() -> ModelRowState {
        if languageReady {
            return .ready
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

        // Idle: show approximate download size
        let sizeCaption: String = if let model = LLMModelCatalog.model(id: targetID) {
            ModelDiskPolicy.formatBytes(model.approxDownloadBytes)
        } else {
            ""
        }
        return .idle(sizeCaption: sizeCaption)
    }
}

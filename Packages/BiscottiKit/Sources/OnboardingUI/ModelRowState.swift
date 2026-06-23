import Intelligence
import LocalLLM

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
    /// Model is downloaded and ready to use.
    case ready
    /// Download failed; message describes the error.
    case failed(message: String)
    /// Probing readiness / disk space in the background.
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

    /// Whether the transcription model cannot be downloaded due to disk.
    internal var transcriptionInsufficientDisk: Bool {
        !hasSufficientDisk
    }

    // MARK: - Language row derivation

    /// The language model id the "Download" pill targets: the active
    /// model if one is already downloaded, else the recommended model.
    var languageTargetModelID: String? {
        appCore.modelManager.activeModelID
            ?? appCore.modelManager.recommendedModelID()
    }

    /// Display name of the hardware-recommended language model.
    var recommendedLanguageDisplayName: String? {
        guard let id = appCore.modelManager.recommendedModelID() else {
            return nil
        }
        return LLMModelCatalog.model(id: id)?.displayName
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
        if transcriptionInsufficientDisk {
            return .insufficientDisk
        }
        if downloadFailed, let status = downloadStatus {
            return .failed(message: status)
        }
        return .idle(sizeCaption: "~1.5 GB")
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

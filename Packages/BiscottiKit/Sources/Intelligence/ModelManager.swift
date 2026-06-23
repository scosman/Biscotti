import DataStore
import Foundation
import LocalLLM
import os

// MARK: - ModelChoice & ModelBlockedReason

/// Why a model row is blocked (cannot be downloaded or selected).
public enum ModelBlockedReason: Sendable, Equatable {
    /// The Mac does not have enough RAM to run this model.
    case cannotRun
    /// Not enough free disk space to download this model.
    case insufficientDisk
}

/// A per-model view value assembled for the Manage Models sheet.
/// Not persisted; recomputed each time the sheet appears.
public struct ModelChoice: Sendable, Identifiable, Equatable {
    public let model: LLMModel
    public let description: String
    public let isRecommended: Bool
    public let runnable: Bool
    public let hasEnoughDiskToDownload: Bool
    public let isDownloaded: Bool
    public let isSelected: Bool
    public let downloadState: ModelDownloadState
    public var id: String {
        model.id
    }

    /// The reason this model is blocked, if any.
    public var blockedReason: ModelBlockedReason? {
        if !runnable { return .cannotRun }
        if !isDownloaded, !hasEnoughDiskToDownload { return .insufficientDisk }
        return nil
    }
}

// MARK: - ModelManager

/// The in-process owner of all model state: per-model download status,
/// selection, suitability, and the `modelChoices` matrix for the UI.
///
/// Replaces `Intelligence`'s former `download`, `downloadModel`,
/// `refreshModelState`, `isModelDownloaded`, and single-model coupling.
/// Observed by Settings (parallels how `Intelligence.download` was observed).
@MainActor @Observable
public final class ModelManager {
    // MARK: - Observable state

    /// Per-model download lifecycle state, keyed by model id.
    public package(set) var downloads: [String: ModelDownloadState] = [:]

    /// Cached mirror of the persisted `selectedModelID` setting.
    /// Updated by `refresh()` and `selectModel(id:)`.
    public private(set) var selectedModelID: String = ""

    // MARK: - Dependencies

    private let store: DataStore
    private let models: any ModelProviding
    private let hardware: any HardwareProbing

    private let logger = Logger(
        subsystem: "net.scosman.biscotti",
        category: "ModelManager"
    )

    // MARK: - Init

    public init(
        store: DataStore,
        models: any ModelProviding,
        hardware: any HardwareProbing
    ) {
        self.store = store
        self.models = models
        self.hardware = hardware
    }

    // MARK: - Derived reads

    /// Whether any model is available for AI analysis (active model exists).
    public var isModelAvailable: Bool {
        activeModelID != nil
    }

    /// The active model id resolved from downloads + selection.
    ///
    /// 1. If `selectedModelID` names a downloaded catalog model, that id.
    /// 2. Else the first downloaded model in catalog order.
    /// 3. Else `nil`.
    public var activeModelID: String? {
        let sel = selectedModelID
        if !sel.isEmpty,
           downloads[sel] == .downloaded
        {
            return sel
        }
        // Fallback: first downloaded in catalog order
        for model in models.catalog where downloads[model.id] == .downloaded {
            return model.id
        }
        return nil
    }

    /// The on-disk URL for the active model, or `nil` if none.
    public func activeModelURL() -> URL? {
        guard let id = activeModelID else { return nil }
        return models.url(for: id)
    }

    /// The recommended model id for this hardware, delegating to
    /// `ModelSuitability` with the injected hardware probe's RAM.
    public func recommendedModelID() -> String? {
        ModelSuitability.recommendedModelID(
            catalog: models.catalog, ram: hardware.physicalMemoryBytes
        )
    }

    /// Assembles the per-model choice matrix for the Manage Models sheet.
    public func modelChoices() -> [ModelChoice] {
        let ram = hardware.physicalMemoryBytes
        // Assumes all models share one cache directory; uses the first
        // model's URL to query available disk space.
        let cacheDir = models.url(for: models.catalog.first?.id ?? "")
        let freeBytes: Int64? = if let cacheDir {
            hardware.availableDiskBytes(at: cacheDir)
        } else {
            nil
        }
        let recommendedID = ModelSuitability.recommendedModelID(
            catalog: models.catalog, ram: ram
        )
        let activeID = activeModelID

        return models.catalog.map { model in
            let downloaded = downloads[model.id] == .downloaded
            let runnable = ModelSuitability.canRun(model, ram: ram)
            let enoughDisk = ModelSuitability.hasEnoughDisk(model, freeBytes: freeBytes)
            let state = downloads[model.id] ?? .notDownloaded

            return ModelChoice(
                model: model,
                description: ModelPolicy.description(id: model.id),
                isRecommended: model.id == recommendedID,
                runnable: runnable,
                hasEnoughDiskToDownload: enoughDisk,
                isDownloaded: downloaded,
                isSelected: model.id == activeID,
                downloadState: state
            )
        }
    }

    // MARK: - Lifecycle / actions

    /// Recomputes downloads from disk and loads/migrates the persisted selection.
    ///
    /// Called at app startup and when Settings appear. **Migration:** if the
    /// loaded selection is empty or names a non-downloaded model but a downloaded
    /// model is found, persists that id as the selection. This provides seamless
    /// migration for existing 12B users.
    public func refresh() async {
        // Rebuild download states from disk truth
        for model in models.catalog {
            if models.isDownloaded(model.id) {
                downloads[model.id] = .downloaded
            } else if case .downloading = downloads[model.id] {
                // Keep in-flight download state
            } else {
                downloads[model.id] = .notDownloaded
            }
        }

        // Load persisted selection
        let settings = try? await store.settings()
        selectedModelID = settings?.selectedModelID ?? ""

        // Migration: if the selection is empty or stale, persist the resolved active
        if let resolved = activeModelID, resolved != selectedModelID {
            selectedModelID = resolved
            try? await store.updateSettings { settings in
                settings.selectedModelID = resolved
            }
        }
    }

    /// Download the model with the given id.
    ///
    /// Guards: the model must be runnable, have enough disk, and no other
    /// download can be in flight (one-at-a-time). On success, auto-selects
    /// the model if no valid selection exists.
    public func downloadModel(id: String) async {
        guard canStartDownload(id: id) else { return }

        downloads[id] = .downloading(fraction: nil)

        let lastFraction = LastFraction()

        do {
            try await models.download(id) { [weak self] bytes, total in
                let fraction = total.map { Double(bytes) / Double($0) }
                guard lastFraction.shouldUpdate(to: fraction) else { return }
                // Note: this Task may dispatch after the outer method sets
                // .downloaded, briefly reverting state. Acceptable: the next
                // refresh() corrects it, and the visual glitch is imperceptible.
                Task { @MainActor [weak self] in
                    self?.downloads[id] = .downloading(fraction: fraction)
                }
            }
            downloads[id] = .downloaded
            await autoSelectAfterDownload(id: id)
        } catch is CancellationError {
            downloads[id] = .notDownloaded
        } catch {
            downloads[id] = .failed(message: shortDescription(error))
        }
    }

    /// Pre-flight checks for `downloadModel`: model exists, is runnable,
    /// has enough disk, and no other download is in flight.
    private func canStartDownload(id: String) -> Bool {
        // One-at-a-time guard
        let hasInFlight = downloads.values.contains {
            if case .downloading = $0 { return true }
            return false
        }
        guard !hasInFlight else { return false }

        guard let model = models.catalog.first(where: { $0.id == id })
        else { return false }

        let ram = hardware.physicalMemoryBytes
        guard ModelSuitability.canRun(model, ram: ram) else { return false }

        let freeBytes = models.url(for: id)
            .flatMap { hardware.availableDiskBytes(at: $0) }
        guard ModelSuitability.hasEnoughDisk(model, freeBytes: freeBytes) else { return false }
        return true
    }

    /// After a successful download, auto-selects the model if no valid
    /// selection exists or the model is already the active fallback.
    private func autoSelectAfterDownload(id: String) async {
        if activeModelID == id, selectedModelID != id {
            // Already active via fallback; persist it
            await selectModel(id: id)
        } else if selectedModelID.isEmpty || !models.isDownloaded(selectedModelID) {
            await selectModel(id: id)
        }
    }

    /// Delete the model with the given id from disk.
    ///
    /// If the deleted model was selected, recomputes selection: first remaining
    /// downloaded model in catalog order, or clears if none remain.
    public func deleteModel(id: String) async {
        do {
            try models.delete(id)
        } catch {
            logger.error("Failed to delete model \(id): \(error)")
            return
        }

        downloads[id] = .notDownloaded

        if selectedModelID == id {
            // Recompute: first remaining downloaded model in catalog order
            if let fallback = models.catalog.first(where: {
                $0.id != id && downloads[$0.id] == .downloaded
            }) {
                await selectModel(id: fallback.id)
            } else {
                selectedModelID = ""
                try? await store.updateSettings { settings in
                    settings.selectedModelID = ""
                }
            }
        }
    }

    /// Select a model as the active default.
    ///
    /// Guard: the model must be downloaded and runnable.
    public func selectModel(id: String) async {
        guard let model = models.catalog.first(where: { $0.id == id })
        else { return }
        guard downloads[id] == .downloaded else { return }

        let ram = hardware.physicalMemoryBytes
        guard ModelSuitability.canRun(model, ram: ram) else { return }

        selectedModelID = id
        try? await store.updateSettings { settings in
            settings.selectedModelID = id
        }
    }

    // MARK: - Private

    private func shortDescription(_ error: some Error) -> String {
        if let llmError = error as? LLMServiceError {
            return llmError.localizedDescription
        }
        return error.localizedDescription
    }
}

// MARK: - Download progress throttle

/// Tracks the last reported download fraction to avoid dispatching thousands
/// of MainActor tasks during a multi-GB download. Only reports when the
/// fraction changes by >= 1% or transitions to/from nil.
///
/// Marked `@unchecked Sendable` because it is only mutated from the
/// `ModelProviding.download` progress callback (single call site).
final class LastFraction: @unchecked Sendable {
    private var value: Double?

    /// Returns `true` if the caller should dispatch a UI update for this fraction.
    func shouldUpdate(to newFraction: Double?) -> Bool {
        guard let newFraction else {
            // nil fraction (unknown total): report only the first time
            if value == nil { return false }
            value = nil
            return true
        }
        guard let previous = value else {
            value = newFraction
            return true
        }
        if newFraction - previous >= 0.01 || newFraction >= 1.0 {
            value = newFraction
            return true
        }
        return false
    }
}

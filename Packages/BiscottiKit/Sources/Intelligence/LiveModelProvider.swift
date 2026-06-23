import Foundation
import LocalLLM

/// Production `ModelProviding` backed by `LLMModelCatalog` + `ModelInventory`
/// + `ModelDownloader`, all sharing `LocalLLMPaths.defaultModelCacheDir`.
public struct LiveModelProvider: ModelProviding {
    private let inventory: ModelInventory
    private let downloader: ModelDownloader

    public let catalog: [LLMModel]

    public init() {
        let cacheDir = LocalLLMPaths.defaultModelCacheDir
        catalog = LLMModelCatalog.all
        inventory = ModelInventory(cacheDirectory: cacheDir)
        downloader = ModelDownloader(cacheDirectory: cacheDir)
    }

    public func url(for id: String) -> URL? {
        guard let model = LLMModelCatalog.model(id: id) else { return nil }
        return inventory.path(for: model)
    }

    public func isDownloaded(_ id: String) -> Bool {
        guard let model = LLMModelCatalog.model(id: id) else { return false }
        return inventory.isDownloaded(model)
    }

    public func downloadedModelIDs() -> [String] {
        inventory.downloadedModels(in: catalog).map(\.id)
    }

    public func download(
        _ id: String,
        progress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws {
        guard let model = LLMModelCatalog.model(id: id) else { return }
        _ = try await downloader.download(from: model.downloadURL, progress: progress)
    }

    public func delete(_ id: String) throws {
        guard let model = LLMModelCatalog.model(id: id) else { return }
        try inventory.delete(model)
    }
}

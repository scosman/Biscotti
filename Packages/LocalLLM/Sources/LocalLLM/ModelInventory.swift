import Foundation

/// Disk-facing companion to ``ModelDownloader``.
///
/// Provides path resolution, presence checks, and deletion for catalog models
/// within the shared cache directory. All operations are in-process (no XPC).
/// The ``ModelDownloader`` handles network downloads; this type handles
/// what's already on disk.
public struct ModelInventory: Sendable {
    /// The directory where model GGUF files are stored.
    public let cacheDirectory: URL

    /// Create an inventory backed by `cacheDirectory`.
    ///
    /// - Parameter cacheDirectory: The shared model cache directory
    ///   (typically ``LocalLLMPaths/defaultModelCacheDir``).
    public init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    /// The on-disk path for a catalog model within this inventory's cache directory.
    ///
    /// Consistent with ``ModelDownloader/download(from:progress:)`` -- both
    /// resolve `cacheDirectory + model.fileName`, so a downloaded file is
    /// found by both.
    public func path(for model: LLMModel) -> URL {
        cacheDirectory.appendingPathComponent(model.fileName)
    }

    /// Whether the model's GGUF file exists on disk as a non-empty regular file.
    public func isDownloaded(_ model: LLMModel) -> Bool {
        ModelDownloader.fileExistsAndNonEmpty(at: path(for: model))
    }

    /// Returns the subset of `catalog` models that are currently downloaded.
    ///
    /// Preserves the catalog's ordering (display order = fallback tie-break order).
    public func downloadedModels(in catalog: [LLMModel]) -> [LLMModel] {
        catalog.filter { isDownloaded($0) }
    }

    /// Removes a model's GGUF file and any stray `.partial` download artifact.
    ///
    /// Does not throw if the files are already absent (idempotent delete).
    public func delete(_ model: LLMModel) throws {
        let modelPath = path(for: model)
        let partialPath = ModelDownloader.tempPath(for: modelPath)

        try removeIfExists(at: modelPath)
        try removeIfExists(at: partialPath)
    }

    // MARK: - Private

    private func removeIfExists(at url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}

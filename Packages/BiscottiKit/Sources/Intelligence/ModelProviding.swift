import Foundation
import LocalLLM

/// Abstracts multi-model presence checks, downloading, and deletion.
/// Real impl wraps `LLMModelCatalog` + `ModelInventory` + `ModelDownloader`;
/// fakes in tests implement the protocol in-memory.
public protocol ModelProviding: Sendable {
    /// The catalog of available models (display order).
    var catalog: [LLMModel] { get }

    /// The on-disk path for a catalog model, or `nil` if the id is unknown.
    func url(for id: String) -> URL?

    /// Whether the model with the given id is downloaded on disk.
    func isDownloaded(_ id: String) -> Bool

    /// The ids of all catalog models currently downloaded.
    func downloadedModelIDs() -> [String]

    /// Download the model with the given id. Calls `progress` periodically
    /// with (bytesDownloaded, totalBytes).
    func download(
        _ id: String,
        progress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws

    /// Delete the model with the given id from disk.
    func delete(_ id: String) throws
}

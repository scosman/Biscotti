import Foundation
import LocalLLM

/// Production `ModelProviding` backed by `ModelDownloader` + `LocalLLMPaths`.
public struct LiveModelProvider: ModelProviding {
    private let downloader: ModelDownloader

    public let modelURL: URL

    public init() {
        let cacheDir = LocalLLMPaths.defaultModelCacheDir
        let modelDownloader = ModelDownloader(cacheDirectory: cacheDir)
        downloader = modelDownloader
        modelURL = modelDownloader.modelPath
    }

    public func isDownloaded() -> Bool {
        ModelDownloader.fileExistsAndNonEmpty(at: modelURL)
    }

    public func download(
        progress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws {
        _ = try await downloader.download(progress: progress)
    }
}

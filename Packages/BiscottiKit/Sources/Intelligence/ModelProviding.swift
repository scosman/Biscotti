import Foundation

/// Abstracts model presence checks and downloading.
/// Real impl wraps `ModelDownloader` + `LocalLLMPaths`; fakes in tests.
public protocol ModelProviding: Sendable {
    var modelURL: URL { get }
    func isDownloaded() -> Bool
    func download(
        progress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws
}

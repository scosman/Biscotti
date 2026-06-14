import Foundation

/// Downloads a GGUF model file with progress reporting.
///
/// Implements skip-if-present and temp-then-move atomicity. No resume, no checksum --
/// an interrupted download is discarded and restarted on the next call.
///
/// The cache directory is a **required** init parameter -- the library does not own a default
/// location. Callers (CLI, app) supply the path so a single shared directory can be used across
/// all consumers, avoiding duplicate multi-GB downloads.
public struct ModelDownloader: Sendable {
    /// Default Gemma 4 12B QAT GGUF URL.
    public static let defaultModelURL = URL(
        string:
            "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-UD-Q4_K_XL.gguf"
    )!

    /// The caller-supplied cache directory where models are stored.
    public let cacheDirectory: URL

    /// Resolved model file path for the default model URL within this downloader's cache directory.
    ///
    /// Composed from ``cacheDirectory`` + ``defaultModelURL``'s filename.
    public var modelPath: URL {
        cacheDirectory.appendingPathComponent(Self.defaultModelURL.lastPathComponent)
    }

    /// Create a downloader that stores models in `cacheDirectory`.
    ///
    /// - Parameter cacheDirectory: The directory to use for model storage. Created on demand
    ///   during download if it doesn't already exist.
    public init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    /// Download a model file into this downloader's ``cacheDirectory``.
    ///
    /// The destination is derived from `cacheDirectory + source.lastPathComponent` -- the
    /// ``cacheDirectory`` is always authoritative for where models are stored.
    ///
    /// - Parameters:
    ///   - source: URL to download from. Defaults to `defaultModelURL`.
    ///   - progress: Called periodically with (bytesDownloaded, totalBytes). `totalBytes` is nil if
    ///     the server didn't provide Content-Length.
    /// - Returns: The final file path.
    /// - Throws: `LocalLLMError.downloadFailed` on failure.
    public func download(
        from source: URL = ModelDownloader.defaultModelURL,
        progress: @Sendable @escaping (_ bytes: Int64, _ total: Int64?) -> Void
    ) async throws -> URL {
        let finalPath = cacheDirectory.appendingPathComponent(source.lastPathComponent)

        // Skip if a non-empty file already exists
        if Self.fileExistsAndNonEmpty(at: finalPath) {
            return finalPath
        }

        // Ensure the parent directory exists
        let parentDir = finalPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Download to a temp file, then move atomically
        let tempPath = Self.tempPath(for: finalPath)

        // Clean up any leftover partial file
        try? FileManager.default.removeItem(at: tempPath)

        do {
            try await performDownload(
                from: source, to: tempPath, progress: progress
            )

            // Atomic move to final path
            try? FileManager.default.removeItem(at: finalPath)
            try FileManager.default.moveItem(at: tempPath, to: finalPath)

            return finalPath
        } catch {
            // Clean up temp on failure
            try? FileManager.default.removeItem(at: tempPath)
            if let llmError = error as? LocalLLMError {
                throw llmError
            }
            throw LocalLLMError.downloadFailed(
                url: source, underlying: error.localizedDescription
            )
        }
    }

    // MARK: - Pure helpers (testable without network)

    /// Check if a **regular file** (not a directory) exists and is non-empty.
    ///
    /// A directory at the same path reports a non-zero size on APFS/HFS+, so we explicitly verify
    /// `.type == .typeRegular` to avoid a false-positive skip-if-present when a cache directory
    /// exists but the model file inside it does not.
    public static func fileExistsAndNonEmpty(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileType = attrs[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let size = attrs[.size] as? UInt64
        else { return false }
        return size > 0
    }

    /// The temp path used during download (sibling of the final path with `.partial` suffix).
    public static func tempPath(for finalPath: URL) -> URL {
        finalPath.appendingPathExtension("partial")
    }

    // MARK: - Network (isolated for testability)

    private func performDownload(
        from source: URL,
        to destination: URL,
        progress: @Sendable @escaping (_ bytes: Int64, _ total: Int64?) -> Void
    ) async throws {
        let request = URLRequest(url: source)
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LocalLLMError.downloadFailed(
                url: source, underlying: "HTTP \(code)"
            )
        }

        let totalBytes: Int64? = {
            let length = httpResponse.expectedContentLength
            return length > 0 ? length : nil
        }()

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw LocalLLMError.downloadFailed(
                url: source, underlying: "Failed to create file at \(destination.path)"
            )
        }
        let fileHandle = try FileHandle(forWritingTo: destination)

        defer { try? fileHandle.close() }

        var downloaded: Int64 = 0
        var buffer = Data()
        let flushThreshold = 1024 * 1024 // 1 MB chunks

        for try await byte in asyncBytes {
            buffer.append(byte)
            downloaded += 1

            if buffer.count >= flushThreshold {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                progress(downloaded, totalBytes)
            }
        }

        // Flush remaining
        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
        }
        progress(downloaded, totalBytes)
    }
}

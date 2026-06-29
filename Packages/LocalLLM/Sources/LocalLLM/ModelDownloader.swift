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

    /// The URLSession configuration used for downloads. Defaults to `.default`.
    /// Override in tests to inject a custom `protocolClasses` for deterministic
    /// network interception (e.g. cancellation tests).
    var sessionConfiguration: URLSessionConfiguration = .default

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
        // TODO: Filename sanitization (non-empty, no leading dot, filename-safe chars) should
        // be added when the downloader accepts arbitrary user URLs in Project 10.
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
            let expectedLength = try await performDownload(
                from: source, to: tempPath, progress: progress
            )

            // Validate downloaded size against the server's Content-Length when available.
            // TODO: Full SHA-256 integrity verification against a published digest is
            // deferred to the Project 10 download manager.
            if let expectedLength, expectedLength > 0 {
                let attrs = try FileManager.default.attributesOfItem(atPath: tempPath.path)
                let actualSize = (attrs[.size] as? Int64) ?? 0
                if actualSize != expectedLength {
                    throw LocalLLMError.downloadFailed(
                        url: source,
                        underlying: "Size mismatch: expected \(expectedLength) bytes, got \(actualSize)"
                    )
                }
            }

            // Atomic move to final path
            try? FileManager.default.removeItem(at: finalPath)
            try FileManager.default.moveItem(at: tempPath, to: finalPath)

            return finalPath
        } catch {
            // Clean up temp on failure (including cancel — partial file removed)
            try? FileManager.default.removeItem(at: tempPath)
            // Preserve CancellationError identity so ModelManager's
            // `catch is CancellationError` branch fires for user cancels.
            if error is CancellationError {
                throw CancellationError()
            }
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

    /// Returns the server's expected content length (nil if not provided).
    ///
    /// Streams the response to disk in whole `Data` chunks via a `URLSessionDataDelegate`.
    /// The previous implementation iterated `URLSession.AsyncBytes` one `UInt8` at a time,
    /// which is CPU-bound (billions of async-sequence iterations for a multi-GB file) and
    /// capped throughput far below the link speed. Delegate `didReceive` chunks let the
    /// transfer run at network speed while still reporting progress.
    @discardableResult
    private func performDownload(
        from source: URL,
        to destination: URL,
        progress: @Sendable @escaping (_ bytes: Int64, _ total: Int64?) -> Void
    ) async throws -> Int64? {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw LocalLLMError.downloadFailed(
                url: source, underlying: "Failed to create file at \(destination.path)"
            )
        }
        let fileHandle = try FileHandle(forWritingTo: destination)

        let delegate = StreamingDownloadDelegate(
            source: source, fileHandle: fileHandle, progress: progress
        )
        // A delegate cannot be attached to `URLSession.shared`, so we spin up a dedicated
        // session and tear it down when the transfer completes (breaks the session→delegate
        // retain cycle).
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await delegate.run(session: session, request: URLRequest(url: source))
    }
}

/// Bridges a `URLSessionDataTask` to async/await, streaming response chunks straight to a
/// `FileHandle` and reporting progress.
///
/// All callbacks arrive serially on the session's delegate queue; mutable state is still guarded
/// by `lock` to publish safely to the awaiting task and to satisfy Swift 6 `Sendable`.
private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: URL
    private let fileHandle: FileHandle
    private let progress: @Sendable (Int64, Int64?) -> Void

    private let lock = NSLock()
    private var downloaded: Int64 = 0
    private var total: Int64?
    private var failure: Error?
    private var continuation: CheckedContinuation<Int64?, Error>?
    private var finished = false

    init(
        source: URL,
        fileHandle: FileHandle,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) {
        self.source = source
        self.fileHandle = fileHandle
        self.progress = progress
    }

    /// Starts the data task and suspends until the transfer completes (or fails).
    ///
    /// Cooperative cancellation: if the enclosing Swift `Task` is cancelled, the
    /// `onCancel` handler calls `dataTask.cancel()`, which triggers the delegate's
    /// `didCompleteWithError` with `NSURLErrorCancelled` — that resumes the
    /// continuation normally, so the exactly-once guarantee is preserved.
    /// - Returns: the server's `Content-Length` (nil if unknown).
    func run(session: URLSession, request: URLRequest) async throws -> Int64? {
        // Create the task synchronously so the cancellation handler can capture it.
        // `task` is a `let` — safe to read from the concurrent `onCancel` closure
        // without additional synchronisation.
        let task = session.dataTask(with: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64?, Error>) in
                lock.lock()
                continuation = cont
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            recordFailure(LocalLLMError.downloadFailed(url: source, underlying: "HTTP \(code)"))
            completionHandler(.cancel)
            return
        }
        let length = http.expectedContentLength
        lock.lock()
        total = length > 0 ? length : nil
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if failure != nil {
            lock.unlock()
            return
        }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            failure = error
            lock.unlock()
            dataTask.cancel()
            return
        }
        downloaded += Int64(data.count)
        let bytes = downloaded
        let totalBytes = total
        lock.unlock()
        // Reported outside the lock to avoid re-entrancy with caller-side throttling.
        progress(bytes, totalBytes)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        let storedFailure = failure
        let totalBytes = total
        lock.unlock()

        // Close the file handle outside the lock (no deadlock risk either way, but
        // clearer separation). Must happen before resuming the continuation so the
        // outer atomic-move sees a flushed/closed file.
        try? fileHandle.close()

        if let storedFailure {
            cont?.resume(throwing: storedFailure)
        } else if let error {
            // A cancelled URLSessionDataTask surfaces NSURLErrorCancelled.
            // Propagate as CancellationError so callers (ModelManager) can
            // distinguish user cancel from genuine failure.
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                cont?.resume(throwing: CancellationError())
            } else {
                cont?.resume(throwing: LocalLLMError.downloadFailed(
                    url: source, underlying: error.localizedDescription
                ))
            }
        } else {
            cont?.resume(returning: totalBytes)
        }
    }

    private func recordFailure(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }
}

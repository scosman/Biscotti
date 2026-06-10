import Foundation

/// The client the app holds for transcription. Supports two backends:
/// `.inProcess` (runs the engine in this process) and `.hosted` (talks
/// to an XPC service by name).
///
/// For `.hosted`, owns the `NSXPCConnection`, sets the `interruptionHandler`,
/// and maps worker crashes to `TranscriptionError.workerInterrupted` (retriable --
/// the next call auto-relaunches the worker via launchd).
///
/// The XPC connection is **demand-driven**: created lazily on the first call
/// and torn down by ``shutdown()`` after work completes. This ensures the
/// heavyweight XPC worker process (which loads multi-GB ML models) is released
/// promptly rather than lingering until the OS kills it for memory pressure.
/// Callers should call ``shutdown()`` when they are done with a batch of work
/// (e.g. after transcription completes). The next call will transparently
/// re-establish the connection and re-launch the worker.
public actor Transcriber {
    /// Which backend to use for transcription.
    public enum Backend: Sendable {
        /// Connect to the named XPC service (app/test-app context).
        case hosted(serviceName: String)

        /// Run the engine in this process (CLI, unit tests, no-XPC contexts).
        case inProcess
    }

    private let backend: Backend
    private let method: TranscriptionMethod

    /// The engine used for the `.inProcess` backend. For `.hosted`, the engine
    /// is created on-demand alongside the XPC connection (see `ensureConnected`).
    private var engine: (any TranscriptionEngine)?

    /// Current status, tracked here so statusStream can emit without
    /// crossing into the engine's actor isolation.
    private var currentStatus: ModelStatus = .needsDownload

    // XPC-specific state (only used for .hosted)
    private var xpcConnection: (any TranscriberXPCConnecting)?
    private let interruptedFlag: InterruptedFlag?

    /// Factory for creating XPC connections, used for demand-driven reconnection.
    /// Nil for `.inProcess` backend.
    private let connectionFactory: (@Sendable () -> any TranscriberXPCConnecting)?

    /// For statusStream
    private var statusContinuations: [UUID: AsyncStream<ModelStatus>.Continuation] = [:]

    /// Create a Transcriber with the specified backend.
    ///
    /// - Parameters:
    ///   - backend: `.inProcess` or `.hosted(serviceName:)`.
    ///   - method: The transcription method to use (default: `.current`).
    public init(backend: Backend, method: TranscriptionMethod = .current) {
        self.backend = backend
        self.method = method

        switch backend {
        case .inProcess:
            engine = InProcessTranscriptionEngine(method: method)
            xpcConnection = nil
            interruptedFlag = nil
            connectionFactory = nil

        case let .hosted(serviceName):
            // Connection is created on-demand; start disconnected.
            xpcConnection = nil
            engine = nil
            let flag = InterruptedFlag()
            interruptedFlag = flag
            connectionFactory = {
                TranscriberXPCConnectionImpl(serviceName: serviceName)
            }
        }
    }

    /// Internal initializer for testing: inject a custom engine and optional XPC connection.
    init(
        backend: Backend,
        method: TranscriptionMethod = .current,
        engine: (any TranscriptionEngine)? = nil,
        xpcConnection: (any TranscriberXPCConnecting)? = nil,
        interruptedFlag: InterruptedFlag? = nil,
        connectionFactory: (@Sendable () -> any TranscriberXPCConnecting)? = nil
    ) {
        self.backend = backend
        self.method = method
        self.engine = engine
        self.xpcConnection = xpcConnection
        self.interruptedFlag = interruptedFlag
        self.connectionFactory = connectionFactory
    }

    // MARK: - Public API

    /// Download models if not already cached.
    ///
    /// - Parameter status: Optional callback receiving a human-readable status
    ///   message for each download stage (e.g. "Downloading speech-to-text
    ///   model"). There is no numeric percentage — see ``TranscriptionEngine``.
    public func ensureModelsDownloaded(
        status: (@Sendable (String) -> Void)? = nil
    ) async throws {
        try checkInterrupted()
        let activeEngine = ensureConnected()
        emitStatus(.downloading(progress: 0.0))
        // For the hosted backend, status arrives over the reverse XPC channel
        // rather than through the engine call, so route it via the connection.
        // For .inProcess this is a no-op (xpcConnection is nil) and the engine
        // calls the closure directly.
        xpcConnection?.setStatusHandler(status)
        defer { xpcConnection?.setStatusHandler(nil) }
        do {
            try await activeEngine.ensureModelsDownloaded(
                status: status ?? { _ in }
            )
            emitStatus(.ready)
        } catch {
            let mapped = mapToTranscriptionError(error)
            emitStatus(.error(mapped))
            throw mapped
        }
    }

    /// Process audio files and return a diarized transcript.
    ///
    /// Both `mic` and `system` URLs are required. The engine merges them
    /// internally. If only one stream was recorded, pass an empty/silent
    /// file for the other.
    ///
    /// - Parameters:
    ///   - mic: URL to the mic audio file.
    ///   - system: URL to the system audio file.
    ///   - customVocabulary: Custom vocabulary terms for biasing.
    /// - Returns: A rich diarized `TranscriptResult`.
    public func processAudio(
        mic: URL,
        system: URL,
        customVocabulary: [String] = []
    ) async throws -> TranscriptResult {
        try checkInterrupted()
        let activeEngine = ensureConnected()
        emitStatus(.running)
        do {
            let result = try await activeEngine.processAudio(
                micPath: mic.path,
                systemPath: system.path,
                customVocabulary: customVocabulary
            )
            emitStatus(.ready)
            return result
        } catch {
            let mapped = mapToTranscriptionError(error)
            emitStatus(.error(mapped))
            throw mapped
        }
    }

    /// Re-transcribe previously recorded audio with a potentially different vocabulary.
    ///
    /// - Parameters:
    ///   - mic: URL to the mic audio file.
    ///   - system: URL to the system audio file.
    ///   - customVocabulary: Custom vocabulary terms.
    /// - Returns: A rich diarized `TranscriptResult`.
    public func reTranscribe(
        mic: URL,
        system: URL,
        customVocabulary: [String] = []
    ) async throws -> TranscriptResult {
        try await processAudio(mic: mic, system: system, customVocabulary: customVocabulary)
    }

    /// Explicitly unload all models from memory.
    public func unloadModels() async {
        await engine?.unloadModels()
        emitStatus(.needsDownload)
    }

    /// Delete all downloaded models from disk and unload them from memory,
    /// returning to a clean `needsDownload` state. The next
    /// ``ensureModelsDownloaded(status:)`` will re-download.
    ///
    /// Unloads first so the worker releases the models before the files are
    /// removed, and so its in-memory "already downloaded" state is reset.
    public func clearCache() async throws {
        await unloadModels()
        try ModelStorage.clearCache()
    }

    /// Tear down the XPC connection, allowing the worker process to exit
    /// and release its memory (loaded ML models are multi-GB).
    ///
    /// For `.inProcess` this is a no-op. For `.hosted` this invalidates
    /// the underlying `NSXPCConnection`, which causes `launchd` to terminate
    /// the idle worker. The next ``ensureModelsDownloaded(status:)`` or
    /// ``processAudio(mic:system:customVocabulary:)`` call will transparently
    /// re-establish the connection.
    ///
    /// Callers should call this after a transcription batch completes so the
    /// heavyweight worker does not linger.
    public func shutdown() {
        guard case .hosted = backend else { return }
        xpcConnection?.invalidate()
        xpcConnection = nil
        engine = nil
        // Clear the interrupted flag so a shutdown-then-reconnect cycle
        // does not surface a spurious workerInterrupted from the old connection.
        interruptedFlag?.value = false
    }

    /// An `AsyncStream` of model status updates.
    ///
    /// The stream yields the current status immediately upon subscription,
    /// then emits subsequent changes. Finishes when the `Transcriber` is
    /// deallocated or the consumer cancels.
    ///
    /// **Note:** The emitted statuses are an approximation of the underlying engine's
    /// status machine. For the `.inProcess` backend the engine tracks the full lifecycle
    /// (`.compiling`, `.loading`, etc.), but the `Transcriber` layer emits a simplified
    /// view (`.downloading`, `.running`, `.ready`, `.error`). This avoids coupling the
    /// public stream to engine internals while still providing useful UI-driving status.
    public func statusStream() -> AsyncStream<ModelStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            // Register the continuation BEFORE yielding the current status so
            // that any update emitted between the capture and registration is
            // not lost.
            self.statusContinuations[id] = continuation
            continuation.yield(self.currentStatus)
            continuation.onTermination = { @Sendable _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    /// Check if the backend is available and responsive.
    ///
    /// For `.inProcess`, returns true if the engine status is `.ready`.
    /// For `.hosted`, returns true if the XPC proxy is reachable and
    /// the connection has not been interrupted.
    public func isAvailable() async -> Bool {
        switch backend {
        case .inProcess:
            guard let activeEngine = engine else { return false }
            let engineStatus = await activeEngine.status()
            return engineStatus == .ready

        case .hosted:
            if let flag = interruptedFlag, flag.value { return false }
            guard let connection = xpcConnection else { return false }
            return connection.remoteObjectProxy() != nil
        }
    }

    // MARK: - Private

    /// Ensures an active XPC connection and engine exist for the `.hosted`
    /// backend. For `.inProcess` simply returns the existing engine.
    ///
    /// Creates a new `NSXPCConnection` (via `connectionFactory`) if the
    /// previous one was torn down by ``shutdown()``. This makes the
    /// connection demand-driven: established before work, released after.
    private func ensureConnected() -> any TranscriptionEngine {
        if let existing = engine { return existing }

        guard let factory = connectionFactory else {
            // .inProcess backend — engine should always be set. If somehow
            // nil, create a fresh one (defensive).
            assertionFailure("InProcess engine was unexpectedly nil")
            let fallback = InProcessTranscriptionEngine(method: method)
            engine = fallback
            return fallback
        }

        let connection = factory()
        xpcConnection = connection

        if let flag = interruptedFlag {
            connection.setInterruptionHandler {
                flag.value = true
            }
        }
        connection.activate()

        let adapter = XPCEngineAdapter(
            proxyProvider: { [weak connection] in
                connection?.remoteObjectProxy()
            }
        )
        engine = adapter
        return adapter
    }

    private func checkInterrupted() throws {
        guard let flag = interruptedFlag else { return }
        if flag.value {
            // Clear the flag so the next call can succeed (worker auto-relaunches)
            flag.value = false
            throw TranscriptionError.workerInterrupted
        }
    }

    private func emitStatus(_ status: ModelStatus) {
        currentStatus = status
        for (_, continuation) in statusContinuations {
            continuation.yield(status)
        }
    }

    private func removeContinuation(id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }

    private func mapToTranscriptionError(_ error: Error) -> TranscriptionError {
        if let transcriptionError = error as? TranscriptionError { return transcriptionError }
        return .transcriptionFailed(error.localizedDescription)
    }
}

/// Thread-safe mutable flag for XPC interruption state.
///
/// The `NSXPCConnection` interruption handler runs on an arbitrary queue,
/// outside the `Transcriber` actor. This class provides a thread-safe way
/// for the handler to signal the interruption, which the actor reads on
/// next call.
final class InterruptedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    init() {}

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}

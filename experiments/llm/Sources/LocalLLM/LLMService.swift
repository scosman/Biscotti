import Foundation

/// Entry point for opening LLM connections.
///
/// Provides two forms:
/// - **`withConnection`** (scoped, strongly preferred): opens, runs a closure,
///   and guarantees close on every exit path (return, throw, cancellation).
/// - **`openConnection`** (explicit, advanced): for connections that outlive one
///   scope (e.g. a SwiftUI view model). Caller MUST call `close()`.
public enum LLMService {
    /// How the connection runs its engine.
    public enum Backend: Sendable {
        /// Spawn a child process for full memory reclamation on close (Phase 3).
        /// `serviceBinary`: explicit path to the service binary; nil auto-resolves.
        case outOfProcess(serviceBinary: URL? = nil)

        /// Run the engine in the caller's process (fast tests, no isolation).
        case inProcess
    }

    /// Scoped, leak-proof connection form.
    ///
    /// Opens a connection, passes it to `body`, and **always** closes the
    /// connection on exit (return, throw, or cancellation). Returns whatever
    /// `body` returns.
    ///
    /// ```swift
    /// let summary = try await LLMService.withConnection(
    ///     model: modelURL, backend: .inProcess, config: .default
    /// ) { conn in
    ///     try await conn.generate(prompt: "Summarize this.").text
    /// }
    /// ```
    public static func withConnection<T: Sendable>(
        model: URL,
        backend: Backend = .outOfProcess(),
        config: EngineConfig = .default,
        _ body: (LLMConnection) async throws -> T
    ) async throws -> T {
        let conn = try await openConnection(model: model, backend: backend, config: config)
        return try await runWithGuaranteedClose(conn, body)
    }

    /// Explicit lifecycle connection form.
    ///
    /// Opens a connection, starts the backend (loads the model / spawns the
    /// service), and waits until it reports ready. The caller **must** call
    /// `close()` when done. A deinit backstop kills the service if close is
    /// forgotten, but that is a last resort -- prefer `withConnection`.
    ///
    /// - Throws: `LLMServiceError` if the backend fails to start.
    public static func openConnection(
        model: URL,
        backend: Backend = .outOfProcess(),
        config: EngineConfig = .default
    ) async throws -> LLMConnection {
        let serviceBackend = try createBackend(model: model, backend: backend, config: config)
        let connection = LLMConnection(backend: serviceBackend)
        try await connection.start()
        return connection
    }

    // MARK: - Internal

    /// Build the concrete `ServiceBackend` for the requested mode.
    private static func createBackend(
        model: URL,
        backend: Backend,
        config: EngineConfig
    ) throws -> any ServiceBackend {
        switch backend {
        case .inProcess:
            // In-process uses a real LLMEngine or a test-injected engine.
            // For now, this path requires a model file -- real LLMEngine will
            // be constructed at start() time in a future iteration. Phase 2
            // tests inject MockEngine directly via the internal initializer.
            // TODO: Phase 4 will construct LLMEngine here with model + config.
            throw LLMServiceError.serviceUnavailable(
                "In-process backend with real LLMEngine requires model loading (use openConnection(engine:) for tests)"
            )
        case let .outOfProcess(explicitBinary):
            guard let binaryURL = RemoteBackend.resolveServiceBinary(explicit: explicitBinary) else {
                throw LLMServiceError.serviceUnavailable(
                    "localllm-service binary not found. Build with 'swift build' first, " +
                        "or set LOCALLLM_SERVICE_PATH."
                )
            }
            return RemoteBackend(
                serviceBinary: binaryURL,
                model: model,
                config: config
            )
        }
    }

    // MARK: - Internal test/engine-injection entry points

    /// Open a connection with a pre-built `InferenceEngine` (in-process).
    ///
    /// Used by tests to inject `MockEngine` and by any caller that already holds
    /// a configured engine instance.
    static func openConnection(engine: any InferenceEngine) async throws -> LLMConnection {
        let backend = InProcessBackend(engine: engine)
        let connection = LLMConnection(backend: backend)
        try await connection.start()
        return connection
    }

    /// Scoped form with a pre-built engine (test convenience).
    static func withConnection<T: Sendable>(
        engine: any InferenceEngine,
        _ body: (LLMConnection) async throws -> T
    ) async throws -> T {
        let conn = try await openConnection(engine: engine)
        return try await runWithGuaranteedClose(conn, body)
    }

    /// Open an out-of-process connection in `--fake` mode (transport tests).
    ///
    /// Returns the connection and the child's PID for reclamation assertions.
    static func openFakeConnection(
        serviceBinary: URL
    ) async throws -> (LLMConnection, pid_t) {
        let backend = RemoteBackend(
            serviceBinary: serviceBinary,
            model: URL(fileURLWithPath: "/dev/null"),
            config: .default,
            fake: true
        )
        let connection = LLMConnection(backend: backend)
        try await connection.start()
        let pid = backend.transportHandle.runningPID ?? 0
        return (connection, pid)
    }

    // MARK: - Shared close guarantee

    /// Run `body` with `connection`, guaranteeing `close()` on every exit path
    /// (return, throw, cancellation). Single implementation shared by all
    /// `withConnection` overloads.
    private static func runWithGuaranteedClose<T: Sendable>(
        _ connection: LLMConnection,
        _ body: (LLMConnection) async throws -> T
    ) async throws -> T {
        do {
            let result = try await body(connection)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }
}

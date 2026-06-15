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
        /// Run the engine in the caller's process. Used by the CLI, tests, and
        /// as the inner engine inside the XPC service host.
        case inProcess

        /// Connect to an NSXPC service for out-of-process isolation and full
        /// memory reclamation on close.
        case hosted(serviceName: String)
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
        backend: Backend,
        config: EngineConfig = .default,
        verbose: Bool = false,
        _ body: (LLMConnection) async throws -> T
    ) async throws -> T {
        let conn = try await openConnection(
            model: model, backend: backend, config: config, verbose: verbose
        )
        return try await runWithGuaranteedClose(conn, body)
    }

    /// Explicit lifecycle connection form.
    ///
    /// Opens a connection, starts the backend (loads the model), and waits
    /// until it reports ready. The caller **must** call `close()` when done.
    /// A deinit backstop kills the backend if close is forgotten, but that is
    /// a last resort -- prefer `withConnection`.
    ///
    /// - Throws: `LLMServiceError` if the backend fails to start.
    public static func openConnection(
        model: URL,
        backend: Backend,
        config: EngineConfig = .default,
        verbose _: Bool = false
    ) async throws -> LLMConnection {
        let serviceBackend = createBackend(
            model: model, backend: backend, config: config
        )
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
    ) -> any ServiceBackend {
        switch backend {
        case .inProcess:
            InProcessBackend(model: model, config: config)
        case let .hosted(serviceName):
            XPCBackend(serviceName: serviceName, model: model, config: config)
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

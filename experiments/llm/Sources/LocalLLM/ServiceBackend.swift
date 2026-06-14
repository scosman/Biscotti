/// Abstraction over how an `LLMConnection` talks to an engine.
///
/// Two implementations:
/// - `InProcessBackend` -- wraps an `InferenceEngine` in the caller's process
///   (fast tests, no child process).
/// - `RemoteBackend` (Phase 3) -- spawns a child process with framed-JSON pipes.
///
/// The serial queue, state machine, and id allocation live in `LLMConnection`
/// (above the backend), so semantics are identical for both backends.
protocol ServiceBackend: Sendable {
    /// Load the model / spawn the service and await readiness.
    func start() async throws

    /// Run a buffered generation.
    func generate(
        id: UInt64, prompt: String, system: String?,
        options: GenerationOptions
    ) async throws -> GenerationResult

    /// Run a streaming generation.
    func generateStreaming(
        id: UInt64, prompt: String, system: String?,
        options: GenerationOptions
    ) -> AsyncThrowingStream<StreamEvent, Error>

    /// Best-effort cancel an in-flight request.
    func cancel(id: UInt64) async

    /// Orderly shutdown: release resources, terminate child (if any).
    func shutdown() async

    /// Synchronous best-effort kill for the deinit backstop. No-op in-process.
    nonisolated func forceKill()
}

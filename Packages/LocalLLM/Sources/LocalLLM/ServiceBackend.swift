/// Abstraction over how an `LLMConnection` talks to an engine.
///
/// Implementations:
/// - `InProcessBackend` -- wraps an `InferenceEngine` in the caller's process
///   (CLI, tests, and the XPC service host's inner engine).
/// - `XPCBackend` -- NSXPC client adapter for the hosted service.
///
/// The serial queue, state machine, and id allocation live in `LLMConnection`
/// (above the backend), so semantics are identical for all backends.
protocol ServiceBackend: Sendable {
    /// Load the model / connect to the service and await readiness.
    func start() async throws

    /// Count tokens for a message list using the model's tokenizer.
    func countTokens(
        messages: [LLMMessage],
        applyChatTemplate: Bool, thinking: ThinkingMode
    ) async throws -> Int

    /// Recreate the inference context with a new size. Model stays loaded.
    func reconfigure(contextSize: Int) async throws

    /// Run a buffered generation.
    func generate(
        id: UInt64, messages: [LLMMessage],
        options: GenerationOptions
    ) async throws -> GenerationResult

    /// Run a streaming generation.
    func generateStreaming(
        id: UInt64, messages: [LLMMessage],
        options: GenerationOptions
    ) -> AsyncThrowingStream<StreamEvent, Error>

    /// Best-effort cancel an in-flight request.
    func cancel(id: UInt64) async

    /// Orderly shutdown: release resources, invalidate connection (if any).
    func shutdown() async

    /// Synchronous best-effort kill for the deinit backstop. No-op in-process.
    nonisolated func forceKill()
}

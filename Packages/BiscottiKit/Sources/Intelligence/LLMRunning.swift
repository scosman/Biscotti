import LocalLLM

/// A single loaded-model session that supports N sequential generation calls.
/// Real impl wraps `LLMService.withConnection`; fakes in tests.
public protocol LLMRunning: Sendable {
    func withSession<T: Sendable>(
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T
}

/// A single generation call within a session. Real impl wraps `LLMConnection`.
public protocol LLMSession: Sendable {
    func generate(
        system: String, user: String, options: GenerationOptions
    ) async throws -> String

    func generateStreaming(
        system: String, user: String, options: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error>
}

import Foundation
import LocalLLM

/// A single loaded-model session that supports N sequential generation calls.
/// Real impl wraps `LLMService.withConnection`; fakes in tests.
public protocol LLMRunning: Sendable {
    func withSession<T: Sendable>(
        model: URL,
        config: EngineConfig,
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T
}

/// A single generation call within a session. Real impl wraps `LLMConnection`.
public protocol LLMSession: Sendable {
    /// Count the tokens for a message list using the model's tokenizer.
    ///
    /// Same template and tokenization as `generate`, but returns only the
    /// count. No context/KV-cache work, no sampling.
    func countTokens(
        messages: [LLMMessage]
    ) async throws -> Int

    /// Recreate the inference context with a new size.
    ///
    /// Frees the current KV cache and allocates a new one. The model stays
    /// loaded (no re-download/re-read of the GGUF weights). Used by the
    /// caller after `countTokens` to right-size the context before generating.
    func reconfigure(contextSize: Int) async throws

    func generate(
        messages: [LLMMessage], options: GenerationOptions
    ) async throws -> String

    func generateStreaming(
        messages: [LLMMessage], options: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error>
}

/// Abstraction over a loaded LLM that can generate text.
///
/// Satisfied by the real `LLMEngine` (llama.cpp), `MockEngine` (canned tokens for
/// tests), and eventually any future engine backend. The protocol lets
/// `InProcessBackend` be engine-agnostic and lets tests run without a model.
public protocol InferenceEngine: Sendable {
    /// Count the tokens for a message list using the model's tokenizer.
    ///
    /// Applies the same chat template and tokenization as `generate`, but
    /// returns only the integer count. Only requires the model's vocab -- no
    /// context or KV-cache needed.
    func countTokens(
        messages: [LLMMessage],
        applyChatTemplate: Bool,
        thinking: ThinkingMode
    ) async throws -> Int

    /// Run a buffered (non-streaming) generation.
    func generate(
        messages: [LLMMessage],
        options: GenerationOptions
    ) async throws -> GenerationResult

    /// Run a streaming generation, yielding tokens as they arrive.
    func generateStreaming(
        messages: [LLMMessage],
        options: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error>

    /// Release model resources. Safe to call multiple times.
    func unload() async
}

// MARK: - LLMEngine conformance

extension LLMEngine: InferenceEngine {}

/// Abstraction over a loaded LLM that can generate text.
///
/// Satisfied by the real `LLMEngine` (llama.cpp), `MockEngine` (canned tokens for
/// tests), and eventually any future engine backend. The protocol lets
/// `InProcessBackend` be engine-agnostic and lets tests run without a model.
public protocol InferenceEngine: Sendable {
    /// Run a buffered (non-streaming) generation.
    func generate(
        prompt: String,
        system: String?,
        options: GenerationOptions
    ) async throws -> GenerationResult

    /// Run a streaming generation, yielding tokens as they arrive.
    func generateStreaming(
        prompt: String,
        system: String?,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error>

    /// Release model resources. Safe to call multiple times.
    func unload() async
}

// MARK: - LLMEngine conformance

extension LLMEngine: InferenceEngine {}

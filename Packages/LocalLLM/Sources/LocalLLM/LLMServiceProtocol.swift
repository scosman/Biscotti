import Foundation

// MARK: - Client -> Service

/// The `@objc` XPC protocol for the LLM inference service.
///
/// All parameters are `@objc`-compatible Foundation types. Structured request
/// data (model path, config, prompt, options) crosses the boundary as
/// JSON-encoded `Data` because `@objc` protocols cannot carry `Codable`
/// generics.
///
/// Strict serialization: one in-flight generation per connection (enforced
/// by `LLMConnection`'s semaphore), so the wire carries no request IDs.
///
/// **`Int32` on the wire:** `@objc` protocols require Objective-C-compatible
/// types. `Int` is not `@objc`-representable; `Int32` is the widest signed
/// integer the `@objc` bridge supports for scalar reply-handler parameters.
/// Token counts and context sizes are well within Int32.max (~2 billion),
/// so the narrowing is safe in practice. Overflow guards exist at every
/// `Int -> Int32` cast site (see `XPCBackend` and `LLMXPCService`).
@objc public protocol LLMServiceProtocol {
    /// Load a model and prepare the engine for generation.
    ///
    /// - Parameters:
    ///   - requestData: JSON-encoded `LLMLoadRequest` (model path + `EngineConfig`).
    ///   - reply: `nil` on success; `NSError` wrapping `LLMErrorPayload` on failure.
    func load(
        requestData: Data,
        reply: @escaping @Sendable (Error?) -> Void
    )

    /// Run a buffered (non-streaming) generation and return the full result.
    ///
    /// - Parameters:
    ///   - requestData: JSON-encoded `LLMGenerateRequest` (prompt + options).
    ///   - reply: JSON-encoded `GenerationResult` data on success, or an error.
    func generate(
        requestData: Data,
        reply: @escaping @Sendable (Data?, Error?) -> Void
    )

    /// Run a streaming generation. Tokens arrive via the reverse
    /// `LLMEventReporting` proxy; the reply fires once at terminal (success
    /// or error).
    ///
    /// - Parameters:
    ///   - requestData: JSON-encoded `LLMGenerateRequest` (prompt + options).
    ///   - reply: `nil` on successful completion; error if the generation failed.
    func generateStreaming(
        requestData: Data,
        reply: @escaping @Sendable (Error?) -> Void
    )

    /// Best-effort cancel the in-flight generation.
    func cancel(reply: @escaping @Sendable () -> Void)

    /// Count the tokens for a prompt using the model's tokenizer.
    ///
    /// Requires the model to be loaded (via `load`). Uses the same chat
    /// template and tokenization pipeline as `generate`, but returns only
    /// the integer token count -- no context, sampling, or KV-cache work.
    ///
    /// - Parameters:
    ///   - requestData: JSON-encoded `LLMCountTokensRequest`.
    ///   - reply: Token count on success, or an error.
    func countTokens(
        requestData: Data,
        reply: @escaping @Sendable (Int32, Error?) -> Void
    )

    /// Recreate the inference context with a new size.
    ///
    /// Frees the current KV cache and allocates a new one. The model stays
    /// loaded. Used after `countTokens` to right-size the context.
    ///
    /// - Parameters:
    ///   - contextSize: The new context window size in tokens.
    ///   - reply: `nil` on success; error on failure.
    func reconfigure(
        contextSize: Int32,
        reply: @escaping @Sendable (Error?) -> Void
    )

    /// Lightweight liveness check.
    func healthCheck(reply: @escaping @Sendable (Bool) -> Void)
}

// MARK: - Service -> Client (reverse proxy)

/// The reverse `@objc` XPC protocol: the **client** exports an object
/// conforming to this so the service can stream tokens back during
/// `generateStreaming`.
///
/// Each call is fire-and-forget (no reply block), so a dropped callback
/// during teardown is harmless.
@objc public protocol LLMEventReporting {
    /// A final-content token piece.
    func reportToken(_ piece: String)

    /// A thinking/reasoning token piece.
    func reportReasoningToken(_ piece: String)

    /// Generation completed successfully. `resultData` is JSON-encoded
    /// `GenerationResult`.
    func reportDone(resultData: Data)

    /// Generation failed. `errorData` is JSON-encoded `LLMErrorPayload`.
    func reportError(errorData: Data)
}

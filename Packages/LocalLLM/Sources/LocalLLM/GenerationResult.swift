import Foundation

/// A streaming event emitted during token-by-token generation.
public enum StreamEvent: Sendable, Equatable {
    /// A final-content token (decoded text piece). Never contains thinking content
    /// or channel markers — those are routed to `.reasoningToken` (or suppressed).
    case token(String)
    /// A thinking/reasoning token, separately consumable. Emitted only in
    /// ThinkingMode.auto when the model produces a thinking channel. Consumers may
    /// ignore these events. Never contains channel markers.
    case reasoningToken(String)
    /// Generation is complete; carries the full result with stats.
    case done(GenerationResult)
}

/// Why generation stopped.
public enum FinishReason: Sendable, Equatable, Codable {
    /// Model emitted a turn-close token: `<turn|>` (Gemma 4) or `<end_of_turn>` (Gemma 3).
    case endOfTurn
    /// Model emitted EOS token.
    case eos
    /// Hit the maxTokens limit.
    case maxTokens
    /// Hit a caller-provided stop sequence.
    case stopSequence
}

/// The result of a single-turn generation.
public struct GenerationResult: Sendable, Equatable, Codable {
    /// The model's response with turn/stop/thinking tokens stripped and trimmed.
    public let text: String

    /// Reasoning content if the model emitted a thinking channel. nil when none or when
    /// ThinkingMode.off fully suppressed it.
    public let reasoning: String?

    /// Number of tokens in the prompt after chat-template expansion.
    public let promptTokenCount: Int

    /// Number of tokens the model generated.
    public let generatedTokenCount: Int

    /// Prompt tokens served from the KV cache (reused prefix) this call. 0 when cold.
    public let cachedPromptTokenCount: Int

    /// Why generation stopped.
    public let finishReason: FinishReason

    /// Time to load the model (non-nil only on the first generate after load).
    public let loadDuration: TimeInterval?

    /// Time spent evaluating the prompt.
    public let promptEvalDuration: TimeInterval

    /// Time spent generating tokens (the decode loop).
    public let generationDuration: TimeInterval

    /// Total wall-clock time for the generate call.
    public let totalDuration: TimeInterval

    // MARK: - Debug fields

    /// The exact prompt string sent to the tokenizer, AFTER chat-template rendering
    /// (or the verbatim prompt under `--raw`). Debugging aid: inspect this to see
    /// what the model actually received. Empty string when not populated (e.g. in tests).
    public let renderedPrompt: String

    /// The raw, UNPARSED model output — the decode loop's accumulated text BEFORE
    /// `OutputParser.parse` / channel splitting. Debugging aid: inspect this to see
    /// exactly what the model emitted (including channel markers, stop tokens, etc.).
    /// Empty string when not populated (e.g. in tests).
    public let rawText: String

    /// Reserved for the GGUF-embedded Jinja chat template string from the model
    /// metadata (`llama_model_chat_template`). Currently always nil; will be
    /// populated when LLMEngine adds chat-template extraction.
    public let embeddedChatTemplate: String?

    /// Generation speed: generated tokens / generation duration. Returns 0 when duration is zero.
    public var tokensPerSecond: Double {
        guard generationDuration > 0 else { return 0 }
        return Double(generatedTokenCount) / generationDuration
    }
}

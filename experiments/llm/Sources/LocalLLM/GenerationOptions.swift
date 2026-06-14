/// Controls how the model thinks and whether to surface reasoning content.
public enum ThinkingMode: Sendable, Codable, Equatable {
    /// Ask the model not to reason; strip any thinking tokens that leak through.
    case off
    /// Leave the template default; surface reasoning separately in `GenerationResult.reasoning`.
    case auto
}

/// Per-call generation parameters.
///
/// Defaults match the Gemma-team recommended sampling settings.
public struct GenerationOptions: Sendable, Codable, Equatable {
    /// Maximum tokens to generate. Clamped to remaining context at generation time.
    public var maxTokens: Int

    /// Sampling temperature. 0 selects greedy (argmax) decoding.
    public var temperature: Float

    /// Top-K sampling cutoff.
    public var topK: Int

    /// Nucleus (top-P) sampling threshold.
    public var topP: Float

    /// Min-P sampling threshold.
    public var minP: Float

    /// Repetition penalty multiplier. 1.0 disables penalty.
    public var repeatPenalty: Float

    /// Window of recent tokens to apply repetition penalty over.
    public var repeatLastN: Int

    /// Per-call RNG seed override. nil uses the engine's seed.
    /// Note: the built-in sampler path (llama.cpp) only uses the lower 32 bits.
    public var seed: UInt64?

    /// Additional stop sequences beyond `<end_of_turn>` and EOS.
    public var stopSequences: [String]

    /// Whether to apply the chat template. `false` sends the prompt verbatim (raw mode).
    public var applyChatTemplate: Bool

    /// Thinking mode controls reasoning token handling.
    public var thinking: ThinkingMode

    /// When true AND `applyChatTemplate` is true, use `BuiltinChatTemplate` (llama.cpp's
    /// `llama_chat_apply_template` heuristic) instead of the default `GemmaChatTemplate`.
    /// The builtin heuristic is broken for Gemma 4 (drops system, no turn markers, no
    /// `<|think|>`) but is kept for A/B comparison via `--template builtin`.
    /// Default: false (use `GemmaChatTemplate`).
    public var useBuiltinTemplate: Bool

    public init(
        maxTokens: Int = 2048,
        temperature: Float = 1.0,
        topK: Int = 64,
        topP: Float = 0.95,
        minP: Float = 0.0,
        repeatPenalty: Float = 1.0,
        repeatLastN: Int = 64,
        seed: UInt64? = nil,
        stopSequences: [String] = [],
        applyChatTemplate: Bool = true,
        thinking: ThinkingMode = .off,
        useBuiltinTemplate: Bool = false
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.seed = seed
        self.stopSequences = stopSequences
        self.applyChatTemplate = applyChatTemplate
        self.thinking = thinking
        self.useBuiltinTemplate = useBuiltinTemplate
    }

    /// Gemma-team recommended defaults.
    public static let `default` = GenerationOptions()

    /// Clamp maxTokens to the remaining context window after the prompt.
    public func clampedMaxTokens(promptTokenCount: Int, contextSize: Int) -> Int {
        let remaining = contextSize - promptTokenCount
        guard remaining > 0 else { return 0 }
        return min(maxTokens, remaining)
    }
}

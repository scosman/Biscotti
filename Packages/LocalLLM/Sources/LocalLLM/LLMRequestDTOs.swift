import Foundation

/// Request payload for `LLMServiceProtocol.load(requestData:reply:)`.
///
/// Bundles the model path and engine configuration into a single JSON-encoded
/// `Data` blob for transport across the `@objc` XPC boundary.
public struct LLMLoadRequest: Codable, Sendable, Equatable {
    /// Absolute path to the GGUF model file.
    public let modelPath: String

    /// Engine configuration (context size, GPU layers, etc.).
    public let config: EngineConfig

    public init(modelPath: String, config: EngineConfig) {
        self.modelPath = modelPath
        self.config = config
    }
}

/// Request payload for `LLMServiceProtocol.countTokens(requestData:reply:)`.
///
/// Bundles the prompt, optional system message, and template settings into a
/// single JSON-encoded `Data` blob for transport across the `@objc` XPC boundary.
public struct LLMCountTokensRequest: Codable, Sendable, Equatable {
    /// The user prompt.
    public let user: String

    /// Optional system message.
    public let system: String?

    /// Whether to apply the chat template before tokenizing.
    public let applyChatTemplate: Bool

    /// Thinking mode for template rendering.
    public let thinking: ThinkingMode

    public init(
        user: String,
        system: String?,
        applyChatTemplate: Bool = true,
        thinking: ThinkingMode = .off
    ) {
        self.user = user
        self.system = system
        self.applyChatTemplate = applyChatTemplate
        self.thinking = thinking
    }
}

/// Request payload for `LLMServiceProtocol.generate` and `generateStreaming`.
///
/// Bundles the prompt, optional system message, and generation options into a
/// single JSON-encoded `Data` blob for transport across the `@objc` XPC boundary.
public struct LLMGenerateRequest: Codable, Sendable, Equatable {
    /// The user prompt.
    public let prompt: String

    /// Optional system message prepended to the conversation.
    public let system: String?

    /// Per-call generation parameters (temperature, maxTokens, etc.).
    public let options: GenerationOptions

    public init(prompt: String, system: String?, options: GenerationOptions) {
        self.prompt = prompt
        self.system = system
        self.options = options
    }
}

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
/// Bundles the message list and template settings into a single JSON-encoded
/// `Data` blob for transport across the `@objc` XPC boundary.
public struct LLMCountTokensRequest: Codable, Sendable, Equatable {
    /// The conversation messages to tokenize.
    public let messages: [LLMMessage]

    /// Whether to apply the chat template before tokenizing.
    public let applyChatTemplate: Bool

    /// Thinking mode for template rendering.
    public let thinking: ThinkingMode

    public init(
        messages: [LLMMessage],
        applyChatTemplate: Bool = true,
        thinking: ThinkingMode = .off
    ) {
        self.messages = messages
        self.applyChatTemplate = applyChatTemplate
        self.thinking = thinking
    }
}

/// Request payload for `LLMServiceProtocol.generate` and `generateStreaming`.
///
/// Bundles the message list and generation options into a single JSON-encoded
/// `Data` blob for transport across the `@objc` XPC boundary.
public struct LLMGenerateRequest: Codable, Sendable, Equatable {
    /// The conversation messages.
    public let messages: [LLMMessage]

    /// Per-call generation parameters (temperature, maxTokens, etc.).
    public let options: GenerationOptions

    public init(messages: [LLMMessage], options: GenerationOptions) {
        self.messages = messages
        self.options = options
    }
}

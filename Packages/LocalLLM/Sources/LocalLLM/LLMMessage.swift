/// A single message in an LLM conversation.
///
/// Used at every layer — from the app's prompt builder through the XPC wire
/// to the engine's chat-template renderer. Ordering contract (callers obey;
/// the service does not validate): optional leading `.system`, then alternating
/// `.user` / `.assistant`, ending on `.user` for a generate call.
public struct LLMMessage: Codable, Sendable, Equatable {
    /// The role of the message sender.
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    // MARK: - Convenience factories

    public static func system(_ content: String) -> LLMMessage {
        LLMMessage(role: .system, content: content)
    }

    public static func user(_ content: String) -> LLMMessage {
        LLMMessage(role: .user, content: content)
    }

    public static func assistant(_ content: String) -> LLMMessage {
        LLMMessage(role: .assistant, content: content)
    }
}

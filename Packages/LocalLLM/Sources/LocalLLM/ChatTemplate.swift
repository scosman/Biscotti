import Foundation

// MARK: - Protocol

/// Renders a message list into a chat-templated string ready for tokenization.
public protocol ChatTemplating: Sendable {
    /// Render the prompt. When `addGenerationPrompt` is true, append the model's
    /// generation prefix so the next tokens the model produces are the assistant reply.
    func render(messages: [LLMMessage], addGenerationPrompt: Bool) -> String
}

// MARK: - Gemma 4 template

/// A pure string builder for the **Gemma 4** chat format, byte-matching the model's
/// embedded Jinja template (cross-checked via `--show-raw`).
///
/// Gemma 4 changed its turn markers from Gemma 3's `<start_of_turn>`/`<end_of_turn>` to
/// `<|turn>`/`<turn|>`. The template renders (thinking ON, system present):
/// ```
/// <|turn>system
/// <|think|>
/// {system | trim}<turn|>
/// <|turn>user
/// {user | trim}<turn|>
/// <|turn>model
/// ```
///
/// When thinking mode is `.auto`, the system turn begins with `<|think|>\n` to enable
/// the model's reasoning channel. If no system message is provided, a system turn
/// containing just `<|think|>` is still emitted (the thinking directive must be present
/// for the model to produce reasoning).
///
/// When thinking is `.off` and `addGenerationPrompt` is true, the model turn is prefilled
/// with an empty thought block (`<|channel>thought\n<channel|>`) to deterministically
/// suppress reasoning -- matching the embedded template's behavior.
///
/// System and user content is trimmed (whitespace/newlines), matching the Jinja `| trim`
/// filter in the embedded template.
///
/// No literal `<bos>` -- llama.cpp's tokenizer adds BOS via `add_special = true`.
///
/// **Why hand-rolled:** `llama_chat_apply_template`'s heuristic (b9601) does not handle
/// Gemma 4 correctly -- it renders a near-bare prompt with no turn markers, drops the
/// system message, and never emits `<|think|>`. Future multi-model support will likely
/// require `swift-jinja` or an equivalent templating engine.
public struct GemmaChatTemplate: ChatTemplating {
    // Gemma 4 turn markers -- named constants so they're trivially correctable
    // if hardware testing reveals a variant.
    static let turnOpen = "<|turn>"
    static let turnClose = "<turn|>"
    static let thinkingDirective = "<|think|>"

    /// Empty thought block prefill for thinking-off mode. Placed after the model turn
    /// prefix to deterministically suppress reasoning (the model sees an already-closed
    /// thought channel and proceeds directly to content).
    static let emptyThoughtPrefill = "<|channel>thought\n<channel|>"

    public let thinkingEnabled: Bool

    public init(thinkingEnabled: Bool = false) {
        self.thinkingEnabled = thinkingEnabled
    }

    public func render(
        messages: [LLMMessage],
        addGenerationPrompt: Bool
    ) -> String {
        var result = ""

        // Thinking-with-no-system edge: if thinking is enabled and no .system message
        // exists, emit a bare directive turn before the first message.
        let hasSystem = messages.contains { $0.role == .system }
        if thinkingEnabled, !hasSystem {
            result += "\(Self.turnOpen)system\n"
            result += "\(Self.thinkingDirective)\(Self.turnClose)\n"
        }

        for message in messages {
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)

            switch message.role {
            case .system:
                // Empty/whitespace-only system: with thinking, emit directive-only turn;
                // without thinking, skip entirely.
                if trimmed.isEmpty {
                    if thinkingEnabled {
                        result += "\(Self.turnOpen)system\n"
                        result += "\(Self.thinkingDirective)\(Self.turnClose)\n"
                    }
                } else {
                    let systemContent = thinkingEnabled
                        ? "\(Self.thinkingDirective)\n\(trimmed)"
                        : trimmed
                    result += "\(Self.turnOpen)system\n\(systemContent)\(Self.turnClose)\n"
                }

            case .user:
                result += "\(Self.turnOpen)user\n\(trimmed)\(Self.turnClose)\n"

            case .assistant:
                // Completed assistant turn: model turn with content, closed.
                // No empty-thought prefill (that's only for the generation prompt).
                result += "\(Self.turnOpen)model\n\(trimmed)\(Self.turnClose)\n"
            }
        }

        // Model generation prefix
        if addGenerationPrompt {
            result += "\(Self.turnOpen)model\n"
            if !thinkingEnabled {
                result += "\(Self.emptyThoughtPrefill)"
            }
        }

        return result
    }
}

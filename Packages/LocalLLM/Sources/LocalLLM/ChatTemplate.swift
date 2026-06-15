import Foundation
import LlamaSwift

// MARK: - Protocol

/// Renders a (system?, user) pair into a chat-templated string ready for tokenization.
public protocol ChatTemplating: Sendable {
    /// Render the prompt. When `addGenerationPrompt` is true, append the model's
    /// generation prefix so the next tokens the model produces are the assistant reply.
    func render(system: String?, user: String, addGenerationPrompt: Bool) -> String
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
        system: String?,
        user: String,
        addGenerationPrompt: Bool
    ) -> String {
        var result = ""
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSystem = system?.trimmingCharacters(in: .whitespacesAndNewlines)

        // System turn: always present when thinking is enabled (for the directive),
        // or when a system message is provided.
        if let trimmedSystem, !trimmedSystem.isEmpty {
            let systemContent = thinkingEnabled
                ? "\(Self.thinkingDirective)\n\(trimmedSystem)"
                : trimmedSystem
            result += "\(Self.turnOpen)system\n\(systemContent)\(Self.turnClose)\n"
        } else if thinkingEnabled {
            result += "\(Self.turnOpen)system\n"
            result += "\(Self.thinkingDirective)\(Self.turnClose)\n"
        }

        // User turn
        result += "\(Self.turnOpen)user\n\(trimmedUser)\(Self.turnClose)\n"

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

// MARK: - Helpers

/// Calls `body` with a C-compatible array of `llama_chat_message` whose string pointers
/// remain valid for the duration of the closure.
///
/// Uses `strdup`/`free` to guarantee pointer stability (no dangling references from
/// nested `withUnsafeBufferPointer` closures).
func withChatMessages<R>(
    _ pairs: [(role: String, content: String)],
    _ body: (_ messages: UnsafeBufferPointer<llama_chat_message>) -> R
) -> R {
    var rolePtrs: [UnsafeMutablePointer<CChar>] = []
    var contentPtrs: [UnsafeMutablePointer<CChar>] = []
    defer {
        for ptr in rolePtrs {
            free(ptr)
        }
        for ptr in contentPtrs {
            free(ptr)
        }
    }

    var messages: [llama_chat_message] = []
    for pair in pairs {
        // swiftlint:disable:next force_unwrapping
        let rolePtr = strdup(pair.role)!
        // swiftlint:disable:next force_unwrapping
        let contentPtr = strdup(pair.content)!
        rolePtrs.append(rolePtr)
        contentPtrs.append(contentPtr)
        messages.append(llama_chat_message(role: rolePtr, content: contentPtr))
    }

    return messages.withUnsafeBufferPointer { buf in
        body(buf)
    }
}

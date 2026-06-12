import Foundation
import LlamaSwift

// MARK: - Protocol

/// Renders a (system?, user) pair into a chat-templated string ready for tokenization.
public protocol ChatTemplating: Sendable {
    /// Render the prompt. When `addGenerationPrompt` is true, append the model's generation prefix
    /// so the next tokens the model produces are the assistant reply.
    func render(system: String?, user: String, addGenerationPrompt: Bool) -> String
}

// MARK: - Built-in (llama.cpp's embedded template)

/// Uses llama.cpp's `llama_chat_apply_template` with the GGUF-embedded Jinja template.
/// This is the source-of-truth path for the Gemma 4 format -- the template comes from the model
/// metadata, so it tracks upstream changes automatically.
///
/// When `thinkingEnabled` is true, the system message is prefixed with a thinking directive
/// so the model produces a reasoning channel before the answer. The exact token is
/// `<|think|>` for Gemma 4; other model families may use a different marker.
///
/// Requires a loaded model (for the template string). Constructed by `LLMEngine` after loading.
public struct BuiltinChatTemplate: ChatTemplating {
    /// The raw Jinja template extracted from the model via `llama_model_chat_template`.
    let templateString: String

    /// When true, inject a thinking directive into the system message.
    let thinkingEnabled: Bool

    // [Phase-1 validate] Confirm the exact thinking marker token against real Gemma 4 output.
    // Architecture §12 defers token confirmation to the Phase 4 live run. For now, use the
    // same marker as GemmaChatTemplate: `<|think|>`.
    static let thinkingDirective = "<|think|>"

    /// Build from a loaded model. Returns nil if the model has no embedded chat template.
    /// Internal -- only LLMEngine should construct this.
    init?(model: OpaquePointer, thinkingEnabled: Bool = false) {
        guard let cStr = llama_model_chat_template(model, nil) else { return nil }
        self.templateString = String(cString: cStr)
        self.thinkingEnabled = thinkingEnabled
    }

    /// Visible for testing with a known template string.
    init(templateString: String, thinkingEnabled: Bool = false) {
        self.templateString = templateString
        self.thinkingEnabled = thinkingEnabled
    }

    public func render(system: String?, user: String, addGenerationPrompt: Bool) -> String {
        var pairs: [(role: String, content: String)] = []

        // Inject thinking directive into the system message when thinking is enabled.
        // If there's no system message, create one solely for the directive.
        let effectiveSystem: String? = if thinkingEnabled {
            if let system {
                "\(Self.thinkingDirective)\n\(system)"
            } else {
                Self.thinkingDirective
            }
        } else {
            system
        }

        if let effectiveSystem {
            pairs.append((role: "system", content: effectiveSystem))
        }
        pairs.append((role: "user", content: user))

        return templateString.withCString { tmpl in
            withChatMessages(pairs) { msgBuf in
                // First call: query required buffer size
                let needed = llama_chat_apply_template(
                    tmpl, msgBuf.baseAddress, msgBuf.count, addGenerationPrompt, nil, 0
                )
                guard needed > 0 else {
                    // Fallback if the built-in template fails -- return raw
                    return user
                }
                var buffer = [CChar](repeating: 0, count: Int(needed) + 1)
                _ = llama_chat_apply_template(
                    tmpl, msgBuf.baseAddress, msgBuf.count, addGenerationPrompt, &buffer,
                    Int32(buffer.count)
                )
                // Convert the null-terminated CChar buffer to String
                let resultLen = Int(needed)
                return buffer.withUnsafeBufferPointer { ptr in
                    String(decoding: UnsafeRawBufferPointer(
                        start: ptr.baseAddress, count: resultLen
                    ), as: UTF8.self)
                }
            }
        }
    }
}

// MARK: - Hand-rolled Gemma 4 fallback

/// A pure string builder for the Gemma 4 chat format.
///
/// Gemma 4 introduced native `system` role support. The format is:
/// ```
/// <start_of_turn>system
/// {system}<end_of_turn>
/// <start_of_turn>user
/// {user}<end_of_turn>
/// <start_of_turn>model
/// ```
///
/// When thinking mode is `.auto`, prepends `<|think|>` to the system content to enable reasoning.
///
/// No literal `<bos>` -- llama.cpp's tokenizer adds BOS via `add_special = true`.
public struct GemmaChatTemplate: ChatTemplating {
    public let thinkingEnabled: Bool

    public init(thinkingEnabled: Bool = false) {
        self.thinkingEnabled = thinkingEnabled
    }

    public func render(system: String?, user: String, addGenerationPrompt: Bool) -> String {
        var result = ""

        if let system {
            let systemContent = thinkingEnabled ? "<|think|>\n\(system)" : system
            result += "<start_of_turn>system\n\(systemContent)<end_of_turn>\n"
        } else if thinkingEnabled {
            result += "<start_of_turn>system\n<|think|><end_of_turn>\n"
        }

        result += "<start_of_turn>user\n\(user)<end_of_turn>\n"

        if addGenerationPrompt {
            result += "<start_of_turn>model\n"
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
    // strdup all strings so pointers are stable
    var rolePtrs: [UnsafeMutablePointer<CChar>] = []
    var contentPtrs: [UnsafeMutablePointer<CChar>] = []
    defer {
        for p in rolePtrs { free(p) }
        for p in contentPtrs { free(p) }
    }

    var messages: [llama_chat_message] = []
    for pair in pairs {
        let r = strdup(pair.role)!
        let c = strdup(pair.content)!
        rolePtrs.append(r)
        contentPtrs.append(c)
        messages.append(llama_chat_message(role: r, content: c))
    }

    return messages.withUnsafeBufferPointer { buf in
        body(buf)
    }
}

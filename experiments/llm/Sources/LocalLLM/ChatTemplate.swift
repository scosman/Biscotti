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

// MARK: - Hand-rolled Gemma 4 template (default)

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
/// suppress reasoning — matching the embedded template's behavior.
///
/// System and user content is trimmed (whitespace/newlines), matching the Jinja `| trim`
/// filter in the embedded template.
///
/// No literal `<bos>` — llama.cpp's tokenizer adds BOS via `add_special = true`.
///
/// **Why this is the default (not `BuiltinChatTemplate`):** `llama_chat_apply_template`'s
/// heuristic (b9601) does not handle Gemma 4 correctly — it renders a near-bare prompt
/// with no turn markers, drops the system message, and never emits `<|think|>`. The
/// `BuiltinChatTemplate` path is kept behind `--template builtin` for A/B comparison.
/// See `experiments/llm/README.md` "Chat template rendering" for the full rationale
/// and the `swift-jinja` recommendation for future multi-model support.
public struct GemmaChatTemplate: ChatTemplating {
    // Gemma 4 turn markers — named constants so they're trivially correctable
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

    public func render(system: String?, user: String, addGenerationPrompt: Bool) -> String {
        var result = ""
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSystem = system?.trimmingCharacters(in: .whitespacesAndNewlines)

        // System turn: always present when thinking is enabled (for the directive),
        // or when a system message is provided.
        if let trimmedSystem, !trimmedSystem.isEmpty {
            // When thinking on + system present: `<|think|>\n{system}` — the newline
            // separates the directive from the system content, matching the embedded
            // Jinja's `<|think|>\n` + `{{ message['content'] | trim }}`.
            let systemContent = thinkingEnabled
                ? "\(Self.thinkingDirective)\n\(trimmedSystem)"
                : trimmedSystem
            result += "\(Self.turnOpen)system\n\(systemContent)\(Self.turnClose)\n"
        } else if thinkingEnabled {
            // When thinking on + no system: `<|think|>` alone (no trailing newline
            // before `<turn|>`) — the Jinja template only emits `<|think|>\n` when
            // it's about to append trimmed content; with no content, the `| trim`
            // produces empty and the `\n` is not emitted.
            result += "\(Self.turnOpen)system\n\(Self.thinkingDirective)\(Self.turnClose)\n"
        }

        // User turn
        result += "\(Self.turnOpen)user\n\(trimmedUser)\(Self.turnClose)\n"

        // Model generation prefix
        if addGenerationPrompt {
            result += "\(Self.turnOpen)model\n"
            // When thinking is off, prefill an empty thought block to deterministically
            // suppress reasoning — the model sees a closed channel and emits content directly.
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

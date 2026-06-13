import Testing

@testable import LocalLLM

// MARK: - BuiltinChatTemplate (llama_chat_apply_template wrapper)

@Suite("BuiltinChatTemplate")
struct BuiltinChatTemplateTests {
    // Use the "gemma" built-in template name. llama_chat_apply_template recognizes model names
    // like "gemma" and renders with the correct format. This tests the real llama.cpp template
    // engine -- buffer sizing, C-string conversion, message assembly, and thinking injection.
    static let gemmaTemplateName = "gemma"

    @Test("Renders system + user through llama_chat_apply_template")
    func systemAndUser() {
        let template = BuiltinChatTemplate(templateString: Self.gemmaTemplateName)
        let result = template.render(
            system: "Be helpful.", user: "Hello!", addGenerationPrompt: true
        )
        #expect(result.contains("Be helpful."))
        #expect(result.contains("Hello!"))
        #expect(result.contains("<start_of_turn>"))
        #expect(result.contains("<end_of_turn>"))
        #expect(result.contains("model"))
    }

    @Test("User only renders correctly")
    func userOnly() {
        let template = BuiltinChatTemplate(templateString: Self.gemmaTemplateName)
        let result = template.render(
            system: nil, user: "What is 2+2?", addGenerationPrompt: true
        )
        #expect(result.contains("What is 2+2?"))
        #expect(result.contains("model"))
    }

    @Test("Thinking enabled injects directive into system message")
    func thinkingWithSystem() {
        let template = BuiltinChatTemplate(
            templateString: Self.gemmaTemplateName, thinkingEnabled: true
        )
        let result = template.render(
            system: "Be concise.", user: "Hi", addGenerationPrompt: true
        )
        #expect(result.contains("<|think|>"))
        #expect(result.contains("Be concise."))
    }

    @Test("Thinking enabled without system injects directive")
    func thinkingWithoutSystem() {
        let template = BuiltinChatTemplate(
            templateString: Self.gemmaTemplateName, thinkingEnabled: true
        )
        let result = template.render(
            system: nil, user: "Hi", addGenerationPrompt: true
        )
        // Thinking directive should appear somewhere in the rendered output
        #expect(result.contains("<|think|>"))
        #expect(result.contains("Hi"))
    }

    @Test("Thinking disabled does not inject directive")
    func thinkingOff() {
        let template = BuiltinChatTemplate(
            templateString: Self.gemmaTemplateName, thinkingEnabled: false
        )
        let result = template.render(
            system: "Be helpful.", user: "Hi", addGenerationPrompt: true
        )
        #expect(!result.contains("<|think|>"))
    }

    @Test("Empty template string falls back to raw user prompt")
    func emptyTemplateFallback() {
        let template = BuiltinChatTemplate(templateString: "")
        let result = template.render(
            system: nil, user: "raw prompt", addGenerationPrompt: true
        )
        // When llama_chat_apply_template returns <= 0, we fall back to the raw user string
        #expect(result == "raw prompt")
    }

    @Test("addGenerationPrompt false omits model prefix")
    func noGenerationPrompt() {
        let template = BuiltinChatTemplate(templateString: Self.gemmaTemplateName)
        let withPrompt = template.render(
            system: nil, user: "Hi", addGenerationPrompt: true
        )
        let withoutPrompt = template.render(
            system: nil, user: "Hi", addGenerationPrompt: false
        )
        // The version with generation prompt should be longer (contains model turn prefix)
        #expect(withPrompt.count > withoutPrompt.count)
    }

    @Test("Builtin and Gemma templates produce different output (anti-regression)")
    func builtinAndGemmaAreDifferent() {
        // The "gemma" heuristic in llama_chat_apply_template renders the OLD Gemma format
        // (<start_of_turn>/<end_of_turn>). GemmaChatTemplate renders the Gemma 4 format
        // (<|turn>/<turn|>). They must not be the same — if they are, the --template
        // builtin path has silently fallen back to the gemma path.
        let builtin = BuiltinChatTemplate(templateString: Self.gemmaTemplateName)
        let gemma = GemmaChatTemplate()
        let builtinResult = builtin.render(
            system: "Be helpful.", user: "Hi", addGenerationPrompt: true
        )
        let gemmaResult = gemma.render(
            system: "Be helpful.", user: "Hi", addGenerationPrompt: true
        )
        #expect(builtinResult != gemmaResult,
                "Builtin and Gemma templates must produce different output")
        // The builtin uses old Gemma markers; the hand-rolled uses Gemma 4 markers.
        #expect(builtinResult.contains("<start_of_turn>"))
        #expect(gemmaResult.contains("<|turn>"))
        #expect(!gemmaResult.contains("<start_of_turn>"))
    }
}

// MARK: - GemmaChatTemplate (hand-rolled, byte-matches embedded Jinja)

@Suite("GemmaChatTemplate")
struct ChatTemplateTests {
    let template = GemmaChatTemplate()
    let thinkingTemplate = GemmaChatTemplate(thinkingEnabled: true)

    // MARK: - Thinking OFF (default)

    @Test("Thinking off: system + user with generation prompt (includes empty thought prefill)")
    func thinkingOffSystemAndUserWithGenPrompt() {
        let result = template.render(
            system: "You are a helpful assistant.",
            user: "Hello!",
            addGenerationPrompt: true
        )
        let expected =
            "<|turn>system\n"
            + "You are a helpful assistant.<turn|>\n"
            + "<|turn>user\n"
            + "Hello!<turn|>\n"
            + "<|turn>model\n"
            + "<|channel>thought\n<channel|>"
        #expect(result == expected)
    }

    @Test("Thinking off: user only with generation prompt (includes empty thought prefill)")
    func thinkingOffUserOnlyWithGenPrompt() {
        let result = template.render(
            system: nil,
            user: "What is 2+2?",
            addGenerationPrompt: true
        )
        let expected =
            "<|turn>user\n"
            + "What is 2+2?<turn|>\n"
            + "<|turn>model\n"
            + "<|channel>thought\n<channel|>"
        #expect(result == expected)
    }

    @Test("Thinking off: user only without generation prompt (no prefill)")
    func thinkingOffUserOnlyNoGenPrompt() {
        let result = template.render(
            system: nil,
            user: "Hello",
            addGenerationPrompt: false
        )
        let expected =
            "<|turn>user\n"
            + "Hello<turn|>\n"
        #expect(result == expected)
    }

    @Test("Thinking off: system + user without generation prompt (no prefill)")
    func thinkingOffSystemAndUserNoGenPrompt() {
        let result = template.render(
            system: "System msg",
            user: "User msg",
            addGenerationPrompt: false
        )
        let expected =
            "<|turn>system\n"
            + "System msg<turn|>\n"
            + "<|turn>user\n"
            + "User msg<turn|>\n"
        #expect(result == expected)
    }

    // MARK: - Thinking ON

    @Test("Thinking on: system + user with generation prompt (think directive + newline)")
    func thinkingOnSystemAndUserWithGenPrompt() {
        let result = thinkingTemplate.render(
            system: "Be concise.",
            user: "Hi",
            addGenerationPrompt: true
        )
        let expected =
            "<|turn>system\n"
            + "<|think|>\n"
            + "Be concise.<turn|>\n"
            + "<|turn>user\n"
            + "Hi<turn|>\n"
            + "<|turn>model\n"
        #expect(result == expected)
    }

    @Test("Thinking on: no system creates system turn with just think directive")
    func thinkingOnNoSystemWithGenPrompt() {
        let result = thinkingTemplate.render(
            system: nil,
            user: "Hi",
            addGenerationPrompt: true
        )
        let expected =
            "<|turn>system\n"
            + "<|think|><turn|>\n"
            + "<|turn>user\n"
            + "Hi<turn|>\n"
            + "<|turn>model\n"
        #expect(result == expected)
    }

    @Test("Thinking on: no empty thought prefill in model turn")
    func thinkingOnNoEmptyThoughtPrefill() {
        let result = thinkingTemplate.render(
            system: nil,
            user: "Hi",
            addGenerationPrompt: true
        )
        #expect(!result.contains("<|channel>thought"))
    }

    // MARK: - Content handling

    @Test("No literal <bos> in output")
    func noBosInOutput() {
        let result = template.render(
            system: "Be helpful.",
            user: "Hi",
            addGenerationPrompt: true
        )
        #expect(!result.contains("<bos>"))
    }

    @Test("Content is trimmed (leading/trailing whitespace stripped)")
    func contentTrimmed() {
        let result = template.render(
            system: "  padded system  \n",
            user: "\n  padded user  ",
            addGenerationPrompt: true
        )
        #expect(result.contains("padded system<turn|>"))
        #expect(result.contains("padded user<turn|>"))
        #expect(!result.contains("  padded"))
        #expect(!result.contains("padded  "))
    }

    @Test("Multiline prompt content preserved (internal newlines kept)")
    func multilineContent() {
        let result = template.render(
            system: nil,
            user: "Line one\nLine two\nLine three",
            addGenerationPrompt: true
        )
        #expect(result.contains("Line one\nLine two\nLine three"))
    }

    @Test("Empty system string treated as no system (no system turn when thinking off)")
    func emptySystemStringThinkingOff() {
        let result = template.render(
            system: "   ",
            user: "Hi",
            addGenerationPrompt: true
        )
        // Empty/whitespace-only system should produce no system turn
        #expect(!result.contains("<|turn>system"))
    }

    @Test("Empty system string with thinking on still emits system turn for directive")
    func emptySystemStringThinkingOn() {
        let result = thinkingTemplate.render(
            system: "   ",
            user: "Hi",
            addGenerationPrompt: true
        )
        // Should produce a system turn with just the thinking directive
        #expect(result.contains("<|turn>system\n<|think|><turn|>"))
    }
}

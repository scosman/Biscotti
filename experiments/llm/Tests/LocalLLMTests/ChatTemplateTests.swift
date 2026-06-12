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
}

// MARK: - GemmaChatTemplate (hand-rolled fallback)

@Suite("GemmaChatTemplate")
struct ChatTemplateTests {
    let template = GemmaChatTemplate()

    @Test("System + user with generation prompt")
    func systemAndUserWithGenPrompt() {
        let result = template.render(
            system: "You are a helpful assistant.",
            user: "Hello!",
            addGenerationPrompt: true
        )
        let expected =
            "<start_of_turn>system\n"
            + "You are a helpful assistant.<end_of_turn>\n"
            + "<start_of_turn>user\n"
            + "Hello!<end_of_turn>\n"
            + "<start_of_turn>model\n"
        #expect(result == expected)
    }

    @Test("User only with generation prompt")
    func userOnlyWithGenPrompt() {
        let result = template.render(
            system: nil,
            user: "What is 2+2?",
            addGenerationPrompt: true
        )
        let expected =
            "<start_of_turn>user\n"
            + "What is 2+2?<end_of_turn>\n"
            + "<start_of_turn>model\n"
        #expect(result == expected)
    }

    @Test("User only without generation prompt")
    func userOnlyNoGenPrompt() {
        let result = template.render(
            system: nil,
            user: "Hello",
            addGenerationPrompt: false
        )
        let expected =
            "<start_of_turn>user\n"
            + "Hello<end_of_turn>\n"
        #expect(result == expected)
    }

    @Test("No literal <bos> in output")
    func noBosInOutput() {
        let result = template.render(
            system: "Be helpful.",
            user: "Hi",
            addGenerationPrompt: true
        )
        #expect(!result.contains("<bos>"))
    }

    @Test("System + user without generation prompt")
    func systemAndUserNoGenPrompt() {
        let result = template.render(
            system: "System msg",
            user: "User msg",
            addGenerationPrompt: false
        )
        #expect(result.contains("<start_of_turn>system\nSystem msg<end_of_turn>"))
        #expect(result.contains("<start_of_turn>user\nUser msg<end_of_turn>"))
        #expect(!result.contains("<start_of_turn>model"))
    }

    @Test("Thinking enabled adds think token to system")
    func thinkingEnabledWithSystem() {
        let thinkingTemplate = GemmaChatTemplate(thinkingEnabled: true)
        let result = thinkingTemplate.render(
            system: "Be concise.",
            user: "Hi",
            addGenerationPrompt: true
        )
        #expect(result.contains("<|think|>\nBe concise."))
        #expect(result.contains("<start_of_turn>system"))
    }

    @Test("Thinking enabled without system creates system turn for think token")
    func thinkingEnabledNoSystem() {
        let thinkingTemplate = GemmaChatTemplate(thinkingEnabled: true)
        let result = thinkingTemplate.render(
            system: nil,
            user: "Hi",
            addGenerationPrompt: true
        )
        #expect(result.contains("<start_of_turn>system\n<|think|><end_of_turn>"))
    }

    @Test("Multiline prompt content preserved")
    func multilineContent() {
        let result = template.render(
            system: nil,
            user: "Line one\nLine two\nLine three",
            addGenerationPrompt: true
        )
        #expect(result.contains("Line one\nLine two\nLine three"))
    }
}

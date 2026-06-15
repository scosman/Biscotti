import Testing
@testable import LocalLLM

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

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
            messages: [.system("You are a helpful assistant."), .user("Hello!")],
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
            messages: [.user("What is 2+2?")],
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
            messages: [.user("Hello")],
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
            messages: [.system("System msg"), .user("User msg")],
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
            messages: [.system("Be concise."), .user("Hi")],
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
            messages: [.user("Hi")],
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
            messages: [.user("Hi")],
            addGenerationPrompt: true
        )
        #expect(!result.contains("<|channel>thought"))
    }

    // MARK: - Content handling

    @Test("No literal <bos> in output")
    func noBosInOutput() {
        let result = template.render(
            messages: [.system("Be helpful."), .user("Hi")],
            addGenerationPrompt: true
        )
        #expect(!result.contains("<bos>"))
    }

    @Test("Content is trimmed (leading/trailing whitespace stripped)")
    func contentTrimmed() {
        let result = template.render(
            messages: [.system("  padded system  \n"), .user("\n  padded user  ")],
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
            messages: [.user("Line one\nLine two\nLine three")],
            addGenerationPrompt: true
        )
        #expect(result.contains("Line one\nLine two\nLine three"))
    }

    @Test("Empty system string treated as no system (no system turn when thinking off)")
    func emptySystemStringThinkingOff() {
        let result = template.render(
            messages: [.system("   "), .user("Hi")],
            addGenerationPrompt: true
        )
        // Empty/whitespace-only system should produce no system turn
        #expect(!result.contains("<|turn>system"))
    }

    @Test("Empty system string with thinking on still emits system turn for directive")
    func emptySystemStringThinkingOn() {
        let result = thinkingTemplate.render(
            messages: [.system("   "), .user("Hi")],
            addGenerationPrompt: true
        )
        // Should produce a system turn with just the thinking directive
        #expect(result.contains("<|turn>system\n<|think|><turn|>"))
    }

    // MARK: - Multi-turn rendering

    @Test("Multi-turn: system + user + assistant + user with generation prompt")
    func multiTurnFullConversation() {
        let result = template.render(
            messages: [
                .system("You are an analyst."),
                .user("Identify the speakers."),
                .assistant("Speaker 0 is Alice."),
                .user("Now summarize the meeting.")
            ],
            addGenerationPrompt: true
        )
        let expected =
            "<|turn>system\n"
                + "You are an analyst.<turn|>\n"
                + "<|turn>user\n"
                + "Identify the speakers.<turn|>\n"
                + "<|turn>model\n"
                + "Speaker 0 is Alice.<turn|>\n"
                + "<|turn>user\n"
                + "Now summarize the meeting.<turn|>\n"
                + "<|turn>model\n"
                + "<|channel>thought\n<channel|>"
        #expect(result == expected)
    }

    @Test("Multi-turn: assistant turn uses model marker, not assistant")
    func assistantTurnUsesModelMarker() {
        let result = template.render(
            messages: [
                .user("Hi"),
                .assistant("Hello!"),
                .user("Bye")
            ],
            addGenerationPrompt: true
        )
        // The assistant turn should be wrapped with <|turn>model, not <|turn>assistant
        #expect(result.contains("<|turn>model\nHello!<turn|>"))
        // Should not contain <|turn>assistant anywhere
        #expect(!result.contains("<|turn>assistant"))
    }

    @Test("Multi-turn: assistant turn has no empty thought prefill")
    func assistantTurnNoThoughtPrefill() {
        let result = template.render(
            messages: [
                .user("Hi"),
                .assistant("Response here"),
                .user("Follow-up")
            ],
            addGenerationPrompt: true
        )
        // The completed assistant turn should NOT have the thought prefill
        // Only the final generation prompt should have it
        let parts = result.components(separatedBy: "<|channel>thought\n<channel|>")
        // Exactly one occurrence: at the end (generation prompt)
        #expect(parts.count == 2)
    }

    @Test("Multi-turn with thinking enabled: assistant turn clean, no directive")
    func multiTurnThinkingAssistantClean() {
        let result = thinkingTemplate.render(
            messages: [
                .system("Analyze this."),
                .user("Input text"),
                .assistant("Analysis result"),
                .user("Follow-up question")
            ],
            addGenerationPrompt: true
        )
        // The assistant turn should be clean (no think directive)
        #expect(result.contains("<|turn>model\nAnalysis result<turn|>"))
        // Only one <|think|> in the system turn
        let thinkCount = result.components(separatedBy: "<|think|>").count - 1
        #expect(thinkCount == 1)
    }

    @Test("Multi-turn: assistant content is trimmed like other roles")
    func assistantContentTrimmed() {
        let result = template.render(
            messages: [
                .user("Q"),
                .assistant("  padded answer  \n"),
                .user("Follow-up")
            ],
            addGenerationPrompt: true
        )
        #expect(result.contains("padded answer<turn|>"))
        #expect(!result.contains("  padded answer"))
    }
}

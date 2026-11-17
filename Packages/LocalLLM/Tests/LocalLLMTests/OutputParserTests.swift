import Testing
@testable import LocalLLM

@Suite("OutputParser")
struct OutputParserTests {
    @Test("Strips trailing turn close (Gemma 4)")
    func stripsTurnClose() {
        let result = OutputParser.parse(rawText: "Hello world<turn|>")
        #expect(result.text == "Hello world")
        #expect(result.reasoning == nil)
    }

    @Test("Strips trailing end_of_turn")
    func stripsEndOfTurn() {
        let result = OutputParser.parse(rawText: "Hello world<end_of_turn>")
        #expect(result.text == "Hello world")
        #expect(result.reasoning == nil)
    }

    @Test("Strips trailing eos")
    func stripsEos() {
        let result = OutputParser.parse(rawText: "Hello<eos>")
        #expect(result.text == "Hello")
    }

    @Test("Strips trailing whitespace after turn tokens")
    func stripsWhitespaceAfterTurnTokens() {
        let result = OutputParser.parse(rawText: "Hello<end_of_turn>\n  ")
        #expect(result.text == "Hello")
    }

    @Test("Strips custom stop sequence")
    func stripsCustomStopSequence() {
        let result = OutputParser.parse(
            rawText: "Output text###END###",
            stopSequences: ["###END###"]
        )
        #expect(result.text == "Output text")
        #expect(result.matchedStopSequence == true)
    }

    @Test("No stop sequence match returns false")
    func noStopSequenceMatch() {
        let result = OutputParser.parse(
            rawText: "Clean text",
            stopSequences: ["###END###"]
        )
        #expect(result.text == "Clean text")
        #expect(result.matchedStopSequence == false)
    }

    @Test("Extracts thinking channel to reasoning")
    func extractsThinkingChannel() {
        let raw = "<|channel>thought\nI should think about this carefully<channel|>The answer is 42."
        let result = OutputParser.parse(rawText: raw, stripThinking: false)
        #expect(result.text == "The answer is 42.")
        #expect(result.reasoning == "I should think about this carefully")
    }

    @Test("Thinking channel stripped when stripThinking is true")
    func thinkingStrippedWhenOff() {
        let raw = "<|channel>thought\nSome reasoning<channel|>The answer."
        let result = OutputParser.parse(rawText: raw, stripThinking: true)
        #expect(result.text == "The answer.")
        #expect(result.reasoning == nil)
    }

    @Test("No thinking channel returns nil reasoning")
    func noThinkingChannel() {
        let result = OutputParser.parse(rawText: "Just a normal response")
        #expect(result.reasoning == nil)
    }

    @Test("Empty thinking channel returns nil reasoning")
    func emptyThinkingChannel() {
        let raw = "<|channel>thought\n<channel|>The answer."
        let result = OutputParser.parse(rawText: raw, stripThinking: false)
        #expect(result.text == "The answer.")
        #expect(result.reasoning == nil)
    }

    @Test("Thinking channel with no close tag treats rest as thought")
    func unclosedThinkingChannel() {
        let raw = "Prefix<|channel>thought\nAll reasoning here"
        let result = OutputParser.parse(rawText: raw, stripThinking: false)
        #expect(result.text == "Prefix")
        #expect(result.reasoning == "All reasoning here")
    }

    @Test("Idempotent on clean text")
    func idempotentOnCleanText() {
        let clean = "Already clean output"
        let result = OutputParser.parse(rawText: clean)
        #expect(result.text == clean)
    }

    @Test("Combined: thinking + turn token + stop sequence")
    func combinedParsing() {
        let raw = "<|channel>thought\nReason<channel|>Result###STOP###<end_of_turn>"
        let result = OutputParser.parse(
            rawText: raw,
            stopSequences: ["###STOP###"],
            stripThinking: false
        )
        #expect(result.reasoning == "Reason")
        // Turn token stripped first, then stop sequence checked
        #expect(result.text == "Result")
    }

    @Test("matchesStopSequence helper")
    func matchesStopSequenceHelper() {
        #expect(OutputParser.matchesStopSequence("hello###", stopSequences: ["###"]) == "###")
        #expect(OutputParser.matchesStopSequence("hello", stopSequences: ["###"]) == nil)
        #expect(OutputParser.matchesStopSequence("", stopSequences: ["###"]) == nil)
    }

    @Test("stripTrailingTurnTokens removes multiple tokens")
    func stripMultipleTurnTokens() {
        let text = "Hello<end_of_turn><eos>"
        let result = OutputParser.stripTrailingTurnTokens(text)
        #expect(result == "Hello")
    }

    @Test("stripTrailingTurnTokens removes Gemma 4 turn close + eos")
    func stripTurnCloseAndEos() {
        let text = "Hello<turn|><eos>"
        let result = OutputParser.stripTrailingTurnTokens(text)
        #expect(result == "Hello")
    }

    // MARK: - Bare close tag (reasoning written as plain text)

    @Test("Thinking stripped: bare <channel|> drops everything before and including it")
    func bareCloseDropsLeakedReasoning() {
        let raw = "The user wants me to map the speakers.\nSpeaker 1 is Steve.<channel|>1 | Steve | steve@kiln.tech<turn|>"
        let result = OutputParser.parse(rawText: raw, stripThinking: true)
        #expect(result.text == "1 | Steve | steve@kiln.tech")
        #expect(result.reasoning == nil)
    }

    @Test("Thinking kept: bare <channel|> is left alone")
    func bareCloseIgnoredWhenThinkingKept() {
        let result = OutputParser.parse(rawText: "reasoning<channel|>answer", stripThinking: false)
        #expect(result.text == "reasoning<channel|>answer")
    }

    @Test("Thinking stripped: only the first bare <channel|> is cut")
    func bareCloseCutsAtFirstOnly() {
        let result = OutputParser.parse(rawText: "reasoning<channel|>answer<channel|>tail")
        #expect(result.text == "answer<channel|>tail")
    }

    @Test("Thinking stripped: a full thinking block is not treated as a bare close")
    func fullBlockIsNotBareClose() {
        let result = OutputParser.parse(rawText: "Intro <|channel>thought\nhmm<channel|>answer")
        #expect(result.text == "Intro answer")
    }

    @Test("Thinking stripped: output with no channel tags is unchanged")
    func noTagsUnchanged() {
        let result = OutputParser.parse(rawText: "Weekly sync on the billing fix")
        #expect(result.text == "Weekly sync on the billing fix")
    }

    @Test("dropThroughBareThinkingClose keeps a close tag preceded by another channel's open")
    func closeAfterOtherChannelOpenIsNotBare() {
        let text = "<|channel>analysis\nx<channel|>y"
        #expect(OutputParser.dropThroughBareThinkingClose(text) == text)
    }

    @Test("dropThroughBareThinkingClose: bare close at the very end leaves nothing")
    func bareCloseAtEnd() {
        #expect(OutputParser.dropThroughBareThinkingClose("all reasoning<channel|>").isEmpty)
    }
}

import Foundation
import Testing
@testable import LocalLLM

// MARK: - Synthetic stream builder

/// Builds an `AsyncThrowingStream<StreamEvent, Error>` from a known list of token strings,
/// running them through a `StreamingChannelSplitter` and finishing with a
/// `.done(GenerationResult)`. This drives the same event contract that
/// `LLMEngine.generateStreaming` produces, without requiring a model.
///
/// **Scope note:** This synthetic suite verifies the StreamEvent contract (ordering, equality,
/// OutputParser integration, error propagation) and the channel-aware streaming behavior.
/// It does NOT exercise the real `LLMEngine.runGeneration` / `generateStreaming` / `generate`
/// unification -- a bug in the real decode loop would not be caught here. Real-path parity
/// between streaming and buffered generate is covered by the env-gated integration test
/// `streamingParityWithBufferedGenerate` in `IntegrationTests.swift` (requires the model +
/// `LLM_RUN_AI=1`).
enum SyntheticStream {
    /// Create a stream that yields classified `.token` / `.reasoningToken` events for each
    /// piece (after running through `StreamingChannelSplitter`), then `.done` with a result
    /// whose stats are synthetic. The final result uses `OutputParser.parse` for parity with
    /// the real engine.
    static func from(
        tokenPieces: [String],
        finishReason: FinishReason = .endOfTurn,
        thinkingMode: ThinkingMode = .off
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let rawText = tokenPieces.joined()

            // Run tokens through the channel splitter (same as LLMEngine.generateStreaming).
            var splitter = StreamingChannelSplitter(
                suppressReasoning: thinkingMode == .off
            )
            for piece in tokenPieces {
                let classified = splitter.feed(piece)
                for item in classified {
                    switch item {
                    case let .content(text):
                        continuation.yield(.token(text))
                    case let .reasoning(text):
                        continuation.yield(.reasoningToken(text))
                    }
                }
            }
            let remaining = splitter.finish()
            for item in remaining {
                switch item {
                case let .content(text):
                    continuation.yield(.token(text))
                case let .reasoning(text):
                    continuation.yield(.reasoningToken(text))
                }
            }

            // Post-process identically to LLMEngine
            let parsed = OutputParser.parse(
                rawText: rawText,
                stopSequences: [],
                stripThinking: thinkingMode == .off
            )

            let result = GenerationResult(
                text: parsed.text,
                reasoning: parsed.reasoning,
                promptTokenCount: 10,
                generatedTokenCount: tokenPieces.count,
                finishReason: finishReason,
                loadDuration: nil,
                promptEvalDuration: 0.1,
                generationDuration: Double(tokenPieces.count) * 0.05,
                totalDuration: 0.1 + Double(tokenPieces.count) * 0.05,
                renderedPrompt: "",
                rawText: rawText,
                embeddedChatTemplate: nil
            )

            continuation.yield(.done(result))
            continuation.finish()
        }
    }

    /// Create a stream that fails with the given error after yielding some tokens.
    static func failing(
        tokenPieces: [String] = [],
        error: Error
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for piece in tokenPieces {
                continuation.yield(.token(piece))
            }
            continuation.finish(throwing: error)
        }
    }
}

// MARK: - Helper to collect stream events

/// Collect all events from a stream into an array.
private func collectEvents(
    from stream: AsyncThrowingStream<StreamEvent, Error>
) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

/// Collect all events, expecting the stream to throw.
private func collectEventsExpectingError(
    from stream: AsyncThrowingStream<StreamEvent, Error>
) async -> (events: [StreamEvent], error: Error?) {
    var events: [StreamEvent] = []
    var caughtError: Error?
    do {
        for try await event in stream {
            events.append(event)
        }
    } catch {
        caughtError = error
    }
    return (events, caughtError)
}

// MARK: - StreamEvent equality tests

@Suite("Streaming")
struct StreamingTests {
    @Test("StreamEvent.token equality")
    func tokenEquality() {
        let a = StreamEvent.token("hello")
        let b = StreamEvent.token("hello")
        let c = StreamEvent.token("world")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("StreamEvent.reasoningToken equality")
    func reasoningTokenEquality() {
        let a = StreamEvent.reasoningToken("think")
        let b = StreamEvent.reasoningToken("think")
        let c = StreamEvent.reasoningToken("other")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("StreamEvent.done equality")
    func doneEquality() {
        let result = GenerationResult(
            text: "Hello",
            reasoning: nil,
            promptTokenCount: 5,
            generatedTokenCount: 1,
            finishReason: .endOfTurn,
            loadDuration: nil,
            promptEvalDuration: 0.1,
            generationDuration: 0.2,
            totalDuration: 0.3,
            renderedPrompt: "",
            rawText: "",
            embeddedChatTemplate: nil
        )
        let a = StreamEvent.done(result)
        let b = StreamEvent.done(result)
        #expect(a == b)
    }

    @Test("StreamEvent.token != StreamEvent.reasoningToken != StreamEvent.done")
    func eventCasesAreDistinct() {
        let result = GenerationResult(
            text: "hi",
            reasoning: nil,
            promptTokenCount: 1,
            generatedTokenCount: 1,
            finishReason: .eos,
            loadDuration: nil,
            promptEvalDuration: 0.1,
            generationDuration: 0.1,
            totalDuration: 0.2,
            renderedPrompt: "",
            rawText: "",
            embeddedChatTemplate: nil
        )
        let tokenEvent = StreamEvent.token("hi")
        let reasoningEvent = StreamEvent.reasoningToken("hi")
        let doneEvent = StreamEvent.done(result)
        #expect(tokenEvent != reasoningEvent)
        #expect(tokenEvent != doneEvent)
        #expect(reasoningEvent != doneEvent)
    }

    @Test("Event ordering: all token/reasoningToken events precede .done")
    func eventOrderingTokensBeforeDone() async throws {
        let pieces = ["Hello", ", ", "world", "!"]
        let stream = SyntheticStream.from(tokenPieces: pieces)
        let events = try await collectEvents(from: stream)

        // Last event must be .done
        guard case .done = events.last else {
            Issue.record("Expected last event to be .done, got \(String(describing: events.last))")
            return
        }

        // All preceding events must be .token or .reasoningToken
        for event in events.dropLast() {
            switch event {
            case .token, .reasoningToken:
                break // expected
            case .done:
                Issue.record("Unexpected .done event before the last position")
            }
        }
    }

    @Test("Streamed content tokens concatenate to result.text (content-only)")
    func streamedTokensConcatenateToResultText() async throws {
        let pieces = ["The ", "quick ", "brown ", "fox"]
        let stream = SyntheticStream.from(tokenPieces: pieces)
        let events = try await collectEvents(from: stream)

        // Collect content token text
        let contentTexts = events.compactMap { event -> String? in
            if case let .token(text) = event { return text }
            return nil
        }
        let concatenated = contentTexts.joined()
        #expect(concatenated == "The quick brown fox")
    }

    @Test("Final result text matches post-processed concatenation")
    func finalResultParityWithBufferedGenerate() async throws {
        let pieces = ["Hello", " ", "world", "!"]
        let stream = SyntheticStream.from(tokenPieces: pieces)
        let events = try await collectEvents(from: stream)

        // Extract the done result
        guard case let .done(streamResult) = events.last else {
            Issue.record("Expected .done as last event")
            return
        }

        // Build the same result via OutputParser (what buffered generate does)
        let rawText = pieces.joined()
        let parsed = OutputParser.parse(rawText: rawText, stopSequences: [], stripThinking: true)

        #expect(streamResult.text == parsed.text)
        #expect(streamResult.generatedTokenCount == pieces.count)
    }

    @Test("Empty generation yields only .done")
    func emptyGenerationYieldsDoneOnly() async throws {
        let stream = SyntheticStream.from(tokenPieces: [], finishReason: .maxTokens)
        let events = try await collectEvents(from: stream)

        #expect(events.count == 1)
        guard case let .done(result) = events.first else {
            Issue.record("Expected .done event")
            return
        }
        #expect(result.generatedTokenCount == 0)
        #expect(result.text.isEmpty)
        #expect(result.finishReason == .maxTokens)
    }

    @Test("Error propagation terminates the stream")
    func errorPropagation() async {
        let stream = SyntheticStream.failing(
            tokenPieces: ["partial"],
            error: LocalLLMError.cancelled
        )
        let (events, error) = await collectEventsExpectingError(from: stream)

        // Should have received the partial token before the error
        #expect(events.count == 1)
        guard case let .token(text) = events.first else {
            Issue.record("Expected .token event before error")
            return
        }
        #expect(text == "partial")

        // The error should be our cancellation
        #expect(error != nil)
        if let llmError = error as? LocalLLMError,
           case .cancelled = llmError
        {
            // Expected: cancelled error
        } else {
            Issue.record("Expected LocalLLMError.cancelled, got \(String(describing: error))")
        }
    }

    @Test("Thinking channel in streaming: reasoning suppressed when off (no .reasoningToken events)")
    func thinkingChannelSuppressedWhenOff() async throws {
        let pieces = [
            "<|channel>thought\n",
            "Let me think...",
            "<channel|>",
            "The answer is 42.",
        ]
        let stream = SyntheticStream.from(
            tokenPieces: pieces, finishReason: .endOfTurn, thinkingMode: .off
        )
        let events = try await collectEvents(from: stream)

        // No .reasoningToken events should appear
        let reasoningEvents = events.compactMap { event -> String? in
            if case let .reasoningToken(text) = event { return text }
            return nil
        }
        #expect(reasoningEvents.isEmpty, "No reasoning tokens should appear in .off mode")

        // Content tokens should only contain the final answer
        let contentTokens = events.compactMap { event -> String? in
            if case let .token(text) = event { return text }
            return nil
        }
        let contentText = contentTokens.joined()
        #expect(contentText == "The answer is 42.")

        // Final result should have thinking stripped
        guard case let .done(result) = events.last else {
            Issue.record("Expected .done")
            return
        }
        #expect(result.text == "The answer is 42.")
        #expect(result.reasoning == nil) // stripped in .off mode
    }

    @Test("Thinking channel in streaming: reasoning preserved when auto (.reasoningToken events emitted)")
    func thinkingChannelPreservedWhenAuto() async throws {
        let pieces = [
            "<|channel>thought\n",
            "Let me think...",
            "<channel|>",
            "The answer is 42.",
        ]
        let stream = SyntheticStream.from(
            tokenPieces: pieces, finishReason: .endOfTurn, thinkingMode: .auto
        )
        let events = try await collectEvents(from: stream)

        // Should have .reasoningToken events for the thinking content
        let reasoningTexts = events.compactMap { event -> String? in
            if case let .reasoningToken(text) = event { return text }
            return nil
        }
        let reasoningConcat = reasoningTexts.joined()
        // The splitter strips markers; "Let me think..." is the reasoning content
        #expect(reasoningConcat == "Let me think...")

        // Content tokens should only contain the final answer
        let contentTokens = events.compactMap { event -> String? in
            if case let .token(text) = event { return text }
            return nil
        }
        let contentText = contentTokens.joined()
        #expect(contentText == "The answer is 42.")

        guard case let .done(result) = events.last else {
            Issue.record("Expected .done")
            return
        }
        #expect(result.text == "The answer is 42.")
        #expect(result.reasoning == "Let me think...")
    }

    @Test("Multiple .done events never appear")
    func singleDoneEvent() async throws {
        let pieces = ["one", " ", "two", " ", "three"]
        let stream = SyntheticStream.from(tokenPieces: pieces)
        let events = try await collectEvents(from: stream)

        let doneCount = events.count {
            if case .done = $0 { return true }
            return false
        }
        #expect(doneCount == 1)
    }

    @Test("Final result stats are coherent")
    func resultStatsCoherent() async throws {
        let pieces = ["a", "b", "c"]
        let stream = SyntheticStream.from(tokenPieces: pieces)
        let events = try await collectEvents(from: stream)

        guard case let .done(result) = events.last else {
            Issue.record("Expected .done")
            return
        }

        #expect(result.generatedTokenCount == 3)
        #expect(result.promptTokenCount == 10) // synthetic value
        #expect(result.totalDuration > 0)
        #expect(result.generationDuration > 0)
        #expect(result.tokensPerSecond > 0)
    }
}

// MARK: - StreamingChannelSplitter unit tests

/// Feed tokens through a `StreamingChannelSplitter` and return the concatenated
/// content and reasoning strings. Reduces per-test boilerplate.
private func splitTokens(
    _ tokens: [String],
    suppress: Bool = false
) -> (content: String, reasoning: String) {
    var splitter = StreamingChannelSplitter(suppressReasoning: suppress)
    var allPieces: [StreamingChannelSplitter.Piece] = []
    for token in tokens {
        allPieces.append(contentsOf: splitter.feed(token))
    }
    allPieces.append(contentsOf: splitter.finish())

    let content = allPieces.compactMap { piece -> String? in
        if case let .content(text) = piece { return text }
        return nil
    }.joined()

    let reasoning = allPieces.compactMap { piece -> String? in
        if case let .reasoning(text) = piece { return text }
        return nil
    }.joined()

    return (content, reasoning)
}

@Suite("StreamingChannelSplitter")
struct StreamingChannelSplitterTests {
    // MARK: Content-only (no thinking)

    @Test("Content-only: tokens pass through unchanged")
    func contentOnlyPassThrough() {
        let (content, reasoning) = splitTokens(["Hello", " ", "world", "!"])
        #expect(content == "Hello world!")
        #expect(reasoning.isEmpty)
    }

    // MARK: Thinking-then-content (auto mode)

    @Test("Auto mode: thinking then content — markers stripped, both channels populated")
    func autoModeThinkingThenContent() {
        let (content, reasoning) = splitTokens([
            "<|channel>thought\n",
            "I need to think",
            " about this.",
            "<channel|>",
            "The answer is 42.",
        ])
        #expect(content == "The answer is 42.")
        #expect(reasoning == "I need to think about this.")
    }

    // MARK: Off mode suppression

    @Test("Off mode: reasoning content and markers are suppressed")
    func offModeSuppression() {
        let (content, reasoning) = splitTokens([
            "<|channel>thought\n",
            "secret reasoning",
            "<channel|>",
            "visible answer",
        ], suppress: true)
        #expect(content == "visible answer")
        #expect(reasoning.isEmpty, "No reasoning should be emitted in off mode")
    }

    // MARK: Markers split across multiple tokens

    @Test("Open marker split across tokens")
    func openMarkerSplitAcrossTokens() {
        // Split "<|channel>thought\n" across multiple tokens
        let (content, reasoning) = splitTokens([
            "<|chan",
            "nel>tho",
            "ught\n",
            "reasoning here",
            "<channel|>",
            "answer",
        ])
        #expect(content == "answer")
        #expect(reasoning == "reasoning here")
    }

    @Test("Close marker split across tokens")
    func closeMarkerSplitAcrossTokens() {
        let (content, reasoning) = splitTokens([
            "<|channel>thought\n",
            "thinking",
            "<chan",
            "nel|>",
            "result",
        ])
        #expect(content == "result")
        #expect(reasoning == "thinking")
    }

    @Test("Both markers split across tokens (one char at a time)")
    func bothMarkersSplitOneCharAtATime() {
        // Feed the entire string one character at a time
        let raw = "<|channel>thought\nmy reasoning<channel|>my content"
        let chars = raw.map { String($0) }
        let (content, reasoning) = splitTokens(chars)
        #expect(content == "my content")
        #expect(reasoning == "my reasoning")
    }

    // MARK: Markers never leak into output

    @Test("Markers never appear in content or reasoning output")
    func markersNeverLeakIntoOutput() {
        var splitter = StreamingChannelSplitter(suppressReasoning: false)
        var allPieces: [StreamingChannelSplitter.Piece] = []

        let tokens = [
            "<|channel>thought\n",
            "some thinking",
            "<channel|>",
            "some content",
        ]
        for token in tokens {
            allPieces.append(contentsOf: splitter.feed(token))
        }
        allPieces.append(contentsOf: splitter.finish())

        for piece in allPieces {
            let text: String
            switch piece {
            case let .content(t): text = t
            case let .reasoning(t): text = t
            }
            #expect(!text.contains("<|channel>thought"), "Marker leaked into output: '\(text)'")
            #expect(!text.contains("<channel|>"), "Marker leaked into output: '\(text)'")
        }
    }

    // MARK: Tail-buffer flush at end

    @Test("Partial marker at end is flushed as content")
    func partialMarkerAtEndFlushedAsContent() {
        // Feed text that ends with something that looks like the start of a marker
        // but isn't a complete marker.
        let (content, _) = splitTokens(["Hello", " world", "<|chan"])
        #expect(content == "Hello world<|chan")
    }

    // MARK: Concatenation parity

    @Test("content + reasoning + markers reconstructs the raw input (auto mode)")
    func concatenationParity() {
        let raw = "<|channel>thought\nreasoning text<channel|>content text"
        let openTag = OutputParser.thinkingOpenTag
        let closeTag = OutputParser.thinkingCloseTag

        var splitter = StreamingChannelSplitter(suppressReasoning: false)
        var allPieces: [StreamingChannelSplitter.Piece] = []

        // Feed one character at a time for maximum splitting
        for char in raw {
            allPieces.append(contentsOf: splitter.feed(String(char)))
        }
        allPieces.append(contentsOf: splitter.finish())

        let content = allPieces.compactMap { piece -> String? in
            if case let .content(text) = piece { return text }
            return nil
        }.joined()

        let reasoning = allPieces.compactMap { piece -> String? in
            if case let .reasoning(text) = piece { return text }
            return nil
        }.joined()

        // Reconstruct: markers + reasoning + content = raw
        let reconstructed = openTag + reasoning + closeTag + content
        #expect(reconstructed == raw, "Reconstruction must equal raw input")

        // Verify content matches OutputParser.parse modulo leading/trailing whitespace.
        // The stream emits raw untrimmed tokens; OutputParser.parse trims the final
        // text via .trimmingCharacters(in: .whitespacesAndNewlines). This modulo-whitespace
        // agreement is the intended invariant — not a workaround.
        let parsed = OutputParser.parse(rawText: raw, stripThinking: false)
        #expect(
            content.trimmingCharacters(in: .whitespacesAndNewlines)
                == parsed.text.trimmingCharacters(in: .whitespacesAndNewlines),
            "Content must match OutputParser.parse text (modulo whitespace trimming)"
        )
    }

    @Test("Content output matches OutputParser.parse text for thinking+content")
    func contentMatchesOutputParser() {
        let raw = "<|channel>thought\nLet me think step by step<channel|>The final answer."

        var splitter = StreamingChannelSplitter(suppressReasoning: false)
        var allPieces: [StreamingChannelSplitter.Piece] = []

        for char in raw {
            allPieces.append(contentsOf: splitter.feed(String(char)))
        }
        allPieces.append(contentsOf: splitter.finish())

        let content = allPieces.compactMap { piece -> String? in
            if case let .content(text) = piece { return text }
            return nil
        }.joined()

        // Modulo-whitespace parity: the stream emits raw tokens; OutputParser.parse
        // trims the finished buffer. This is the intended invariant.
        let parsed = OutputParser.parse(rawText: raw, stripThinking: false)
        #expect(
            content.trimmingCharacters(in: .whitespacesAndNewlines)
                == parsed.text.trimmingCharacters(in: .whitespacesAndNewlines),
            "Content must match OutputParser.parse text (modulo whitespace trimming)"
        )
    }

    // MARK: Edge cases

    @Test("Empty token stream produces no pieces")
    func emptyTokenStream() {
        var splitter = StreamingChannelSplitter(suppressReasoning: false)
        let pieces = splitter.finish()
        #expect(pieces.isEmpty)
    }

    @Test("No thinking content: all tokens are content (auto mode, no markers)")
    func noThinkingContentAutoMode() {
        let (content, reasoning) = splitTokens(["Just", " a", " normal", " response"])
        #expect(content == "Just a normal response")
        #expect(reasoning.isEmpty)
    }

    @Test("Empty thinking block: markers present but no reasoning content")
    func emptyThinkingBlock() {
        let (content, reasoning) = splitTokens(["<|channel>thought\n", "<channel|>", "The answer."])
        #expect(content == "The answer.")
        #expect(reasoning.isEmpty)
    }

    @Test("Content before thinking block is emitted as content")
    func contentBeforeThinkingBlock() {
        // Some models might emit content before the thinking block (unusual but possible)
        let (content, reasoning) = splitTokens([
            "Prefix ", "<|channel>thought\n", "thinking", "<channel|>", "Suffix",
        ])
        #expect(content == "Prefix Suffix")
        #expect(reasoning == "thinking")
    }

    @Test("Uses OutputParser marker constants (single source of truth)")
    func usesOutputParserConstants() {
        // Verify that the splitter uses the same constants as OutputParser
        // by checking that a string with those exact markers is parsed correctly.
        let open = OutputParser.thinkingOpenTag
        let close = OutputParser.thinkingCloseTag
        let raw = "\(open)test reasoning\(close)test content"
        let (content, reasoning) = splitTokens([raw])
        #expect(content == "test content")
        #expect(reasoning == "test reasoning")
    }

    @Test("Marker-like text that is not a valid marker passes through as content")
    func markerLikeTextPassesThrough() {
        // "<|channel>" without "thought\n" is not the open marker
        let (content, _) = splitTokens(["Hello ", "<|channel>", " world"])
        #expect(content == "Hello <|channel> world")
    }

    @Test("Unclosed thinking block: finish() flushes remainder as reasoning (auto mode)")
    func unclosedThinkingBlockAutoMode() {
        // Open marker with no close tag — matches OutputParser's unclosed-tag branch:
        // treat the entire remainder as thought content.
        let (content, reasoning) = splitTokens([
            "<|channel>thought\n", "thinking until end",
        ])
        #expect(content == "", "No content should be emitted when thinking is unclosed")
        #expect(reasoning == "thinking until end")
    }

    @Test("Unclosed thinking block: finish() suppresses remainder in off mode")
    func unclosedThinkingBlockOffMode() {
        let (content, reasoning) = splitTokens([
            "<|channel>thought\n", "secret reasoning until end",
        ], suppress: true)
        #expect(content == "", "No content should be emitted when thinking is unclosed")
        #expect(reasoning.isEmpty, "Reasoning should be suppressed in off mode")
    }

    @Test("Large token with marker embedded is correctly split")
    func largeTokenWithEmbeddedMarker() {
        // Single large token containing the entire thinking block
        let (content, reasoning) = splitTokens([
            "<|channel>thought\nI think therefore I am<channel|>Cogito ergo sum",
        ])
        #expect(content == "Cogito ergo sum")
        #expect(reasoning == "I think therefore I am")
    }
}

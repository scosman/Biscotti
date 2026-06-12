import Foundation
import Testing
@testable import LocalLLM

// MARK: - Synthetic stream builder

/// Builds an `AsyncThrowingStream<StreamEvent, Error>` from a known list of token strings,
/// finishing with a `.done(GenerationResult)`. This drives the same event contract that
/// `LLMEngine.generateStreaming` produces, without requiring a model.
///
/// **Scope note:** This synthetic suite verifies the StreamEvent contract (ordering, equality,
/// OutputParser integration, error propagation) only. It does NOT exercise the real
/// `LLMEngine.runGeneration` / `generateStreaming` / `generate` unification -- a bug in the
/// real decode loop (wrong onToken text, divergent result.text, off-by-one generatedTokenCount)
/// would not be caught here. Real-path parity between streaming and buffered generate is
/// covered by the env-gated integration test `streamingParityWithBufferedGenerate`
/// in `IntegrationTests.swift` (requires the model + `LLM_RUN_AI=1`).
enum SyntheticStream {
    /// Create a stream that yields `.token` for each piece, then `.done` with a result
    /// whose `text` is the post-processed (trimmed) concatenation and whose stats are synthetic.
    static func from(
        tokenPieces: [String],
        finishReason: FinishReason = .endOfTurn,
        stripThinking: Bool = true
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let rawText = tokenPieces.joined()

            for piece in tokenPieces {
                continuation.yield(.token(piece))
            }

            // Post-process identically to LLMEngine
            let parsed = OutputParser.parse(
                rawText: rawText,
                stopSequences: [],
                stripThinking: stripThinking
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
                totalDuration: 0.1 + Double(tokenPieces.count) * 0.05
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

// MARK: - Tests

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
            totalDuration: 0.3
        )
        let a = StreamEvent.done(result)
        let b = StreamEvent.done(result)
        #expect(a == b)
    }

    @Test("StreamEvent.token != StreamEvent.done")
    func tokenNotEqualToDone() {
        let result = GenerationResult(
            text: "hi",
            reasoning: nil,
            promptTokenCount: 1,
            generatedTokenCount: 1,
            finishReason: .eos,
            loadDuration: nil,
            promptEvalDuration: 0.1,
            generationDuration: 0.1,
            totalDuration: 0.2
        )
        let tokenEvent = StreamEvent.token("hi")
        let doneEvent = StreamEvent.done(result)
        #expect(tokenEvent != doneEvent)
    }

    @Test("Event ordering: all .token events precede .done")
    func eventOrderingTokensBeforeDone() async throws {
        let pieces = ["Hello", ", ", "world", "!"]
        let stream = SyntheticStream.from(tokenPieces: pieces)
        let events = try await collectEvents(from: stream)

        // Last event must be .done
        guard case .done = events.last else {
            Issue.record("Expected last event to be .done, got \(String(describing: events.last))")
            return
        }

        // All preceding events must be .token
        for event in events.dropLast() {
            guard case .token = event else {
                Issue.record("Expected .token event, got \(event)")
                return
            }
        }

        // Correct count: one .token per piece + one .done
        #expect(events.count == pieces.count + 1)
    }

    @Test("Streamed tokens concatenate to the raw text (pre-post-processing)")
    func streamedTokensConcatenateToRawText() async throws {
        let pieces = ["The ", "quick ", "brown ", "fox"]
        let stream = SyntheticStream.from(tokenPieces: pieces)
        let events = try await collectEvents(from: stream)

        // Collect token text
        let tokenTexts = events.compactMap { event -> String? in
            if case let .token(text) = event { return text }
            return nil
        }
        let concatenated = tokenTexts.joined()
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

    @Test("Thinking channel in streaming: reasoning stripped when off")
    func thinkingChannelStrippedInStreamResult() async throws {
        let pieces = [
            "<|channel>thought\n",
            "Let me think...",
            "<channel|>",
            "The answer is 42."
        ]
        let stream = SyntheticStream.from(
            tokenPieces: pieces, finishReason: .endOfTurn, stripThinking: true
        )
        let events = try await collectEvents(from: stream)

        // All 4 token pieces are streamed (raw, pre-post-processing)
        let tokenEvents = events.compactMap { event -> String? in
            if case let .token(text) = event { return text }
            return nil
        }
        #expect(tokenEvents.count == 4)

        // But the final result has thinking stripped
        guard case let .done(result) = events.last else {
            Issue.record("Expected .done")
            return
        }
        #expect(result.text == "The answer is 42.")
        #expect(result.reasoning == nil) // stripped in .off mode
    }

    @Test("Thinking channel in streaming: reasoning preserved when auto")
    func thinkingChannelPreservedInStreamResult() async throws {
        let pieces = [
            "<|channel>thought\n",
            "Let me think...",
            "<channel|>",
            "The answer is 42."
        ]
        let stream = SyntheticStream.from(
            tokenPieces: pieces, finishReason: .endOfTurn, stripThinking: false
        )
        let events = try await collectEvents(from: stream)

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

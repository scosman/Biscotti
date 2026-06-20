import LocalLLM
import Testing
@testable import Intelligence

// MARK: - Mock session for async ContextSizing tests

/// Minimal `LLMSession` that returns scriptable token counts and records
/// calls. Used exclusively by the async `ContextSizing` tests.
private final class MockCountingSession: LLMSession, @unchecked Sendable {
    /// Token counts to return, keyed by call index.
    var tokenCounts: [Int]
    /// If set, thrown on the next `countTokens` call.
    var errorToThrow: (any Error)?
    /// Number of `countTokens` calls made.
    var callCount = 0

    init(tokenCounts: [Int] = [100]) {
        self.tokenCounts = tokenCounts
    }

    func countTokens(system _: String, user _: String) async throws -> Int {
        if let error = errorToThrow {
            throw error
        }
        let idx = callCount
        callCount += 1
        guard idx < tokenCounts.count else {
            return tokenCounts.last ?? 0
        }
        return tokenCounts[idx]
    }

    func reconfigure(contextSize _: Int) async throws {}

    func generate(
        system _: String, user _: String,
        options _: GenerationOptions
    ) async throws -> String {
        ""
    }

    func generateStreaming(
        system _: String, user _: String,
        options _: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("ContextSizing")
struct ContextSizingTests {
    // MARK: - contextSize(forInputTokens:)

    @Test("contextSize adds output reservation for a small token count")
    func contextSizeSmall() {
        let size = ContextSizing.contextSize(forInputTokens: 500)
        #expect(size == 500 + ContextSizing.outputTokenReservation)
    }

    @Test("contextSize caps at maxContextSize for large token counts")
    func contextSizeCapped() {
        let size = ContextSizing.contextSize(forInputTokens: 30000)
        #expect(size == ContextSizing.maxContextSize)
    }

    @Test("contextSize floors input tokens to 1")
    func contextSizeMinimum() {
        let sizeZero = ContextSizing.contextSize(forInputTokens: 0)
        #expect(sizeZero == 1 + ContextSizing.outputTokenReservation)

        let sizeNegative = ContextSizing.contextSize(forInputTokens: -5)
        #expect(sizeNegative == 1 + ContextSizing.outputTokenReservation)
    }

    @Test("contextSize with typical summary prompt")
    func contextSizeTypical() {
        // A typical short transcript tokenizes to ~1500 tokens
        let size = ContextSizing.contextSize(forInputTokens: 1500)
        #expect(size == 1500 + ContextSizing.outputTokenReservation)
    }

    @Test("contextSize exactly at boundary")
    func contextSizeExactBoundary() {
        // maxContextSize - outputTokenReservation = 29696
        let boundary = ContextSizing.maxContextSize - ContextSizing.outputTokenReservation
        let sizeAtBoundary = ContextSizing.contextSize(forInputTokens: boundary)
        #expect(sizeAtBoundary == ContextSizing.maxContextSize)

        let sizeJustOver = ContextSizing.contextSize(forInputTokens: boundary + 1)
        #expect(sizeJustOver == ContextSizing.maxContextSize)

        let sizeJustUnder = ContextSizing.contextSize(forInputTokens: boundary - 1)
        #expect(sizeJustUnder == ContextSizing.maxContextSize - 1)
    }

    // MARK: - Constants

    @Test("outputTokenReservation is 3072")
    func outputReservation() {
        #expect(ContextSizing.outputTokenReservation == 3072)
    }

    @Test("maxContextSize is 32768")
    func maxContext() {
        #expect(ContextSizing.maxContextSize == 32768)
    }

    // MARK: - End-to-end scenarios

    @Test("Short meeting transcript: context well under 32k")
    func endToEndShortTranscript() {
        // A short transcript with ~1200 real tokens
        let size = ContextSizing.contextSize(forInputTokens: 1200)
        // 1200 + 3072 = 4272 — saves ~28k vs static 32k
        #expect(size == 4272)
        #expect(size < ContextSizing.maxContextSize)
    }

    @Test("Long meeting transcript: hits cap, no memory regression")
    func endToEndLongTranscript() {
        // A long transcript tokenizing to 30000+ tokens
        let size = ContextSizing.contextSize(forInputTokens: 30000)
        // Capped at 32768 — identical to the old static allocation
        #expect(size == ContextSizing.maxContextSize)
    }

    // MARK: - Async overload: contextSize(forPairs:session:)

    @Test("multi-pair selects the largest token count")
    func multiPairMaxSelection() async throws {
        let session = MockCountingSession(tokenCounts: [200, 800, 400])
        let pairs: [(system: String, user: String)] = [
            (system: "s1", user: "u1"),
            (system: "s2", user: "u2"),
            (system: "s3", user: "u3")
        ]
        let size = try await ContextSizing.contextSize(
            forPairs: pairs, session: session
        )
        // Should use the largest count (800) + reservation
        #expect(size == 800 + ContextSizing.outputTokenReservation)
        #expect(session.callCount == 3)
    }

    @Test("single-pair returns correct context size")
    func singlePair() async throws {
        let session = MockCountingSession(tokenCounts: [500])
        let pairs = [
            (system: "sys", user: "usr")
        ]
        let size = try await ContextSizing.contextSize(
            forPairs: pairs, session: session
        )
        #expect(size == 500 + ContextSizing.outputTokenReservation)
    }

    @Test("multi-pair caps at maxContextSize")
    func multiPairCapped() async throws {
        let session = MockCountingSession(tokenCounts: [30000, 100])
        let pairs: [(system: String, user: String)] = [
            (system: "s1", user: "u1"),
            (system: "s2", user: "u2")
        ]
        let size = try await ContextSizing.contextSize(
            forPairs: pairs, session: session
        )
        #expect(size == ContextSizing.maxContextSize)
    }

    @Test("multi-pair propagates countTokens errors")
    func multiPairError() async throws {
        let session = MockCountingSession(tokenCounts: [100])
        session.errorToThrow = LLMServiceError.serviceUnavailable("test")
        let pairs = [
            (system: "s1", user: "u1")
        ]
        await #expect(throws: LLMServiceError.self) {
            _ = try await ContextSizing.contextSize(
                forPairs: pairs, session: session
            )
        }
    }

    // MARK: - Async overload: contextSize(forSystem:user:session:)

    @Test("single-prompt returns correct context size")
    func singlePrompt() async throws {
        let session = MockCountingSession(tokenCounts: [1200])
        let size = try await ContextSizing.contextSize(
            forSystem: "system", user: "user", session: session
        )
        #expect(size == 1200 + ContextSizing.outputTokenReservation)
    }

    @Test("single-prompt caps at maxContextSize")
    func singlePromptCapped() async throws {
        let session = MockCountingSession(tokenCounts: [31000])
        let size = try await ContextSizing.contextSize(
            forSystem: "system", user: "user", session: session
        )
        #expect(size == ContextSizing.maxContextSize)
    }

    @Test("single-prompt propagates countTokens errors")
    func singlePromptError() async throws {
        let session = MockCountingSession(tokenCounts: [100])
        session.errorToThrow = LLMServiceError.serviceUnavailable("test")
        await #expect(throws: LLMServiceError.self) {
            _ = try await ContextSizing.contextSize(
                forSystem: "system", user: "user", session: session
            )
        }
    }
}

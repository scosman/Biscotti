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
    // MARK: - outputReservation(forInputTokens:)

    @Test("outputReservation returns base + 15% of input")
    func outputReservationFormula() {
        // 3072 + round(0.15 * 500) = 3072 + 75 = 3147
        #expect(ContextSizing.outputReservation(forInputTokens: 500) == 3147)
        // 3072 + round(0.15 * 1200) = 3072 + 180 = 3252
        #expect(ContextSizing.outputReservation(forInputTokens: 1200) == 3252)
        // 3072 + round(0.15 * 10000) = 3072 + 1500 = 4572
        #expect(ContextSizing.outputReservation(forInputTokens: 10000) == 4572)
    }

    @Test("outputReservation for zero/small input stays near base")
    func outputReservationSmall() {
        // 3072 + round(0.15 * 1) = 3072 + 0 = 3072
        #expect(ContextSizing.outputReservation(forInputTokens: 1) == 3072)
        // 3072 + round(0.15 * 0) = 3072 + 0 = 3072
        #expect(ContextSizing.outputReservation(forInputTokens: 0) == 3072)
    }

    // MARK: - contextSize(forInputTokens:)

    @Test("contextSize adds dynamic reservation for a small token count")
    func contextSizeSmall() {
        // 500 + (3072 + 75) = 3647
        let size = ContextSizing.contextSize(forInputTokens: 500)
        #expect(size == 500 + ContextSizing.outputReservation(forInputTokens: 500))
        #expect(size == 3647)
    }

    @Test("contextSize caps at maxContextSize for large token counts")
    func contextSizeCapped() {
        let size = ContextSizing.contextSize(forInputTokens: 30000)
        #expect(size == ContextSizing.maxContextSize)
    }

    @Test("contextSize floors input tokens to 1")
    func contextSizeMinimum() {
        // 1 + outputReservation(1) = 1 + 3072 = 3073
        let sizeZero = ContextSizing.contextSize(forInputTokens: 0)
        #expect(sizeZero == 1 + ContextSizing.outputReservation(forInputTokens: 1))

        let sizeNegative = ContextSizing.contextSize(forInputTokens: -5)
        #expect(sizeNegative == 1 + ContextSizing.outputReservation(forInputTokens: 1))
    }

    @Test("contextSize with typical summary prompt")
    func contextSizeTypical() {
        // 1500 + (3072 + 225) = 4797
        let size = ContextSizing.contextSize(forInputTokens: 1500)
        #expect(size == 1500 + ContextSizing.outputReservation(forInputTokens: 1500))
        #expect(size == 4797)
    }

    @Test("contextSize exactly at boundary")
    func contextSizeExactBoundary() {
        // At input = 25823: 25823 + 3072 + round(0.15*25823) = 25823 + 3072 + 3873 = 32768
        let boundary = 25823
        let sizeAtBoundary = ContextSizing.contextSize(forInputTokens: boundary)
        #expect(sizeAtBoundary == ContextSizing.maxContextSize)

        let sizeJustOver = ContextSizing.contextSize(forInputTokens: boundary + 1)
        #expect(sizeJustOver == ContextSizing.maxContextSize)

        // At input = 25822: 25822 + 3072 + round(0.15*25822) = 25822 + 3072 + 3873 = 32767
        let sizeJustUnder = ContextSizing.contextSize(forInputTokens: boundary - 1)
        #expect(sizeJustUnder == ContextSizing.maxContextSize - 1)
    }

    @Test("large input grows reservation beyond base 3k")
    func largeInputDynamicReservation() {
        // 20000 tokens: reservation = 3072 + round(0.15 * 20000) = 3072 + 3000 = 6072
        // contextSize = 20000 + 6072 = 26072 (well above 20000 + 3072 = 23072)
        let reservation = ContextSizing.outputReservation(forInputTokens: 20000)
        #expect(reservation == 6072)
        #expect(reservation > ContextSizing.outputReservationBase)

        let size = ContextSizing.contextSize(forInputTokens: 20000)
        #expect(size == 26072)
        #expect(size < ContextSizing.maxContextSize)
    }

    // MARK: - Constants

    @Test("outputReservationBase is 3072")
    func outputReservationBaseValue() {
        #expect(ContextSizing.outputReservationBase == 3072)
    }

    @Test("outputReservationInputFraction is 0.15")
    func outputReservationFractionValue() {
        #expect(ContextSizing.outputReservationInputFraction == 0.15)
    }

    @Test("maxContextSize is 32768")
    func maxContext() {
        #expect(ContextSizing.maxContextSize == 32768)
    }

    // MARK: - End-to-end scenarios

    @Test("Short meeting transcript: context well under 32k")
    func endToEndShortTranscript() {
        // 1200 + (3072 + 180) = 4452 — saves ~28k vs static 32k
        let size = ContextSizing.contextSize(forInputTokens: 1200)
        #expect(size == 4452)
        #expect(size < ContextSizing.maxContextSize)
    }

    @Test("Long meeting transcript: hits cap, no memory regression")
    func endToEndLongTranscript() {
        // A long transcript tokenizing to 30000+ tokens — capped at 32768
        let size = ContextSizing.contextSize(forInputTokens: 30000)
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
        // Reservation based on max (800): 3072 + round(0.15*800) = 3072 + 120 = 3192
        // contextSize = 800 + 3192 = 3992
        #expect(size == 800 + ContextSizing.outputReservation(forInputTokens: 800))
        #expect(size == 3992)
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
        // 500 + 3072 + 75 = 3647
        #expect(size == 500 + ContextSizing.outputReservation(forInputTokens: 500))
        #expect(size == 3647)
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
        // 1200 + (3072 + 180) = 4452
        #expect(size == 1200 + ContextSizing.outputReservation(forInputTokens: 1200))
        #expect(size == 4452)
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

    @Test("multi-pair with large input shows dynamic reservation and cap")
    func multiPairLargeInputDynamic() async throws {
        // 20000 tokens: reservation = 6072, total = 26072 (under cap)
        let session = MockCountingSession(tokenCounts: [5000, 20000, 3000])
        let pairs: [(system: String, user: String)] = [
            (system: "s1", user: "u1"),
            (system: "s2", user: "u2"),
            (system: "s3", user: "u3")
        ]
        let size = try await ContextSizing.contextSize(
            forPairs: pairs, session: session
        )
        #expect(size == 20000 + ContextSizing.outputReservation(forInputTokens: 20000))
        #expect(size == 26072)
        #expect(size < ContextSizing.maxContextSize)
    }
}

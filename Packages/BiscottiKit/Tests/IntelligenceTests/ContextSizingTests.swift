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

    func countTokens(messages _: [LLMMessage]) async throws -> Int {
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
        messages _: [LLMMessage],
        options _: GenerationOptions
    ) async throws -> String {
        ""
    }

    func generateStreaming(
        messages _: [LLMMessage],
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

    // MARK: - contextSizeForAnalysis (conversation-aware)

    @Test("contextSizeForAnalysis with followUp adds reserve tokens")
    func analysisWithFollowUp() async throws {
        let session = MockCountingSession(tokenCounts: [500])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user content",
            system: "system",
            followUpUser: "follow up",
            assistantReserveTokens: 512,
            session: session
        )
        // base = 500 (from countTokens), total = 500 + 512 = 1012
        let expected = ContextSizing.contextSize(forInputTokens: 1012)
        #expect(size == expected)
        #expect(session.callCount == 1)
    }

    @Test("contextSizeForAnalysis without followUp (single-turn)")
    func analysisSingleTurn() async throws {
        let session = MockCountingSession(tokenCounts: [800])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user content",
            system: "system",
            followUpUser: nil,
            assistantReserveTokens: 0,
            session: session
        )
        // base = 800, total = 800 + 0 = 800
        let expected = ContextSizing.contextSize(forInputTokens: 800)
        #expect(size == expected)
    }

    @Test("contextSizeForAnalysis caps at max")
    func analysisCapped() async throws {
        let session = MockCountingSession(tokenCounts: [30000])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "big transcript",
            system: "system",
            followUpUser: "follow up",
            assistantReserveTokens: 512,
            session: session
        )
        #expect(size == ContextSizing.maxContextSize)
    }

    @Test("contextSizeForAnalysis propagates errors")
    func analysisError() async throws {
        let session = MockCountingSession(tokenCounts: [100])
        session.errorToThrow = LLMServiceError.serviceUnavailable("test")
        await #expect(throws: LLMServiceError.self) {
            _ = try await ContextSizing.contextSizeForAnalysis(
                firstUser: "user",
                system: "system",
                followUpUser: nil,
                assistantReserveTokens: 0,
                session: session
            )
        }
    }

    @Test("large analysis input shows dynamic reservation")
    func analysisLargeInput() async throws {
        let session = MockCountingSession(tokenCounts: [20000])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "big transcript",
            system: "system",
            followUpUser: "follow up",
            assistantReserveTokens: 512,
            session: session
        )
        // total = 20000 + 512 = 20512
        let expected = ContextSizing.contextSize(forInputTokens: 20512)
        #expect(size == expected)
        #expect(size < ContextSizing.maxContextSize)
    }
}

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

/// Shorthand for building `AnalysisTasks` in tests.
private func tasks(
    speakers: Bool = false, summary: Bool = false, title: Bool = false
) -> ContextSizing.AnalysisTasks {
    .init(doSpeakers: speakers, doSummary: summary, doTitle: title)
}

/// Computes the expected reserve for given task flags and a base token count,
/// mirroring the production formula in `ContextSizing.contextSizeForAnalysis`.
private func expectedReserve(
    base: Int, speakers: Bool, summary: Bool, title: Bool
) -> Int {
    let summaryReserve = summary
        ? ContextSizing.summaryOutputBase
        + Int((ContextSizing.outputReservationInputFraction * Double(base)).rounded())
        : 0
    return ContextSizing.conversationBuffer
        + (speakers ? ContextSizing.speakerOutputReserve : 0)
        + (title ? ContextSizing.titleOutputReserve : 0)
        + summaryReserve
}

@Suite("ContextSizing")
struct ContextSizingTests {
    // MARK: - Constants

    @Test("conversationBuffer is 1024")
    func conversationBufferValue() {
        #expect(ContextSizing.conversationBuffer == 1024)
    }

    @Test("speakerOutputReserve is 512")
    func speakerOutputReserveValue() {
        #expect(ContextSizing.speakerOutputReserve == 512)
    }

    @Test("titleOutputReserve is 128")
    func titleOutputReserveValue() {
        #expect(ContextSizing.titleOutputReserve == 128)
    }

    @Test("summaryOutputBase is 2048")
    func summaryOutputBaseValue() {
        #expect(ContextSizing.summaryOutputBase == 2048)
    }

    @Test("outputReservationInputFraction is 0.15")
    func outputReservationFractionValue() {
        #expect(ContextSizing.outputReservationInputFraction == 0.15)
    }

    @Test("maxContextSize is 49152 (48k)")
    func maxContext() {
        #expect(ContextSizing.maxContextSize == 49152)
    }

    // MARK: - Per-task combinations

    @Test("summary present includes 2048 + 15% of base")
    func summaryReserveFormula() async throws {
        let base = 1000
        let session = MockCountingSession(tokenCounts: [base])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system", followUpUsers: [],
            tasks: tasks(summary: true),
            session: session
        )
        // reserve = 1024 + 0 + 0 + (2048 + round(0.15 * 1000))
        //         = 1024 + 2048 + 150 = 3222
        // size = 1000 + 3222 = 4222
        let reserve = expectedReserve(
            base: base, speakers: false, summary: true, title: false
        )
        #expect(size == base + reserve)
        #expect(reserve == 3222)
        #expect(size == 4222)
    }

    @Test("summary reserve scales with base (15% fraction)")
    func summaryReserveScalesWithBase() async throws {
        let base = 10000
        let session = MockCountingSession(tokenCounts: [base])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system", followUpUsers: [],
            tasks: tasks(summary: true),
            session: session
        )
        // reserve = 1024 + (2048 + round(0.15 * 10000)) = 1024 + 2048 + 1500 = 4572
        let reserve = expectedReserve(
            base: base, speakers: false, summary: true, title: false
        )
        #expect(reserve == 4572)
        #expect(size == base + reserve)
    }

    @Test("speakers add 512 to reserve")
    func speakersAddReserve() async throws {
        let base = 500
        let session = MockCountingSession(tokenCounts: [base])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system", followUpUsers: [],
            tasks: tasks(speakers: true),
            session: session
        )
        // reserve = 1024 + 512 = 1536
        let reserve = expectedReserve(
            base: base, speakers: true, summary: false, title: false
        )
        #expect(reserve == 1536)
        #expect(size == base + reserve)
    }

    @Test("title adds 128 to reserve")
    func titleAddsReserve() async throws {
        let base = 500
        let session = MockCountingSession(tokenCounts: [base])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system", followUpUsers: [],
            tasks: tasks(title: true),
            session: session
        )
        // reserve = 1024 + 128 = 1152
        let reserve = expectedReserve(
            base: base, speakers: false, summary: false, title: true
        )
        #expect(reserve == 1152)
        #expect(size == base + reserve)
    }

    @Test("1024 buffer always included even when only speakers active")
    func bufferAlwaysPresent() async throws {
        let base = 500
        let session = MockCountingSession(tokenCounts: [base])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system", followUpUsers: [],
            tasks: tasks(speakers: true),
            session: session
        )
        // speakers-only: size == base + 1024 + 512
        #expect(size == base + ContextSizing.conversationBuffer + ContextSizing.speakerOutputReserve)
        #expect(size == 2036)
    }

    @Test("all tasks active: reserve stacks correctly")
    func allTasksActive() async throws {
        let base = 2000
        let session = MockCountingSession(tokenCounts: [base])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system",
            followUpUsers: ["summary instr", "title instr"],
            tasks: tasks(speakers: true, summary: true, title: true),
            session: session
        )
        // reserve = 1024 + 512 + 128 + (2048 + round(0.15 * 2000))
        //         = 1024 + 512 + 128 + 2048 + 300 = 4012
        let reserve = expectedReserve(
            base: base, speakers: true, summary: true, title: true
        )
        #expect(reserve == 4012)
        #expect(size == base + reserve)
        #expect(size == 6012)
    }

    @Test("summary + title (no speakers): both reserves present")
    func summaryAndTitle() async throws {
        let base = 800
        let session = MockCountingSession(tokenCounts: [base])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system",
            followUpUsers: ["title instr"],
            tasks: tasks(summary: true, title: true),
            session: session
        )
        // reserve = 1024 + 0 + 128 + (2048 + round(0.15 * 800))
        //         = 1024 + 128 + 2048 + 120 = 3320
        let reserve = expectedReserve(
            base: base, speakers: false, summary: true, title: true
        )
        #expect(reserve == 3320)
        #expect(size == base + reserve)
    }

    @Test("speakers + summary (no title): summary reserve present")
    func speakersAndSummary() async throws {
        let base = 1000
        let session = MockCountingSession(tokenCounts: [base])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system",
            followUpUsers: ["summary instr"],
            tasks: tasks(speakers: true, summary: true),
            session: session
        )
        // reserve = 1024 + 512 + 0 + (2048 + round(0.15 * 1000))
        //         = 1024 + 512 + 2048 + 150 = 3734
        let reserve = expectedReserve(
            base: base, speakers: true, summary: true, title: false
        )
        #expect(reserve == 3734)
        #expect(size == base + reserve)
    }

    // MARK: - Cap at maxContextSize (49152)

    @Test("caps at maxContextSize for large inputs")
    func analysisCapped() async throws {
        let session = MockCountingSession(tokenCounts: [45000])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "big transcript", system: "system",
            followUpUsers: ["follow up"],
            tasks: tasks(speakers: true, summary: true, title: true),
            session: session
        )
        #expect(size == ContextSizing.maxContextSize)
    }

    @Test("cap is exactly 49152")
    func capValue() async throws {
        let session = MockCountingSession(tokenCounts: [48000])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system", followUpUsers: [],
            tasks: tasks(speakers: true, summary: true, title: true),
            session: session
        )
        #expect(size == 49152)
    }

    // MARK: - Error propagation

    @Test("contextSizeForAnalysis propagates errors")
    func analysisError() async throws {
        let session = MockCountingSession(tokenCounts: [100])
        session.errorToThrow = LLMServiceError.serviceUnavailable("test")
        await #expect(throws: LLMServiceError.self) {
            _ = try await ContextSizing.contextSizeForAnalysis(
                firstUser: "user", system: "system", followUpUsers: [],
                tasks: tasks(),
                session: session
            )
        }
    }

    // MARK: - Reconciliation with old reservation

    @Test("summary-only reserve reconciles: 1024 + 2048 + 15% = old 3072 + 15%")
    func reconciliationWithOldReservation() async throws {
        let base = 2000
        let session = MockCountingSession(tokenCounts: [base])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system", followUpUsers: [],
            tasks: tasks(summary: true),
            session: session
        )
        // Old formula: base + 3072 + round(0.15 * base)
        //            = 2000 + 3072 + 300 = 5372
        // New formula: base + 1024 + 2048 + round(0.15 * base)
        //            = 2000 + 1024 + 2048 + 300 = 5372
        let oldStyleReserve = 3072 + Int((0.15 * Double(base)).rounded())
        let newStyleReserve = ContextSizing.conversationBuffer + ContextSizing.summaryOutputBase
            + Int((ContextSizing.outputReservationInputFraction * Double(base)).rounded())
        #expect(oldStyleReserve == newStyleReserve)
        #expect(size == base + newStyleReserve)
    }

    // MARK: - End-to-end scenarios

    @Test("short meeting: well under cap")
    func shortMeeting() async throws {
        let session = MockCountingSession(tokenCounts: [1200])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system",
            followUpUsers: ["summary", "title"],
            tasks: tasks(speakers: true, summary: true, title: true),
            session: session
        )
        #expect(size < ContextSizing.maxContextSize)
        // base=1200, reserve = 1024 + 512 + 128 + 2048 + round(0.15*1200)
        //                     = 1024 + 512 + 128 + 2048 + 180 = 3892
        // size = 1200 + 3892 = 5092
        #expect(size == 5092)
    }

    @Test("long meeting: hits cap, no memory regression")
    func longMeeting() async throws {
        let session = MockCountingSession(tokenCounts: [45000])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system", followUpUsers: [],
            tasks: tasks(speakers: true, summary: true),
            session: session
        )
        #expect(size == ContextSizing.maxContextSize)
    }

    @Test("no tasks active: only conversation buffer")
    func noTasksActive() async throws {
        let base = 500
        let session = MockCountingSession(tokenCounts: [base])
        let size = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system", followUpUsers: [],
            tasks: tasks(),
            session: session
        )
        // Only the always-on 1024 buffer
        #expect(size == base + ContextSizing.conversationBuffer)
        #expect(size == 1524)
    }

    @Test("followUpUsers are counted but do not affect reserve formula")
    func followUpsCounted() async throws {
        let session = MockCountingSession(tokenCounts: [500])
        let sizeNoFollowUp = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system", followUpUsers: [],
            tasks: tasks(speakers: true),
            session: session
        )
        // With follow-ups the mock returns a higher base (next call)
        let session2 = MockCountingSession(tokenCounts: [550])
        let sizeWithFollowUp = try await ContextSizing.contextSizeForAnalysis(
            firstUser: "user", system: "system", followUpUsers: ["instr"],
            tasks: tasks(speakers: true),
            session: session2
        )
        // Same task flags but higher base -> higher size
        #expect(sizeWithFollowUp > sizeNoFollowUp)
    }
}

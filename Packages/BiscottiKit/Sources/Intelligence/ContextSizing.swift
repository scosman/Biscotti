import LocalLLM
import os

/// Caller-side policy for right-sizing the LLM context window.
///
/// Instead of allocating the full model KV cache for every request, the caller
/// obtains the real input token count (via the XPC tokenizer) and adds a
/// per-task output reservation to produce a tighter context size. This keeps
/// memory proportional to actual prompt length.
///
/// The sizing math is pure and testable; the async act of counting tokens
/// lives in the session/runner layer.
enum ContextSizing {
    private static let log = Logger(
        subsystem: "net.scosman.biscotti",
        category: "ContextSizing"
    )

    // MARK: - Per-task output reserves

    /// Always-on conversation buffer: guarantees headroom even on
    /// speakers-only or title-only runs (no zero-slack windows).
    static let conversationBuffer = 1024

    /// Speaker output reserve — equals `speakerOptions.maxTokens` (512).
    static let speakerOutputReserve = 512

    /// Title output reserve — intentionally LARGER than
    /// `titleOptions.maxTokens` (32) for safety; defined as an explicit
    /// constant rather than derived from titleOptions.
    static let titleOutputReserve = 128

    /// Summary output base — equals `summaryOptions.maxTokens` (2048).
    static let summaryOutputBase = 2048

    /// Fraction of input tokens added to the summary reserve so that longer
    /// meetings get proportionally more summary headroom.
    static let outputReservationInputFraction = 0.15

    /// Maximum context size — intentionally raised so the multi-turn
    /// analysis conversation (inherently longer than a single call) isn't
    /// clipped. The Gemma model supports well beyond 48k context.
    static let maxContextSize = 48 * 1024

    /// Which analysis tasks are active in the current run.
    struct AnalysisTasks {
        let doSpeakers: Bool
        let doSummary: Bool
        let doTitle: Bool
    }

    /// Conversation-aware context sizing with per-task output reservation.
    ///
    /// Each active task reserves its own output budget, summed with the
    /// always-on `conversationBuffer`. This avoids the positional
    /// mis-assignment where a generous trailing reservation was consumed by
    /// a tiny final turn (e.g. title) while the summary was starved.
    ///
    /// The reserve formula reconciles with the old single-output reservation:
    /// when summary is present, `1024 + 2048 + 15% = 3072 + 15%` equals the
    /// old `outputReservation`. Speakers/title add on top; the 1k floor is
    /// now guaranteed regardless.
    ///
    /// - Parameters:
    ///   - firstUser: The first user turn content (contains the transcript).
    ///   - system: The system prompt.
    ///   - followUpUsers: Follow-up user turns (summary and/or title
    ///     instructions); both tiny but counted for correctness.
    ///   - tasks: Which analysis tasks are active in this run.
    ///   - session: The LLM session for token counting.
    static func contextSizeForAnalysis(
        firstUser: String,
        system: String,
        followUpUsers: [String],
        tasks: AnalysisTasks,
        session: any LLMSession
    ) async throws -> Int {
        var msgs: [LLMMessage] = [.system(system), .user(firstUser)]
        for followUp in followUpUsers {
            msgs.append(.user(followUp))
        }
        let base = try await session.countTokens(messages: msgs)

        // Per-task output reservation: always-on buffer + each active task's
        // own reserve. The summary term depends on `base` for its 15% boost.
        let summaryReserve = tasks.doSummary
            ? summaryOutputBase + Int((outputReservationInputFraction * Double(base)).rounded())
            : 0
        let reserve = conversationBuffer
            + (tasks.doSpeakers ? speakerOutputReserve : 0)
            + (tasks.doTitle ? titleOutputReserve : 0)
            + summaryReserve
        let size = min(base + reserve, maxContextSize)

        log.info(
            "Context sized (analysis): baseTokens=\(base), reserve=\(reserve), contextSize=\(size)"
        )

        return size
    }
}

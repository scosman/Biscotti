import LocalLLM
import os

/// Caller-side policy for right-sizing the LLM context window.
///
/// Instead of allocating the full 32k KV cache for every request, the caller
/// obtains the real input token count (via the XPC tokenizer) and adds an
/// output reservation to produce a tighter context size. This keeps memory
/// proportional to actual prompt length.
///
/// The sizing math is pure and testable; the async act of counting tokens
/// lives in the session/runner layer.
enum ContextSizing {
    private static let log = Logger(
        subsystem: "net.scosman.biscotti",
        category: "ContextSizing"
    )

    /// Base tokens reserved for model output. Chosen to accommodate a full
    /// summary (~2k tokens) or speaker-ID output (~512 tokens) with headroom.
    static let outputReservationBase = 3072

    /// Fraction of input tokens added to the base reservation so that longer
    /// meetings get proportionally more output headroom.
    static let outputReservationInputFraction = 0.15

    /// Maximum context size -- matches the prior static default so this change
    /// never allocates MORE than before.
    static let maxContextSize = 32768

    /// Dynamic output reservation: base + a fraction of input token count,
    /// so longer meetings get proportionally more output headroom.
    static func outputReservation(forInputTokens inputTokens: Int) -> Int {
        outputReservationBase + Int((outputReservationInputFraction * Double(inputTokens)).rounded())
    }

    /// Compute the context size for a generation, given the real input token
    /// count from the model's tokenizer.
    ///
    /// Returns `inputTokens + outputReservation(forInputTokens:)`, capped at
    /// `maxContextSize`.
    static func contextSize(forInputTokens inputTokens: Int) -> Int {
        let clamped = max(inputTokens, 1)
        let reservation = outputReservation(forInputTokens: clamped)
        return min(clamped + reservation, maxContextSize)
    }

    /// Conversation-aware context sizing for the multi-turn analysis.
    ///
    /// Counts the transcript once (in `firstUser`) and adds budget for
    /// assistant replies that remain in context before the final generation
    /// and all follow-up user turns.
    ///
    /// - Parameters:
    ///   - firstUser: The first user turn content (contains the transcript).
    ///   - system: The system prompt.
    ///   - followUpUsers: Follow-up user turns (summary and/or title
    ///     instructions); both tiny but counted for correctness.
    ///   - assistantReserveTokens: Budget for all assistant replies that
    ///     remain in context before the final generation (sum of prior
    ///     maxTokens budgets).
    ///   - session: The LLM session for token counting.
    static func contextSizeForAnalysis(
        firstUser: String,
        system: String,
        followUpUsers: [String],
        assistantReserveTokens: Int,
        session: any LLMSession
    ) async throws -> Int {
        var msgs: [LLMMessage] = [.system(system), .user(firstUser)]
        for followUp in followUpUsers {
            msgs.append(.user(followUp))
        }
        let base = try await session.countTokens(messages: msgs)
        let total = base + assistantReserveTokens
        let size = contextSize(forInputTokens: total)

        log.info(
            "Context sized (analysis): baseTokens=\(base), assistantReserve=\(assistantReserveTokens), contextSize=\(size)"
        )

        return size
    }
}

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

    /// Maximum context size — matches the prior static default so this change
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

    /// Count tokens for each prompt pair using the session's tokenizer and
    /// return the context size needed for the largest pair.
    ///
    /// Used when a session serves multiple sequential tasks (e.g., speaker-ID
    /// then summary) that share a single context allocation.
    static func contextSize(
        forPairs pairs: [(system: String, user: String)],
        session: any LLMSession
    ) async throws -> Int {
        precondition(!pairs.isEmpty, "pairs must not be empty")
        var maxTokens = 1
        for pair in pairs {
            let count = try await session.countTokens(
                system: pair.system, user: pair.user
            )
            maxTokens = max(maxTokens, count)
        }

        let reservation = outputReservation(forInputTokens: maxTokens)
        let size = min(maxTokens + reservation, maxContextSize)

        log.info(
            "Context sized (multi-task): maxInputTokens=\(maxTokens), reservation=\(reservation), contextSize=\(size)"
        )

        return size
    }

    /// Count tokens for a single prompt pair and return the context size.
    static func contextSize(
        forSystem system: String,
        user: String,
        session: any LLMSession
    ) async throws -> Int {
        let count = try await session.countTokens(
            system: system, user: user
        )
        let clamped = max(count, 1)
        let reservation = outputReservation(forInputTokens: clamped)
        let size = min(clamped + reservation, maxContextSize)

        log.info(
            "Context sized: inputTokens=\(count), reservation=\(reservation), contextSize=\(size)"
        )

        return size
    }
}

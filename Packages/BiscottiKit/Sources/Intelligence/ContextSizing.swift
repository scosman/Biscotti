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

    /// Tokens reserved for model output. Chosen to accommodate a full summary
    /// (~2k tokens) or speaker-ID output (~512 tokens) with headroom.
    static let outputTokenReservation = 3072

    /// Maximum context size — matches the prior static default so this change
    /// never allocates MORE than before.
    static let maxContextSize = 32768

    /// Compute the context size for a generation, given the real input token
    /// count from the model's tokenizer.
    ///
    /// Returns `inputTokens + outputTokenReservation`, capped at
    /// `maxContextSize`.
    static func contextSize(forInputTokens inputTokens: Int) -> Int {
        let clamped = max(inputTokens, 1)
        return min(clamped + outputTokenReservation, maxContextSize)
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

        let size = min(maxTokens + outputTokenReservation, maxContextSize)

        log.info(
            "Context sized (multi-task): maxInputTokens=\(maxTokens), contextSize=\(size)"
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
        let size = min(max(count, 1) + outputTokenReservation, maxContextSize)

        log.info(
            "Context sized: inputTokens=\(count), contextSize=\(size)"
        )

        return size
    }
}

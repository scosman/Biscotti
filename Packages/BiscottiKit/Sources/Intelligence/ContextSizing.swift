import LocalLLM
import os

/// Caller-side heuristic for right-sizing the LLM context window.
///
/// Instead of allocating the full 32k KV cache for every request, the caller
/// estimates input tokens from character counts and adds an output reservation
/// to produce a tighter context size. This keeps memory proportional to actual
/// prompt length.
///
/// Phase 1 uses `chars / 2` (a deliberate overestimate; real tokenizers produce
/// ~chars/4 for English). Phase 2 will use actual tokenization via an XPC API.
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

    /// Estimate input token count from raw message character counts.
    ///
    /// Uses a conservative `chars / 2` heuristic that intentionally overestimates
    /// token count (real tokenizers typically produce ~chars/4 for English).
    /// The overestimate is safe: it just allocates a slightly larger KV cache.
    static func estimateInputTokens(systemCharCount: Int, userCharCount: Int) -> Int {
        max((systemCharCount + userCharCount) / 2, 1)
    }

    /// Compute the context size for a generation, given the system and user
    /// message text.
    ///
    /// Returns `estimatedInputTokens + outputTokenReservation`, capped at
    /// `maxContextSize`.
    static func contextSize(forSystem system: String, user: String) -> Int {
        let estimated = estimateInputTokens(
            systemCharCount: system.count,
            userCharCount: user.count
        )
        let size = min(estimated + outputTokenReservation, maxContextSize)

        log.info(
            "Context sized: estimatedInputTokens=\(estimated), contextSize=\(size)"
        )

        return size
    }

    /// Compute the context size needed for the larger of two prompt pairs.
    ///
    /// Used when a session serves multiple sequential tasks (e.g., speaker-ID
    /// then summary) that share a single context allocation. Takes the max of
    /// both estimates so the context fits whichever task is larger.
    static func contextSize(
        forPairs pairs: [(system: String, user: String)]
    ) -> Int {
        let maxEstimate = pairs.map {
            estimateInputTokens(
                systemCharCount: $0.system.count,
                userCharCount: $0.user.count
            )
        }.max() ?? 1

        let size = min(maxEstimate + outputTokenReservation, maxContextSize)

        log.info(
            "Context sized (multi-task): maxEstimatedInputTokens=\(maxEstimate), contextSize=\(size)"
        )

        return size
    }
}

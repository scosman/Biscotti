import DataStore
import Foundation
import LocalLLM

/// Runs the summary step: build prompt, stream generation, accumulate partial
/// text, persist the final summary.
enum Summarizer {
    /// Generation options for summary: generous max tokens, moderate temperature,
    /// no thinking, chat template applied.
    static let generationOptions = GenerationOptions(
        maxTokens: 2048,
        temperature: 0.6,
        thinking: .off
    )

    /// Context for a summary run, grouping parameters to stay within the
    /// function_parameter_count lint rule.
    struct Context {
        let meetingID: UUID
        let transcript: TranscriptData
        let names: [Int: String]
        let store: DataStore
        let onPartial: @MainActor (String) -> Void
    }

    /// Runs summary generation for a meeting.
    ///
    /// - Parameters:
    ///   - session: The LLM session to use for streaming generation.
    ///   - context: Grouped parameters: meeting ID, transcript, name map,
    ///     store, and the partial-text callback.
    @MainActor
    static func run(
        _ session: any LLMSession,
        _ context: Context
    ) async throws {
        let formattedTranscript = TranscriptFormatter.plain(
            context.transcript, names: context.names
        )
        let userMessage = IntelligencePrompts.summaryUser(
            transcript: formattedTranscript
        )

        var accumulated = ""

        let stream = await session.generateStreaming(
            system: IntelligencePrompts.summarySystem,
            user: userMessage,
            options: generationOptions
        )

        for try await event in stream {
            switch event {
            case let .token(text):
                accumulated += text
                context.onPartial(accumulated)
            case let .done(result):
                // Use the canonical final text from the result
                accumulated = result.text
            case .reasoningToken:
                // Reasoning tokens ignored (thinking: .off)
                break
            }
        }

        try await context.store.applyGeneratedSummary(
            accumulated, for: context.meetingID
        )
    }
}

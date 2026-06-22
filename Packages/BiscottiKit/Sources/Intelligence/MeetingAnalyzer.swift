import DataStore
import Foundation
import LocalLLM

/// The multi-turn conversation orchestrator that replaced the separate
/// `SpeakerIdentifier` and `Summarizer`. Handles three cases:
/// - A: both speaker identification + summary (multi-turn, transcript reused)
/// - B: speakers only (single turn)
/// - C: summary only (single turn, human names in transcript)
enum MeetingAnalyzer {
    static let speakerOptions = GenerationOptions(
        maxTokens: 512, temperature: 0.2, thinking: .off
    )
    static let summaryOptions = GenerationOptions(
        maxTokens: 2048, temperature: 0.6, thinking: .off
    )

    /// Groups all parameters for an analysis run, keeping function
    /// signatures within the lint threshold.
    struct Context {
        let meetingID: UUID
        let detail: MeetingDetailData
        let transcript: TranscriptData
        let human: [Int: PersonData]
        let doSpeakers: Bool
        let doSummary: Bool
        let store: DataStore
        let onStage: @MainActor (EnhancementStatus) -> Void
        let onPartialSummary: @MainActor (String) -> Void
    }

    /// Runs the analysis conversation inside an already-configured session.
    @MainActor
    static func run(
        _ session: any LLMSession, _ ctx: Context
    ) async throws {
        var messages: [LLMMessage] = [
            .system(IntelligencePrompts.analysisSystem)
        ]

        if ctx.doSpeakers {
            try await runSpeakerTurn(
                session, &messages, ctx
            )
        }

        if ctx.doSummary {
            try await runSummaryTurn(
                session, messages, ctx
            )
        }
    }

    // MARK: - Speaker Turn

    @MainActor
    private static func runSpeakerTurn(
        _ session: any LLMSession,
        _ messages: inout [LLMMessage],
        _ ctx: Context
    ) async throws {
        let transcript = TranscriptFormatter.plain(
            ctx.transcript, names: [:]
        )
        let userContent = IntelligencePrompts.analysisFirstUser(
            detail: ctx.detail, human: ctx.human,
            transcriptSpeakerLabeled: transcript
        )
        messages.append(.user(userContent))

        ctx.onStage(.identifyingSpeakers)
        let raw = try await session.generate(
            messages: messages, options: speakerOptions
        )

        try await persistSpeakers(raw, ctx)

        // Feed model output back verbatim (maximizes KV reuse)
        messages.append(.assistant(raw))

        if ctx.doSummary {
            messages.append(
                .user(IntelligencePrompts.summaryFollowUpUser)
            )
        }
    }

    // MARK: - Summary Turn

    @MainActor
    private static func runSummaryTurn(
        _ session: any LLMSession,
        _ messages: [LLMMessage],
        _ ctx: Context
    ) async throws {
        var msgs = messages

        // If the speaker turn did NOT run, build the summary-only first user turn
        if !ctx.doSpeakers {
            let names = ctx.human.mapValues(\.name)
            let transcript = TranscriptFormatter.plain(
                ctx.transcript, names: names
            )
            let userContent = IntelligencePrompts.summaryOnlyFirstUser(
                detail: ctx.detail, transcriptNamed: transcript
            )
            msgs.append(.user(userContent))
        }

        ctx.onStage(.summarizing)

        var accumulated = ""
        let stream = await session.generateStreaming(
            messages: msgs, options: summaryOptions
        )

        for try await event in stream {
            switch event {
            case let .token(text):
                accumulated += text
                ctx.onPartialSummary(accumulated)
            case let .done(result):
                accumulated = result.text
                ctx.onPartialSummary(accumulated)
            case .reasoningToken:
                break
            }
        }

        try await ctx.store.applyGeneratedSummary(
            accumulated, for: ctx.meetingID
        )
    }

    // MARK: - Persistence

    private static func persistSpeakers(
        _ raw: String, _ ctx: Context
    ) async throws {
        let parsed = SpeakerMappingParser.parse(raw)

        var assignments: [Int: UUID] = [:]
        for (speakerID, mapping) in parsed {
            let personID = try await ctx.store.findOrCreatePerson(
                name: mapping.name, email: mapping.email
            )
            assignments[speakerID] = personID
        }

        try await ctx.store.setSpeakerAssignments(
            assignments, for: ctx.transcript.id
        )
    }
}

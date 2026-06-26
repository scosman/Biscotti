import DataStore
import Foundation
import LocalLLM
#if DEBUG
    import os
#endif

/// The multi-turn conversation orchestrator that replaced the separate
/// `SpeakerIdentifier` and `Summarizer`. Handles four cases:
/// - A: speaker identification + summary + title (multi-turn, transcript reused)
/// - B: speakers only (single turn)
/// - C: summary only (single turn, human names in transcript)
/// - D: title only (single turn, when speakers + summary are both skipped)
/// Plus any two-task combination; each turn threads onto the shared messages.
enum MeetingAnalyzer {
    static let speakerOptions = GenerationOptions(
        maxTokens: 512, temperature: 0.2, thinking: .off
    )
    static let summaryOptions = GenerationOptions(
        maxTokens: 2048, temperature: 0.6, thinking: .off
    )
    static let titleOptions = GenerationOptions(
        maxTokens: 32, temperature: 0.3, thinking: .off
    )

    #if DEBUG
        /// DEBUG-only diagnostics logger. Used to capture the raw speaker-ID
        /// turn output so we can harden the parser/prompt against weaker
        /// models (e.g. E2B). Not compiled into release builds.
        private static let debugLog = Logger(
            subsystem: "net.scosman.biscotti", category: "MeetingAnalyzer"
        )
    #endif

    /// Groups all parameters for an analysis run, keeping function
    /// signatures within the lint threshold.
    struct Context {
        let meetingID: UUID
        let detail: MeetingDetailData
        let transcript: TranscriptData
        let human: [Int: PersonData]
        let doSpeakers: Bool
        let doSummary: Bool
        let doTitle: Bool
        let summaryInstructions: String
        let markSummaryEdited: Bool
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

        // Track whether any prior turn ran (for title first-user logic)
        var priorTurnRan = false

        if ctx.doSpeakers {
            try await runSpeakerTurn(
                session, &messages, ctx
            )
            priorTurnRan = true
        }

        if ctx.doSummary {
            try await runSummaryTurn(
                session, &messages, ctx,
                priorTurnRan: priorTurnRan
            )
            priorTurnRan = true
        }

        if ctx.doTitle {
            try await runTitleTurn(
                session, &messages, ctx,
                priorTurnRan: priorTurnRan
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

        #if DEBUG
            debugLog.info(
                "Speaker-ID turn raw response:\n\(raw, privacy: .public)"
            )
        #endif

        try await persistSpeakers(raw, ctx)

        // Feed model output back verbatim (maximizes KV reuse)
        messages.append(.assistant(raw))
    }

    // MARK: - Summary Turn

    @MainActor
    private static func runSummaryTurn(
        _ session: any LLMSession,
        _ messages: inout [LLMMessage],
        _ ctx: Context,
        priorTurnRan: Bool
    ) async throws {
        if priorTurnRan {
            // Transcript is already in context; just add the summary task
            messages.append(
                .user(IntelligencePrompts.summaryFollowUpUser(
                    summaryInstructions: ctx.summaryInstructions
                ))
            )
        } else {
            // No prior turn -- build the summary-only first user turn
            let names = ctx.human.mapValues(\.name)
            let transcript = TranscriptFormatter.plain(
                ctx.transcript, names: names
            )
            let userContent = IntelligencePrompts.summaryOnlyFirstUser(
                detail: ctx.detail, transcriptNamed: transcript,
                summaryInstructions: ctx.summaryInstructions
            )
            messages.append(.user(userContent))
        }

        ctx.onStage(.summarizing)

        var accumulated = ""
        let stream = await session.generateStreaming(
            messages: messages, options: summaryOptions
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
            accumulated, for: ctx.meetingID,
            markEdited: ctx.markSummaryEdited
        )

        // Feed model output back verbatim (for subsequent title turn)
        messages.append(.assistant(accumulated))
    }

    // MARK: - Title Turn

    @MainActor
    private static func runTitleTurn(
        _ session: any LLMSession,
        _ messages: inout [LLMMessage],
        _ ctx: Context,
        priorTurnRan: Bool
    ) async throws {
        if priorTurnRan {
            // Transcript is already in context; just add the title task
            messages.append(
                .user(IntelligencePrompts.titleFollowUpUser)
            )
        } else {
            // No prior turn -- build the title-only first user turn
            let names = ctx.human.mapValues(\.name)
            let transcript = TranscriptFormatter.plain(
                ctx.transcript, names: names
            )
            let userContent = IntelligencePrompts.titleOnlyFirstUser(
                detail: ctx.detail, transcriptNamed: transcript
            )
            messages.append(.user(userContent))
        }

        ctx.onStage(.generatingTitle)

        let raw = try await session.generate(
            messages: messages, options: titleOptions
        )

        if let cleaned = cleanTitle(raw) {
            try await ctx.store.applyGeneratedTitle(
                cleaned, for: ctx.meetingID
            )
        }

        messages.append(.assistant(raw))
    }

    // MARK: - Title Cleaning

    /// Cleans a raw LLM title output to a usable title string.
    ///
    /// Steps: trim whitespace/newlines; take first non-empty line; strip
    /// a leading `Title:` or `Title -` prefix; strip surrounding matching
    /// quotes; trim again; cap length at 120 characters; return nil if empty.
    static func cleanTitle(_ raw: String) -> String? {
        // Take first non-empty line
        let firstLine = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }

        guard var result = firstLine else { return nil }

        // Strip "Title:" or "Title -" prefix (case-insensitive)
        let prefixes = ["title:", "title -"]
        let lower = result.lowercased()
        if let matched = prefixes.first(where: { lower.hasPrefix($0) }) {
            result = String(result.dropFirst(matched.count))
                .trimmingCharacters(in: .whitespaces)
        }

        // Strip surrounding matching quotes
        if result.count >= 2,
           let first = result.first,
           let last = result.last
        {
            let matchingQuotes: [(Character, Character)] = [
                ("\"", "\""), ("\u{201C}", "\u{201D}"),
                ("'", "'"), ("\u{2018}", "\u{2019}")
            ]
            for (open, close) in matchingQuotes where first == open && last == close {
                result = String(result.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Final trim
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cap length
        if result.count > 120 {
            result = String(result.prefix(120))
        }

        return result.isEmpty ? nil : result
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

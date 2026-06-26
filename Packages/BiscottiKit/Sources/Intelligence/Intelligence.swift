import DataStore
import Foundation
import LocalLLM

/// The in-process owner of all Biscotti LLM scenario logic.
///
/// Parallels `TranscriptionService`: holds observable per-meeting status the UI
/// watches. Model management (download, selection, suitability) is delegated to
/// `ModelManager`; this class owns the analysis orchestration.
@MainActor @Observable
public final class Intelligence {
    // MARK: - Observable state

    /// Per-meeting enhancement status. The UI observes this for status pills
    /// and to know when to reload.
    public package(set) var jobs: [UUID: EnhancementStatus] = [:]

    /// Live partial markdown during streaming summary generation, keyed by
    /// meeting ID. Cleared when generation completes or fails.
    public package(set) var streamingSummary: [UUID: String] = [:]

    // MARK: - Dependencies

    private let store: DataStore
    private let llm: any LLMRunning
    private let modelManager: ModelManager
    private let settingsProvider: @Sendable () async -> AISettings

    // MARK: - In-flight guard

    /// The meeting ID currently being enhanced, if any.
    /// Only one AI run at a time (mirrors TranscriptionService.inFlightMeetingID).
    private var inFlightMeetingID: UUID?

    // MARK: - Init

    /// Creates an `Intelligence` service.
    ///
    /// - Parameters:
    ///   - store: The DataStore for reading/writing meeting data.
    ///   - llm: The LLM session provider (real or fake).
    ///   - modelManager: The model state owner (selection, downloads, suitability).
    ///   - settings: Closure that reads the current AI settings from DataStore.
    public init(
        store: DataStore,
        llm: any LLMRunning,
        modelManager: ModelManager,
        settings: @Sendable @escaping () async -> AISettings
    ) {
        self.store = store
        self.llm = llm
        self.modelManager = modelManager
        settingsProvider = settings
    }

    // MARK: - Auto-run orchestration

    /// Post-transcription auto-run. Reads settings + model presence; runs
    /// the analysis conversation in ONE LLM session; honors the edited-summary
    /// guard. No-op if no model, toggle off, or no transcript.
    public func runAutoEnhancements(meetingID: UUID) async {
        guard inFlightMeetingID == nil else { return }
        inFlightMeetingID = meetingID
        defer { inFlightMeetingID = nil }

        // Set preparing SYNCHRONOUSLY before any await, so the UI never
        // falls back to the "Generate Summary" button during the async gap.
        jobs[meetingID] = .preparing

        let settings = await settingsProvider()
        guard settings.enabled else {
            jobs.removeValue(forKey: meetingID)
            return
        }
        guard let modelURL = modelManager.activeModelURL() else {
            jobs.removeValue(forKey: meetingID)
            return
        }

        guard let detail = try? await store.meetingDetail(id: meetingID),
              let transcript = detail.preferredTranscript
        else {
            jobs.removeValue(forKey: meetingID)
            return
        }

        do {
            try await runAnalysisSession(
                meetingID: meetingID,
                detail: detail, transcript: transcript,
                doSummary: !detail.editedSummary,
                modelURL: modelURL,
                summaryInstructions: settings.summaryPrompt,
                markSummaryEdited: false
            )
            jobs[meetingID] = .completed
        } catch is CancellationError {
            jobs.removeValue(forKey: meetingID)
        } catch {
            jobs[meetingID] = .failed(message: shortDescription(error))
        }
        streamingSummary.removeValue(forKey: meetingID)
    }

    // MARK: - Manual analysis (renamed from generateSummary)

    /// Manual "Generate"/"Regenerate Summary" -- runs the full analysis
    /// (speakers + summary) for the given transcript version. `force`
    /// bypasses the edited-summary check (caller already confirmed).
    /// Not gated by `settings.enabled` (manual intent always works).
    ///
    /// - Parameters:
    ///   - summaryPromptOverride: When non-nil, used as the summary
    ///     instruction instead of the saved prompt for this run only.
    ///   - markResultEdited: When `true`, the resulting summary is
    ///     flagged as user-owned (`editedSummary = true`).
    public func runAnalysis(
        meetingID: UUID, transcriptID: UUID, force: Bool,
        summaryPromptOverride: String? = nil,
        markResultEdited: Bool = false
    ) async {
        guard inFlightMeetingID == nil else { return }
        inFlightMeetingID = meetingID
        defer {
            inFlightMeetingID = nil
        }

        guard let modelURL = modelManager.activeModelURL() else { return }

        // Set preparing SYNCHRONOUSLY before any await.
        jobs[meetingID] = .preparing

        guard let detail = try? await store.meetingDetail(id: meetingID),
              let transcript = try? await store.transcript(id: transcriptID)
        else {
            jobs.removeValue(forKey: meetingID)
            return
        }

        // Guard against overwriting user edits unless forced
        let doSummary = !detail.editedSummary || force

        // Resolve the effective summary instruction
        let effective: String = if let override = summaryPromptOverride {
            override
        } else {
            await (settingsProvider()).summaryPrompt
        }

        do {
            try await runAnalysisSession(
                meetingID: meetingID,
                detail: detail, transcript: transcript,
                doSummary: doSummary,
                modelURL: modelURL,
                summaryInstructions: effective,
                markSummaryEdited: markResultEdited
            )
            jobs[meetingID] = .completed
        } catch is CancellationError {
            jobs.removeValue(forKey: meetingID)
        } catch {
            jobs[meetingID] = .failed(message: shortDescription(error))
        }
        streamingSummary.removeValue(forKey: meetingID)
    }

    // MARK: - Shared Analysis Session

    /// Executes the LLM analysis session. Shared by both auto-run and
    /// manual paths.
    private func runAnalysisSession(
        meetingID: UUID,
        detail: MeetingDetailData,
        transcript: TranscriptData,
        doSummary: Bool,
        modelURL: URL,
        summaryInstructions: String = IntelligencePrompts.defaultSummaryPrompt,
        markSummaryEdited: Bool = false
    ) async throws {
        let human = await (try? store.humanSetSpeakerMappings(
            for: transcript.id
        )) ?? [:]
        let allIDs = Set(
            transcript.segments.compactMap(\.speakerID)
        )
        let doSpeakers = !allIDs.subtracting(Set(human.keys)).isEmpty

        // Title generation: only when the meeting still has the default
        // title and the user has not renamed it. Independent of `force`.
        let doTitle = detail.title == Meeting.defaultTitle
            && !detail.editedTitle

        // Nothing to do: all tasks skipped
        guard doSpeakers || doSummary || doTitle else { return }

        let firstUser = buildFirstUserContent(
            doSpeakers: doSpeakers, doSummary: doSummary,
            detail: detail, transcript: transcript, human: human,
            summaryInstructions: summaryInstructions
        )
        let followUpUsers = contextBudgetFollowUps(
            doSpeakers: doSpeakers, doSummary: doSummary,
            doTitle: doTitle,
            summaryInstructions: summaryInstructions
        )

        try await llm.withSession(model: modelURL, config: .modelOnly) { session in
            let contextSize = try await ContextSizing.contextSizeForAnalysis(
                firstUser: firstUser,
                system: IntelligencePrompts.analysisSystem,
                followUpUsers: followUpUsers,
                tasks: .init(
                    doSpeakers: doSpeakers,
                    doSummary: doSummary,
                    doTitle: doTitle
                ),
                session: session
            )
            try await session.reconfigure(contextSize: contextSize)

            let ctx = MeetingAnalyzer.Context(
                meetingID: meetingID, detail: detail,
                transcript: transcript, human: human,
                doSpeakers: doSpeakers, doSummary: doSummary,
                doTitle: doTitle,
                summaryInstructions: summaryInstructions,
                markSummaryEdited: markSummaryEdited,
                store: self.store,
                onStage: { self.jobs[meetingID] = $0 },
                onPartialSummary: { self.streamingSummary[meetingID] = $0 }
            )
            try await MeetingAnalyzer.run(session, ctx)
        }
    }

    /// Returns follow-up user turns for context sizing, based on which
    /// analysis tasks are active. Output reservation is now handled by
    /// `ContextSizing.contextSizeForAnalysis` via the per-task booleans.
    private func contextBudgetFollowUps(
        doSpeakers: Bool, doSummary: Bool, doTitle: Bool,
        summaryInstructions: String = IntelligencePrompts.defaultSummaryPrompt
    ) -> [String] {
        var users: [String] = []

        if doSpeakers, doSummary || doTitle {
            if doSummary {
                users.append(IntelligencePrompts.summaryFollowUpUser(
                    summaryInstructions: summaryInstructions
                ))
            }
            if doTitle {
                users.append(IntelligencePrompts.titleFollowUpUser)
            }
        } else if doSummary, doTitle {
            users.append(IntelligencePrompts.titleFollowUpUser)
        }

        return users
    }

    /// Builds the first user turn content for context sizing. Matches what
    /// `MeetingAnalyzer.run` will build for the actual generation.
    private func buildFirstUserContent(
        doSpeakers: Bool,
        doSummary: Bool,
        detail: MeetingDetailData,
        transcript: TranscriptData,
        human: [Int: PersonData],
        summaryInstructions: String = IntelligencePrompts.defaultSummaryPrompt
    ) -> String {
        if doSpeakers {
            let plain = TranscriptFormatter.plain(transcript, names: [:])
            return IntelligencePrompts.analysisFirstUser(
                detail: detail, human: human,
                transcriptSpeakerLabeled: plain
            )
        } else if doSummary {
            let names = human.mapValues(\.name)
            let plain = TranscriptFormatter.plain(transcript, names: names)
            return IntelligencePrompts.summaryOnlyFirstUser(
                detail: detail, transcriptNamed: plain,
                summaryInstructions: summaryInstructions
            )
        } else {
            // Title-only: no speakers, no summary
            let names = human.mapValues(\.name)
            let plain = TranscriptFormatter.plain(transcript, names: names)
            return IntelligencePrompts.titleOnlyFirstUser(
                detail: detail, transcriptNamed: plain
            )
        }
    }

    // MARK: - Private helpers

    private func shortDescription(_ error: some Error) -> String {
        if let llmError = error as? LLMServiceError {
            return llmError.localizedDescription
        }
        return error.localizedDescription
    }
}

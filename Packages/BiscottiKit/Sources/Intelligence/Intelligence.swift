import DataStore
import Foundation
import LocalLLM

/// The in-process owner of all Biscotti LLM scenario logic.
///
/// Parallels `TranscriptionService`: holds observable per-meeting status the UI
/// watches, plus model-download state. Depends on injected abstractions
/// (`LLMRunning`, `ModelProviding`) so it unit-tests without a model.
@MainActor @Observable
public final class Intelligence {
    // MARK: - Observable state

    /// Per-meeting enhancement status. The UI observes this for status pills
    /// and to know when to reload.
    public package(set) var jobs: [UUID: EnhancementStatus] = [:]

    /// Live partial markdown during streaming summary generation, keyed by
    /// meeting ID. Cleared when generation completes or fails.
    public package(set) var streamingSummary: [UUID: String] = [:]

    /// Model download lifecycle state, observed by Settings.
    public package(set) var download: ModelDownloadState = .unknown

    // MARK: - Dependencies

    private let store: DataStore
    private let llm: any LLMRunning
    private let models: any ModelProviding
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
    ///   - models: The model presence/download provider (real or fake).
    ///   - settings: Closure that reads the current AI settings from DataStore.
    public init(
        store: DataStore,
        llm: any LLMRunning,
        models: any ModelProviding,
        settings: @Sendable @escaping () async -> AISettings
    ) {
        self.store = store
        self.llm = llm
        self.models = models
        settingsProvider = settings
        refreshModelState()
    }

    // MARK: - Auto-run orchestration

    /// Post-transcription auto-run. Reads settings + model presence; runs
    /// speaker-ID then summary in ONE LLM session; honors the edited-summary
    /// guard. No-op if no model, both toggles off, or no transcript.
    public func runAutoEnhancements(meetingID: UUID) async {
        guard inFlightMeetingID == nil else { return }
        inFlightMeetingID = meetingID
        defer { inFlightMeetingID = nil }

        // Set preparing SYNCHRONOUSLY before any await, so the UI never
        // falls back to the "Generate Summary" button during the async gap.
        jobs[meetingID] = .preparing

        let settings = await settingsProvider()
        guard models.isDownloaded() else {
            jobs.removeValue(forKey: meetingID)
            return
        }
        guard settings.summarize || settings.guessSpeakers else {
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
            try await runEnhancementSession(
                meetingID: meetingID, settings: settings,
                detail: detail, transcript: transcript
            )
            jobs[meetingID] = .completed
        } catch is CancellationError {
            jobs.removeValue(forKey: meetingID)
        } catch {
            jobs[meetingID] = .failed(message: shortDescription(error))
        }
        streamingSummary.removeValue(forKey: meetingID)
    }

    /// Executes the LLM session for auto-enhancements. Extracted to keep the
    /// public entry point under the function_body_length lint threshold.
    private func runEnhancementSession(
        meetingID: UUID, settings: AISettings,
        detail: MeetingDetailData, transcript: TranscriptData
    ) async throws {
        let invitees = extractInvitees(from: detail)
        let doSpeakers = settings.guessSpeakers
        let doSummary = settings.summarize && !detail.editedSummary
        let existingNames: [Int: String] = transcript.speakerAssignments
            .mapValues(\.name)

        let promptPairs = buildPromptPairs(
            doSpeakers: doSpeakers, doSummary: doSummary,
            transcript: transcript, names: existingNames,
            invitees: invitees
        )

        // Nothing to do: both tasks were skipped (e.g. guessSpeakers off +
        // summary skipped by edited-summary guard). Return early without
        // loading the model at all.
        guard !promptPairs.isEmpty else { return }

        // Open session in model-only mode (no context/KV-cache allocated).
        // Count tokens, then reconfigure to the right-sized context before
        // generating. This avoids a transient 32k allocation.
        try await llm.withSession(config: .modelOnly) { session in
            let contextSize = try await ContextSizing.contextSize(
                forPairs: promptPairs, session: session
            )
            try await session.reconfigure(contextSize: contextSize)

            var nameMap = existingNames

            if doSpeakers {
                await MainActor.run { self.jobs[meetingID] = .identifyingSpeakers }
                let resolved = try await SpeakerIdentifier.run(
                    session, transcript, invitees, store
                )
                nameMap = resolved
            }

            if doSummary {
                await MainActor.run { self.jobs[meetingID] = .summarizing }
                let context = Summarizer.Context(
                    meetingID: meetingID, transcript: transcript,
                    names: nameMap, store: store
                ) { partial in
                    self.streamingSummary[meetingID] = partial
                }
                try await Summarizer.run(session, context)
            }
        }
    }

    /// Build prompt pairs for context sizing. Extracted to keep
    /// `runEnhancementSession` under the function body length lint limit.
    private func buildPromptPairs(
        doSpeakers: Bool, doSummary: Bool,
        transcript: TranscriptData, names: [Int: String],
        invitees: [(name: String, email: String?)]
    ) -> [(system: String, user: String)] {
        // Pre-compute prompt pairs for token counting. We format with
        // existing names here, but actual generation formats speaker-ID
        // with `[:]` and summary with the resolved nameMap. The
        // token-count difference is negligible (names are a tiny
        // fraction of the transcript).
        let formattedTranscript = TranscriptFormatter.plain(
            transcript, names: names
        )

        var pairs: [(system: String, user: String)] = []
        if doSpeakers {
            pairs.append((
                system: IntelligencePrompts.speakerSystem,
                user: IntelligencePrompts.speakerUser(
                    transcript: formattedTranscript, invitees: invitees
                )
            ))
        }
        if doSummary {
            pairs.append((
                system: IntelligencePrompts.summarySystem,
                user: IntelligencePrompts.summaryUser(
                    transcript: formattedTranscript
                )
            ))
        }
        return pairs
    }

    // MARK: - Manual summary generation

    /// Manual "Generate"/"Regenerate Summary" from the Summary tab -- summary
    /// only, for the given transcript version. `force` bypasses the edited
    /// check (caller already confirmed).
    public func generateSummary(
        meetingID: UUID, transcriptID: UUID, force: Bool
    ) async {
        guard inFlightMeetingID == nil else { return }
        inFlightMeetingID = meetingID
        defer {
            inFlightMeetingID = nil
        }

        guard models.isDownloaded() else { return }

        // Set summarizing SYNCHRONOUSLY before any await, so the UI
        // shows the spinner immediately (not after the DataStore reads).
        jobs[meetingID] = .summarizing

        guard let detail = try? await store.meetingDetail(id: meetingID),
              let transcript = try? await store.transcript(id: transcriptID)
        else {
            jobs.removeValue(forKey: meetingID)
            return
        }

        // Guard against overwriting user edits unless forced
        if detail.editedSummary, !force {
            jobs.removeValue(forKey: meetingID)
            return
        }

        // Use existing name map from the transcript
        let nameMap: [Int: String] = transcript.speakerAssignments
            .mapValues(\.name)

        do {
            let formattedTranscript = TranscriptFormatter.plain(
                transcript, names: nameMap
            )

            // Open in model-only mode (no context/KV-cache), count tokens,
            // then reconfigure to the right-sized context before generating.
            try await llm.withSession(config: .modelOnly) { session in
                let contextSize = try await ContextSizing.contextSize(
                    forSystem: IntelligencePrompts.summarySystem,
                    user: IntelligencePrompts.summaryUser(
                        transcript: formattedTranscript
                    ),
                    session: session
                )
                try await session.reconfigure(contextSize: contextSize)

                let context = Summarizer.Context(
                    meetingID: meetingID,
                    transcript: transcript,
                    names: nameMap,
                    store: store
                ) { partial in
                    self.streamingSummary[meetingID] = partial
                }
                try await Summarizer.run(session, context)
            }
            jobs[meetingID] = .completed
        } catch is CancellationError {
            jobs.removeValue(forKey: meetingID)
        } catch {
            jobs[meetingID] = .failed(message: shortDescription(error))
        }
        streamingSummary.removeValue(forKey: meetingID)
    }

    // MARK: - Model management

    /// Whether the model file exists on disk.
    public var isModelDownloaded: Bool {
        models.isDownloaded()
    }

    /// Recompute `download` state from disk presence. Called at init and when
    /// the Settings screen appears.
    public func refreshModelState() {
        download = models.isDownloaded() ? .downloaded : .notDownloaded
    }

    /// Download the default model, driving `download` through the state machine.
    public func downloadModel() async {
        download = .downloading(fraction: nil)

        // Track the last reported fraction to throttle progress updates.
        // URLSession can fire thousands of callbacks for a multi-GB download;
        // we only dispatch a MainActor task when the fraction moves by >= 1%.
        let lastFraction = LastFraction()

        do {
            try await models.download { [weak self] bytes, total in
                let fraction = total.map { Double(bytes) / Double($0) }
                guard lastFraction.shouldUpdate(to: fraction) else { return }
                Task { @MainActor [weak self] in
                    self?.download = .downloading(fraction: fraction)
                }
            }
            download = .downloaded
        } catch is CancellationError {
            download = .notDownloaded
        } catch {
            download = .failed(message: shortDescription(error))
        }
    }

    // MARK: - Private helpers

    private func extractInvitees(
        from detail: MeetingDetailData
    ) -> [(name: String, email: String?)] {
        guard let calendar = detail.calendar else { return [] }
        var invitees: [(name: String, email: String?)] = []

        // Organizer first
        if let organizer = calendar.organizer {
            invitees.append((name: organizer.name, email: organizer.email))
        }

        // Then attendees, deduped against organizer
        let organizerID = calendar.organizer?.id
        for attendee in calendar.attendees where attendee.id != organizerID {
            invitees.append((name: attendee.name, email: attendee.email))
        }

        return invitees
    }

    private func shortDescription(_ error: some Error) -> String {
        if let llmError = error as? LLMServiceError {
            return llmError.localizedDescription
        }
        return error.localizedDescription
    }
}

// MARK: - Download progress throttle

/// Tracks the last reported download fraction to avoid dispatching thousands
/// of MainActor tasks during a multi-GB download. Only reports when the
/// fraction changes by >= 1% or transitions to/from nil.
///
/// Marked `@unchecked Sendable` because it is only mutated from the
/// `ModelProviding.download` progress callback (single call site).
private final class LastFraction: @unchecked Sendable {
    private var value: Double?

    /// Returns `true` if the caller should dispatch a UI update for this fraction.
    func shouldUpdate(to newFraction: Double?) -> Bool {
        guard let newFraction else {
            // nil fraction (unknown total): report only the first time
            if value == nil { return false }
            value = nil
            return true
        }
        guard let previous = value else {
            value = newFraction
            return true
        }
        if newFraction - previous >= 0.01 || newFraction >= 1.0 {
            value = newFraction
            return true
        }
        return false
    }
}

import DataStore
import Foundation
import os
import Transcription
import Vocabulary

/// App-level transcription orchestration on top of the `Transcription` engine.
///
/// Resolves audio paths from DataStore, ensures model readiness (forwarding
/// status messages), runs `processAudio`, persists the result, and promotes
/// it as the preferred transcript. Exposes per-meeting `JobStatus` for the UI.
///
/// The engine is injected via the `Transcribing` protocol seam so tests run
/// with a fake (no CoreML, no XPC).
@MainActor @Observable
public final class TranscriptionService {
    // MARK: - Published state

    /// Per-meeting job status. The UI observes this to show download/transcribe
    /// progress, completion, or failure on the Meeting Detail screen.
    ///
    /// `package` setter so view-model tests can inject specific statuses
    /// without running the full transcription pipeline.
    public package(set) var jobs: [UUID: JobStatus] = [:]

    /// When the currently running job for a meeting started. Present only
    /// while that job is in flight (set in `runJob`, removed when the job is
    /// cleaned up). The engine reports no numeric progress, so the UI shows
    /// elapsed time derived from this instead.
    ///
    /// `package` setter so view-model tests can inject a start date.
    public package(set) var jobStartedAt: [UUID: Date] = [:]

    // MARK: - Dependencies

    private let store: DataStore
    private let engine: any Transcribing
    private let vocabulary: VocabularyService

    #if DEBUG
        /// DEBUG-only diagnostics logger. Logs the effective vocabulary handed to
        /// the engine. Lives here rather than in the engine so the lines land in
        /// the app process — the engine runs inside `BiscottiTranscriber.xpc`,
        /// whose logs are awkward to follow from the app. Not compiled into
        /// release builds.
        private static let vocabDebugLog = Logger(
            subsystem: "net.scosman.biscotti", category: "TranscriptionService"
        )
    #endif

    // MARK: - In-flight guard

    /// The meeting ID currently being transcribed, if any.
    /// Only one job runs at a time in the MVP.
    private var inFlightMeetingID: UUID?

    /// Identifies the running job so late cleanup never touches a newer one.
    private var currentJobToken: UUID?

    /// The Task running the current job; `nil` once the job body finished.
    private var currentTask: Task<Void, Never>?

    /// Set by `cancel(meetingID:)`; suppresses all further status writes and
    /// persistence from the cancelled job. Reset when the job is cleaned up.
    private var cancelRequested = false

    /// Token of the job that `cancel(meetingID:)` already shut the engine
    /// down for. Unlike `cancelRequested` it is not reset by `finishJob`, so
    /// `runJob` can tell "cancelled" regardless of which of the two callers
    /// finishes the job first. Tokens are unique, so a stale value is inert.
    private var cancelledJobToken: UUID?

    // MARK: - Init

    /// Creates a `TranscriptionService`.
    ///
    /// - Parameters:
    ///   - store: The `DataStore` actor for resolving audio paths and persisting transcripts.
    ///   - engine: The transcription engine (shared instance, not a factory).
    ///   - vocabulary: The vocabulary service that assembles the effective word list per job.
    public init(store: DataStore, engine: any Transcribing, vocabulary: VocabularyService) {
        self.store = store
        self.engine = engine
        self.vocabulary = vocabulary
    }

    // MARK: - Transcribe

    /// Transcribes audio for a meeting: resolve paths, ensure models, run STT,
    /// persist + promote the result.
    ///
    /// Status updates flow through `jobs[meetingID]` as the job progresses.
    /// On failure, sets `.failed` with a typed message and retriable flag.
    public func transcribe(meetingID: UUID) async {
        await runJob(meetingID: meetingID)
    }

    /// Re-transcribes a meeting from its stored audio files, adding a new
    /// transcript version and promoting it.
    ///
    /// MVP: identical to `transcribe` -- both run the same resolve-download-
    /// transcribe-persist pipeline. Later phases may add custom vocabulary from
    /// the previous transcript, different model selection, or partial re-runs.
    public func reTranscribe(meetingID: UUID) async {
        await runJob(meetingID: meetingID)
    }

    // MARK: - Cancel

    /// Cancels the running transcription job for `meetingID`.
    ///
    /// Cancels the job's Swift Task, shuts the engine down (killing the XPC
    /// worker is the only way to actually stop inference), sets the job
    /// status to `.cancelled`, and releases the in-flight guard so a later
    /// job can start. Returns once the job has unwound. No transcript is
    /// persisted for a cancelled job (see the race note in `executeJob`).
    ///
    /// No-op when `meetingID` is not the job currently running.
    public func cancel(meetingID: UUID) async {
        guard inFlightMeetingID == meetingID,
              !cancelRequested,
              let task = currentTask,
              let token = currentJobToken
        else { return }

        cancelRequested = true
        cancelledJobToken = token
        jobs[meetingID] = .cancelled
        task.cancel()
        await engine.shutdown()
        await task.value
        finishJob(token: token)
    }

    // MARK: - Model readiness (for onboarding)

    /// Downloads/compiles models if needed, forwarding status messages.
    /// Standalone entry point for the onboarding download step (no
    /// transcription job involved).
    public func ensureModelsReady(
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        try await engine.ensureModelsDownloaded(status: status)
    }

    /// Returns `true` when models are already present on disk and do NOT
    /// need to be downloaded.
    ///
    /// This is a **read-only** probe -- it checks the filesystem only.
    /// Unlike the removed `modelsReady()` (which called the download path),
    /// this method never triggers a download or mutates engine state.
    public func modelsArePresent() async -> Bool {
        await engine.modelsPresent()
    }

    // MARK: - Private

    private func runJob(meetingID: UUID) async {
        // Single in-flight guard
        guard inFlightMeetingID == nil else {
            jobs[meetingID] = .failed(
                message: "Another transcription is already in progress.",
                retriable: true
            )
            return
        }

        let token = UUID()
        inFlightMeetingID = meetingID
        currentJobToken = token
        cancelRequested = false
        jobStartedAt[meetingID] = Date()

        // The job runs in its own Task so `cancel(meetingID:)` has a handle
        // to cancel. `runJob` still awaits it, so callers of `transcribe` /
        // `reTranscribe` keep their "returns when the job is over" contract.
        let task = Task { @MainActor [self] in
            await executeJob(meetingID: meetingID)
            // Drop the handle in the same MainActor turn as the final status
            // write, so a late `cancel` cannot overwrite `.completed`.
            currentTask = nil
        }
        currentTask = task
        await task.value

        // A cancelled job was already shut down by `cancel(meetingID:)`.
        // Shutting down again here could kill the worker of a job that
        // started right after the cancel.
        //
        // Otherwise release the XPC worker so its process (and multi-GB
        // model memory) is freed promptly. The next call will reconnect.
        //
        // IMPORTANT: shutdown BEFORE clearing inFlightMeetingID. The
        // `await engine.shutdown()` crosses to the Transcriber actor,
        // yielding the MainActor. If inFlightMeetingID were already nil,
        // a re-entrant `transcribe()` call during that yield (e.g. from
        // a SwiftUI observation callback or a fire-and-forget Task) would
        // pass the guard, call ensureConnected(), and spawn a second XPC
        // worker that nothing ever tears down. Keeping the guard held
        // through shutdown prevents this.
        if cancelledJobToken != token {
            await engine.shutdown()
        }
        finishJob(token: token)
    }

    /// Clears the in-flight state for the job identified by `token`.
    ///
    /// Idempotent and token-guarded: both `runJob` and `cancel` call it, and
    /// whichever runs second must not clobber a job that has since started.
    private func finishJob(token: UUID) {
        guard currentJobToken == token else { return }
        if let meetingID = inFlightMeetingID {
            jobStartedAt[meetingID] = nil
        }
        inFlightMeetingID = nil
        currentJobToken = nil
        currentTask = nil
        cancelRequested = false
    }

    /// Writes a job status unless the running job has been cancelled, so a
    /// cancelled job can never replace `.cancelled` with `.failed` (the
    /// engine throws once its worker is killed) or `.completed`.
    private func setStatus(_ status: JobStatus, for meetingID: UUID) {
        guard !cancelRequested else { return }
        jobs[meetingID] = status
    }

    /// How long to wait before surfacing download-phase status messages.
    ///
    /// On a cache hit the download/init phase finishes well under this
    /// threshold, so the user never sees a "Downloading..." subtitle.
    /// A real download (tens of seconds to minutes) exceeds the delay
    /// and shows it. Set to ~5s per spec to absorb cold-disk / larger-
    /// model init times that can push cache hits past 1-2s.
    static let downloadPhaseDelay: Duration = .seconds(5)

    /// The inner work of a transcription job. Separated from `runJob` so
    /// the caller can deterministically `await engine.shutdown()` after
    /// completion on every exit path (success, failure, or cancellation).
    private func executeJob(meetingID: UUID) async {
        // Start with a generic "Transcribing..." status. Download-phase
        // subtitles are only surfaced after a delay (see downloadModels).
        setStatus(.transcribing, for: meetingID)

        guard let paths = await resolveAudioPaths(meetingID: meetingID) else { return }
        guard !Task.isCancelled else { return }

        guard await downloadModels(meetingID: meetingID) else { return }
        guard !Task.isCancelled else { return }

        // Compute vocabulary ONCE and thread the same array into both the
        // engine call and persistence, so `vocabularyUsed` is byte-identical
        // to what the engine received. Re-transcription goes through the same
        // path and naturally recomputes.
        let vocab = await vocabulary.effectiveVocabulary(meetingID: meetingID)

        #if DEBUG
            Self.vocabDebugLog.debug(
                "Vocabulary for \(meetingID, privacy: .public) (\(vocab.count, privacy: .public) terms): \(vocab.joined(separator: ", "), privacy: .public)"
            )
        #endif

        guard !Task.isCancelled else { return }

        guard let result = await runEngine(meetingID: meetingID, paths: paths, vocabulary: vocab) else { return }

        // Last cancellation check before anything is persisted. A cancel that
        // lands while `addTranscript` itself is awaiting the store cannot be
        // honoured (the write is not interruptible); that window is tiny.
        guard !Task.isCancelled else { return }

        guard await persistAndPromote(meetingID: meetingID, result: result, vocabularyUsed: vocab) else { return }

        setStatus(.completed, for: meetingID)
    }

    /// Resolves the mic (and optional system) audio file paths from the store.
    /// Sets a `.failed` job status and returns `nil` if paths are unavailable.
    private func resolveAudioPaths(meetingID: UUID) async -> (mic: URL, system: URL?)? {
        do {
            guard let resolved = try await store.audioPaths(meetingID: meetingID) else {
                let meetingExists = try await store.meetingExists(id: meetingID)
                if meetingExists {
                    setStatus(.failed(
                        message: "No audio files available for this meeting.",
                        retriable: false
                    ), for: meetingID)
                } else {
                    setStatus(.failed(message: "Meeting not found.", retriable: false), for: meetingID)
                }
                return nil
            }
            return resolved
        } catch {
            setStatus(.failed(
                message: "Failed to resolve audio paths: \(error.localizedDescription)",
                retriable: false
            ), for: meetingID)
            return nil
        }
    }

    /// Ensures models are downloaded, forwarding status messages to `jobs`
    /// only after a delay (so cache hits never flash a download subtitle).
    /// Returns `false` (with `.failed` set) on error.
    private func downloadModels(meetingID: UUID) async -> Bool {
        // Gate: only surface download-phase messages after a delay so
        // cache-hit loads (which finish quickly) never show a subtitle.
        let gate = DownloadPhaseGate(delay: Self.downloadPhaseDelay)

        do {
            try await engine.ensureModelsDownloaded { [weak self] message in
                Task { @MainActor [weak self] in
                    // Drop late messages from a job that already ended.
                    guard let self, inFlightMeetingID == meetingID else { return }
                    if gate.hasElapsed {
                        setStatus(.downloadingModel(message: message), for: meetingID)
                    } else {
                        gate.start { @MainActor [weak self] in
                            guard let self, inFlightMeetingID == meetingID else { return }
                            setStatus(.downloadingModel(message: message), for: meetingID)
                        }
                    }
                }
            }
            gate.cancel()
            return true
        } catch {
            gate.cancel()
            let (message, retriable) = mapEngineError(error)
            setStatus(.failed(message: message, retriable: retriable), for: meetingID)
            return false
        }
    }

    /// Runs STT + diarization. Returns `nil` (with `.failed` set) on error.
    private func runEngine(
        meetingID: UUID,
        paths: (mic: URL, system: URL?),
        vocabulary: [String]
    ) async -> TranscriptResult? {
        setStatus(.transcribing, for: meetingID)
        do {
            return try await engine.processAudio(
                mic: paths.mic,
                system: paths.system,
                customVocabulary: vocabulary
            )
        } catch {
            let (message, retriable) = mapEngineError(error)
            setStatus(.failed(message: message, retriable: retriable), for: meetingID)
            return nil
        }
    }

    /// Persists the transcript result and promotes it as preferred.
    /// Returns `false` (with `.failed` set) on error.
    @discardableResult
    private func persistAndPromote(
        meetingID: UUID,
        result: TranscriptResult,
        vocabularyUsed: [String]
    ) async -> Bool {
        do {
            let transcriptID = try await store.addTranscript(
                result,
                vocabularyUsed: vocabularyUsed,
                mappedEventIdentifier: nil,
                to: meetingID
            )
            try await store.setPreferredTranscript(transcriptID, for: meetingID)
            return true
        } catch {
            setStatus(.failed(
                message: "Failed to save transcript: \(error.localizedDescription)",
                retriable: true
            ), for: meetingID)
            return false
        }
    }

    /// Maps engine-level errors to a user-facing message and retriability flag.
    ///
    /// Retriable errors are those where a retry has a reasonable chance of success:
    /// worker crashes (auto-relaunch), download failures (network transient), and
    /// `needsDownload` (state inconsistency). Non-retriable errors indicate
    /// permanent failures for the current audio (invalid input, model load issues).
    private func mapEngineError(_ error: Error) -> (message: String, retriable: Bool) {
        guard let transcriptionError = error as? TranscriptionError else {
            return (error.localizedDescription, false)
        }

        switch transcriptionError {
        case .workerInterrupted:
            return ("Transcription worker stopped unexpectedly. Tap Retry.", true)

        case let .downloadFailed(detail):
            return ("Model download failed: \(detail)", true)

        case .needsDownload:
            return ("Models need to be downloaded.", true)

        case let .insufficientDisk(required, available):
            let requiredMB = required / 1_048_576
            let availableMB = available / 1_048_576
            return ("Not enough disk space. Need \(requiredMB) MB, have \(availableMB) MB.", true)

        case let .modelLoadFailed(detail):
            return ("Failed to load models: \(detail)", false)

        case .workerUnavailable:
            return ("Transcription worker is not available.", false)

        case let .invalidInput(detail):
            return ("Invalid audio input: \(detail)", false)

        case let .transcriptionFailed(detail):
            return ("Transcription failed: \(detail)", false)

        case let .diarizationFailed(detail):
            return ("Speaker detection failed: \(detail)", false)
        }
    }
}

import DataStore
import Foundation
import Transcription

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

    // MARK: - Dependencies

    private let store: DataStore
    private let engine: any Transcribing

    // MARK: - In-flight guard

    /// The meeting ID currently being transcribed, if any.
    /// Only one job runs at a time in the MVP.
    private var inFlightMeetingID: UUID?

    // MARK: - Init

    /// Creates a `TranscriptionService`.
    ///
    /// - Parameters:
    ///   - store: The `DataStore` actor for resolving audio paths and persisting transcripts.
    ///   - engine: The transcription engine (shared instance, not a factory).
    public init(store: DataStore, engine: any Transcribing) {
        self.store = store
        self.engine = engine
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

    // MARK: - Model readiness (for onboarding)

    /// Downloads/compiles models if needed, forwarding status messages.
    /// Standalone entry point for the onboarding download step (no
    /// transcription job involved).
    public func ensureModelsReady(
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        try await engine.ensureModelsDownloaded(status: status)
    }

    /// Returns `true` when models are already downloaded and ready.
    /// Attempts a dry-run download (no-op if cached) to determine readiness.
    public func modelsReady() async -> Bool {
        do {
            try await engine.ensureModelsDownloaded(status: nil)
            return true
        } catch {
            return false
        }
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

        inFlightMeetingID = meetingID
        await executeJob(meetingID: meetingID)
        // Release the XPC worker so its process (and multi-GB model memory)
        // is freed promptly. The next transcription call will reconnect.
        //
        // IMPORTANT: shutdown BEFORE clearing inFlightMeetingID. The
        // `await engine.shutdown()` crosses to the Transcriber actor,
        // yielding the MainActor. If inFlightMeetingID were already nil,
        // a re-entrant `transcribe()` call during that yield (e.g. from
        // a SwiftUI observation callback or a fire-and-forget Task) would
        // pass the guard, call ensureConnected(), and spawn a second XPC
        // worker that nothing ever tears down. Keeping the guard held
        // through shutdown prevents this.
        await engine.shutdown()
        inFlightMeetingID = nil
    }

    /// The inner work of a transcription job. Separated from `runJob` so
    /// the caller can deterministically `await engine.shutdown()` after
    /// completion on every exit path (success, failure, or cancellation).
    private func executeJob(meetingID: UUID) async {
        jobs[meetingID] = .downloadingModel(message: "Preparing\u{2026}")

        guard let paths = await resolveAudioPaths(meetingID: meetingID) else { return }

        guard await downloadModels(meetingID: meetingID) else { return }

        guard let result = await runEngine(meetingID: meetingID, paths: paths) else { return }

        guard await persistAndPromote(meetingID: meetingID, result: result) else { return }

        jobs[meetingID] = .completed
    }

    /// Resolves mic + system audio file paths from the store.
    /// Sets a `.failed` job status and returns `nil` if paths are unavailable.
    private func resolveAudioPaths(meetingID: UUID) async -> (mic: URL, system: URL)? {
        do {
            guard let resolved = try await store.audioPaths(meetingID: meetingID) else {
                let meetingExists = try await store.meeting(id: meetingID) != nil
                if meetingExists {
                    jobs[meetingID] = .failed(
                        message: "No audio files available for this meeting.",
                        retriable: false
                    )
                } else {
                    jobs[meetingID] = .failed(message: "Meeting not found.", retriable: false)
                }
                return nil
            }
            return resolved
        } catch {
            jobs[meetingID] = .failed(
                message: "Failed to resolve audio paths: \(error.localizedDescription)",
                retriable: false
            )
            return nil
        }
    }

    /// Ensures models are downloaded, forwarding status messages to `jobs`.
    /// Returns `false` (with `.failed` set) on error.
    private func downloadModels(meetingID: UUID) async -> Bool {
        do {
            // Note: The status callback fires in a detached `Task` so it doesn't
            // block the engine. This means a late `.downloadingModel` message could
            // theoretically land after the job has already moved to `.transcribing`.
            // Acceptable for MVP -- the UI will immediately overwrite with the
            // correct state on the next observation cycle.
            try await engine.ensureModelsDownloaded { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.jobs[meetingID] = .downloadingModel(message: message)
                }
            }
            return true
        } catch {
            let (message, retriable) = mapEngineError(error)
            jobs[meetingID] = .failed(message: message, retriable: retriable)
            return false
        }
    }

    /// Runs STT + diarization. Returns `nil` (with `.failed` set) on error.
    private func runEngine(
        meetingID: UUID,
        paths: (mic: URL, system: URL)
    ) async -> TranscriptResult? {
        jobs[meetingID] = .transcribing
        do {
            return try await engine.processAudio(
                mic: paths.mic,
                system: paths.system,
                customVocabulary: []
            )
        } catch {
            let (message, retriable) = mapEngineError(error)
            jobs[meetingID] = .failed(message: message, retriable: retriable)
            return nil
        }
    }

    /// Persists the transcript result and promotes it as preferred.
    /// Returns `false` (with `.failed` set) on error.
    @discardableResult
    private func persistAndPromote(meetingID: UUID, result: TranscriptResult) async -> Bool {
        do {
            let transcriptID = try await store.addTranscript(
                result,
                vocabularyUsed: [],
                mappedEventIdentifier: nil,
                to: meetingID
            )
            try await store.setPreferredTranscript(transcriptID, for: meetingID)
            return true
        } catch {
            jobs[meetingID] = .failed(
                message: "Failed to save transcript: \(error.localizedDescription)",
                retriable: true
            )
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

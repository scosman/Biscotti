import DataStore
import Foundation
import os
import Transcription
import Vocabulary

/// App-level transcription orchestration on top of the `Transcription` engine.
///
/// Final passes run one at a time from a queue keyed by meeting. A pass
/// resolves audio paths from DataStore, ensures model readiness (forwarding
/// status messages), runs `processAudio`, persists the result, and promotes
/// it as the preferred transcript. Exposes per-meeting `JobStatus` for the UI.
///
/// No final pass runs while a recording is in progress: live transcription
/// comes first. A recording that starts during a pass cancels it and puts it
/// back at the front of the queue (see `TranscriptionService+Queue.swift`).
///
/// The engine is injected via the `Transcribing` protocol seam so tests run
/// with a fake (no CoreML, no XPC).
@MainActor @Observable
public final class TranscriptionService {
    // MARK: - Published state

    /// Per-meeting job status. The UI observes this to show queued, download,
    /// transcribe, completion, or failure on the Meeting Detail screen.
    ///
    /// `package` setter so view-model tests can inject specific statuses
    /// without running the full transcription pipeline.
    public package(set) var jobs: [UUID: JobStatus] = [:]

    /// The models loading in the background now, so macOS compiles them
    /// before a meeting needs them; empty while none do. Settings shows when
    /// the live model is among them.
    public internal(set) var modelsBeingPrepared: [String] = []

    public var isPreparingModels: Bool {
        !modelsBeingPrepared.isEmpty
    }

    // MARK: - Dependencies

    let store: DataStore
    let engine: any Transcribing
    let vocabulary: VocabularyService

    /// How long a recording's start waits for the worker to report that a
    /// cancelled pass has stopped before shutting the worker down.
    let cancelTimeout: Duration

    static let log = Logger(subsystem: "net.scosman.biscotti", category: "TranscriptionService")

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

    // MARK: - Queue state

    /// Meetings waiting for a final pass, first in, first out.
    @ObservationIgnored var queue: [UUID] = []

    /// The meeting whose pass is running, from its start until its waiters
    /// resume, including the worker shutdown after it.
    @ObservationIgnored var running: UUID?

    /// The recording in progress. No pass starts while it is set.
    @ObservationIgnored var activeRecordingID: UUID?

    /// Set when a recording starts during `running`'s pass: the pass's end is
    /// a requeue, not a result or a failure.
    @ObservationIgnored var runningIsCancelledForRecording = false

    /// Set when a pass lost its worker (`workerInterrupted`). The client keeps
    /// the interruption flagged until a shutdown, so the next job would fail
    /// at once without running; the runner shuts the worker down after it.
    /// TODO: Two paths recover a crashed worker: this flag and the retry-once
    /// in `downloadModelsOnAWorkingWorker`. Set the flag on every idle
    /// `workerWasInterrupted` (today only with a kept model) and drop the
    /// retry, if that report always precedes the next job.
    @ObservationIgnored var workerNeedsReset = false

    /// Callers of `transcribe` waiting for their meeting's job to end.
    @ObservationIgnored var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    /// The task that drains the queue, while it does.
    @ObservationIgnored var runner: Task<Void, Never>?

    /// Preparations waiting, in order, each a list of models prepared in one
    /// run, once no recording runs and no pass waits.
    @ObservationIgnored var pendingPreparation: [[String]] = []

    /// The live model kept loaded in the worker while the live transcript is on.
    @ObservationIgnored var residentModel: String?

    /// Whether `residentModel` is loaded in the current worker.
    @ObservationIgnored var residentIsLoaded = false

    /// `residentModel` could not be loaded: it is missing or broken, or the
    /// worker failed while loading it `residentLoadAttempts` times in a row.
    @ObservationIgnored var residentLoadFailed = false

    /// Loads of `residentModel` in a row that the worker failed during.
    @ObservationIgnored var residentLoadMisses = 0

    /// `residentModel` was downloaded again: its next load reads the new
    /// files even if the worker still holds the old ones.
    @ObservationIgnored var residentNeedsReload = false

    /// Whether the startup disk was below `DiskSpace.lowThreshold` when
    /// last read (`refreshDiskSpace`): Settings opening, a slow live start or
    /// a slow final-pass load reads it.
    public internal(set) var isLowOnDiskSpace = false

    /// The meeting whose final pass is loading its model slowly because the
    /// disk is low; its status says so while the load runs.
    public internal(set) var slowModelLoadOnLowDisk: UUID?

    @ObservationIgnored let diskSpace: DiskSpace

    /// How long a final pass's model load runs before it counts as compiling.
    @ObservationIgnored let slowLoadThreshold: Duration

    /// Whether the engine reports final-pass model loads to this service.
    @ObservationIgnored var observesModelLoads = false

    /// Waits out `slowLoadThreshold` for the model load in progress.
    @ObservationIgnored var slowLoadCheck: Task<Void, Never>?

    /// Whether the engine reports worker crashes to this service.
    @ObservationIgnored var observesWorkerInterruptions = false

    /// Models downloaded again while their run loads them; they are
    /// prepared once more after it.
    @ObservationIgnored var preparedAgainAfterRun: Set<String> = []

    /// Set when a recording or a final pass stopped the running preparation:
    /// the models it did not prepare wait for the queue to be free again.
    @ObservationIgnored var preparationIsCancelled = false

    /// The models already prepared for this build.
    @ObservationIgnored let preparedModels: PreparedModels

    // MARK: - Init

    /// Creates a `TranscriptionService`.
    ///
    /// - Parameters:
    ///   - store: The `DataStore` actor for resolving audio paths and persisting transcripts.
    ///   - engine: The transcription engine (shared instance, not a factory).
    ///   - vocabulary: The vocabulary service that assembles the effective word list per job.
    ///   - cancelTimeout: How long `recordingDidStart` waits for the worker to
    ///     stop a running pass before it shuts the worker down.
    ///   - preparedModels: The models already prepared for this build; by
    ///     default an empty record kept in memory.
    ///   - diskSpace: Reads the startup disk's free space.
    ///   - slowLoadThreshold: How long a final pass's model load runs before
    ///     it counts as compiling.
    public init(
        store: DataStore,
        engine: any Transcribing,
        vocabulary: VocabularyService,
        cancelTimeout: Duration = .seconds(5),
        preparedModels: PreparedModels? = nil,
        diskSpace: DiskSpace = .system,
        slowLoadThreshold: Duration = SlowModelLoad.compileThreshold
    ) {
        self.store = store
        self.engine = engine
        self.vocabulary = vocabulary
        self.cancelTimeout = cancelTimeout
        self.preparedModels = preparedModels ?? PreparedModels(build: "")
        self.diskSpace = diskSpace
        self.slowLoadThreshold = slowLoadThreshold
    }

    // MARK: - Transcribe

    /// Queues a final pass for a meeting and returns when that job ends
    /// (completed or failed). A meeting already queued or running is not
    /// queued twice; the call waits for the same job.
    ///
    /// Status updates flow through `jobs[meetingID]` as the job progresses.
    /// On failure, sets `.failed` with a typed message and retriable flag.
    public func transcribe(meetingID: UUID) async {
        await enqueueAndWait(meetingID)
    }

    /// Re-transcribes a meeting from its stored audio files, adding a new
    /// transcript version and promoting it. Queued like `transcribe`, except
    /// that a request made while the meeting's own pass runs queues one more
    /// pass after it, so the new pass uses the vocabulary as it is now.
    public func reTranscribe(meetingID: UUID) async {
        await enqueueAndWait(meetingID, rerunsARunningPass: true)
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

    // MARK: - Job

    /// How a job left the runner.
    enum JobOutcome {
        /// Completed or failed; its waiters resume.
        case ended
        /// Stopped for a recording; it goes back to the front of the queue.
        case cancelledForRecording
        /// The worker refused it as busy, for example while a live session
        /// loads its model; it goes back to the front and runs once the
        /// worker is idle.
        case waitingForWorker
    }

    /// How long to wait before surfacing download-phase status messages.
    ///
    /// On a cache hit the download/init phase finishes well under this
    /// threshold, so the user never sees a "Downloading..." subtitle.
    /// A real download (tens of seconds to minutes) exceeds the delay
    /// and shows it. Set to ~5s per spec to absorb cold-disk / larger-
    /// model init times that can push cache hits past 1-2s.
    static let downloadPhaseDelay: Duration = .seconds(5)

    /// The work of one final pass. The runner shuts the worker down after it
    /// when nothing else waits, on every exit path.
    func executeJob(meetingID: UUID) async -> JobOutcome {
        // Start with a generic "Transcribing..." status. Download-phase
        // subtitles are only surfaced after a delay (see downloadModels).
        jobs[meetingID] = .transcribing

        guard let paths = await resolveAudioPaths(meetingID: meetingID) else { return .ended }
        guard !runningIsCancelledForRecording else { return .cancelledForRecording }

        if let error = await downloadModelsOnAWorkingWorker(meetingID: meetingID) {
            return engineFailed(meetingID: meetingID, error: error)
        }

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

        guard !runningIsCancelledForRecording else { return .cancelledForRecording }
        jobs[meetingID] = .transcribing
        let result: TranscriptResult
        do {
            result = try await engine.processAudio(mic: paths.mic, system: paths.system, customVocabulary: vocab)
        } catch {
            return engineFailed(meetingID: meetingID, error: error)
        }

        // A pass that finished before the cancellation reached the worker is
        // saved like any other.
        guard await persistAndPromote(meetingID: meetingID, result: result, vocabularyUsed: vocab) else { return .ended }

        jobs[meetingID] = .completed
        return .ended
    }

    /// The job's first worker call. A worker that crashed while no pass ran
    /// (during a live session, say) is reported as `workerInterrupted` by
    /// the next call; this pass never reached it, so it starts again once, on
    /// a fresh worker.
    private func downloadModelsOnAWorkingWorker(meetingID: UUID) async -> (any Error)? {
        let error = await downloadModels(meetingID: meetingID)
        guard (error as? TranscriptionError) == .workerInterrupted, !runningIsCancelledForRecording else { return error }
        workerNeedsReset = false
        await shutDownWorker()
        guard !runningIsCancelledForRecording else { return error }
        return await downloadModels(meetingID: meetingID)
    }

    /// An engine call failed. During a recording that cancelled the pass, the
    /// failure is the cancellation (or the worker shut down after it), so the
    /// job is requeued instead of reported. A pass the worker refused as busy
    /// waits for it instead of failing.
    private func engineFailed(meetingID: UUID, error: any Error) -> JobOutcome {
        if (error as? TranscriptionError) == .workerInterrupted {
            workerNeedsReset = true
        }
        if runningIsCancelledForRecording {
            return .cancelledForRecording
        }
        if (error as? TranscriptionError) == .workerBusy {
            return .waitingForWorker
        }
        let (message, retriable) = mapEngineError(error)
        jobs[meetingID] = .failed(message: message, retriable: retriable)
        return .ended
    }

    /// Resolves mic + system audio file paths from the store.
    /// Sets a `.failed` job status and returns `nil` if paths are unavailable.
    private func resolveAudioPaths(meetingID: UUID) async -> (mic: URL, system: URL)? {
        do {
            guard let resolved = try await store.audioPaths(meetingID: meetingID) else {
                let meetingExists = try await store.meetingExists(id: meetingID)
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

    /// Ensures models are downloaded, forwarding status messages to `jobs`
    /// only after a delay (so cache hits never flash a download subtitle).
    /// Returns the engine's error, if any.
    private func downloadModels(meetingID: UUID) async -> (any Error)? {
        // Gate: only surface download-phase messages after a delay so
        // cache-hit loads (which finish quickly) never show a subtitle.
        let gate = DownloadPhaseGate(delay: Self.downloadPhaseDelay)
        defer { gate.cancel() }

        do {
            try await engine.ensureModelsDownloaded { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, running == meetingID else { return }
                    if gate.hasElapsed {
                        jobs[meetingID] = .downloadingModel(message: message)
                    } else {
                        gate.start { @MainActor [weak self] in
                            self?.jobs[meetingID] = .downloadingModel(
                                message: message
                            )
                        }
                    }
                }
            }
            return nil
        } catch {
            return error
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
    func mapEngineError(_ error: Error) -> (message: String, retriable: Bool) {
        guard let transcriptionError = error as? TranscriptionError else {
            return (error.localizedDescription, false)
        }

        switch transcriptionError {
        case .workerInterrupted, .cancelled, .workerBusy:
            return (Self.workerRetryMessage(transcriptionError), true)

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

    /// The worker stopped this pass, or would not run it, before it finished;
    /// running it again can succeed. A pass cancelled for a recording is
    /// requeued, so `.cancelled` here came from elsewhere. A pass the worker
    /// refuses as busy waits for it (`engineFailed`), so no current path
    /// reports the busy message.
    private static func workerRetryMessage(_ error: TranscriptionError) -> String {
        if error == .workerBusy {
            return "The transcription worker was busy. Tap Retry."
        }
        if error == .cancelled {
            return "Transcription stopped before it finished. Tap Retry."
        }
        return "Transcription worker stopped unexpectedly. Tap Retry."
    }
}

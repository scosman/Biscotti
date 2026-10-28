import Foundation
import Synchronization
import Transcription

/// The final-pass queue: one pass at a time, first in, first out, and none
/// while a recording is in progress. The recording's ID is the meeting ID.
public extension TranscriptionService {
    /// A recording started. Queued meetings wait for it to stop. A running pass
    /// is cancelled and goes back to the front of the queue; this returns once
    /// the worker reports that it has stopped, so the live session never meets
    /// a running final pass. If the worker does not answer within
    /// `cancelTimeout`, this returns then; the worker is shut down when the
    /// cancelled pass still runs, and the next call starts a fresh one.
    ///
    /// - Parameter liveTranscription: Whether a live session runs during this
    ///   recording. Without one, nothing needs the worker until the recording
    ///   stops, so it is shut down after the cancel and the final pass's
    ///   models do not stay loaded through the meeting.
    ///
    /// A model preparation that runs is stopped the same way, and finishes
    /// after the recording, unless it is loading `liveModel`: the
    /// recording's live session needs that model and waits for the load in
    /// progress instead of starting it again.
    ///
    /// - Parameter liveModel: The model the recording's live session loads.
    func recordingDidStart(_ recordingID: UUID, liveTranscription: Bool = false, keepingPreparationOf liveModel: String? = nil) async {
        activeRecordingID = recordingID
        for meetingID in queue {
            jobs[meetingID] = .queued(.waitingForRecording)
        }
        let isStillRunning: @MainActor () -> Bool
        if let liveModel, modelsBeingPrepared.contains(liveModel) {
            Self.log.notice("Keeping the live model's preparation for the recording")
            return
        } else if let cancelled = running {
            runningIsCancelledForRecording = true
            // Only the pass this recording cancelled. If the recording stopped
            // and the next pass started meanwhile, it must not be cut.
            isStillRunning = { [weak self] in self?.running == cancelled && self?.runningIsCancelledForRecording == true }
        } else if isPreparingModels {
            let models = modelsBeingPrepared
            preparationIsCancelled = true
            isStillRunning = { [weak self] in self?.modelsBeingPrepared == models && self?.preparationIsCancelled == true }
        } else {
            return
        }
        let engine = engine
        let timeout = cancelTimeout
        let answered = await Self.finishes(within: timeout) { await engine.cancelActiveWork() }
        if !answered {
            guard isStillRunning() else { return }
            // Usually a pass still loading its model: a Core ML load cannot be
            // stopped, and a compile after a purge takes minutes. Shutting the
            // worker down drops the kept live model too, so this recording's
            // live session loads it in a fresh worker (0.3 s from the compiled
            // cache), and backfill covers the wait. Waiting for the load
            // instead would hold the live start for as long as it runs.
            Self.log.error("The transcription worker did not stop its work within \(timeout, privacy: .public); shutting it down")
            await shutDownWorker()
        } else if !liveTranscription, activeRecordingID == recordingID {
            await shutDownWorker()
        }
    }

    /// Queues models to load once in the worker, in one run, so macOS
    /// compiles them before a meeting needs them. Models already prepared for
    /// this build, waiting or being prepared are left out. The preparation
    /// runs only while no recording runs and no final pass waits; either one
    /// stops it, and what it did not prepare then runs once the queue is free
    /// again.
    ///
    /// - Parameter first: Runs before the runs already queued, as the live
    ///   model's does: a recording waits for it.
    func prepareModels(_ models: [String], first: Bool = false) {
        let known = Set(pendingPreparation.joined() + modelsBeingPrepared)
        let needed = models.filter { !preparedModels.contains($0) && !known.contains($0) }
        guard !needed.isEmpty else { return }
        if first {
            pendingPreparation.insert(needed, at: 0)
        } else {
            pendingPreparation.append(needed)
        }
        startRunnerIfNeeded()
    }

    /// Keeps `model` loaded in the worker while the live transcript is on,
    /// so a recording's live start needs no load (macOS may have purged the
    /// compiled model under low disk space, making every load a recompile).
    /// It is loaded once no recording runs and no final pass waits, and the
    /// worker then stays up, the model loaded through final passes and
    /// preparations; a pass's own models are unloaded after it. After a
    /// worker crash it is loaded again in a fresh worker. Nil releases it:
    /// an idle worker is shut down, and a load of the old model still queued
    /// is dropped, so it does not compile a model nothing keeps.
    func keepModelLoaded(_ model: String?) {
        guard model != residentModel else {
            loadResidentModelIfNeeded()
            return
        }
        if let released = residentModel {
            pendingPreparation.removeAll { $0 == [released] }
        }
        residentModel = model
        residentIsLoaded = false
        residentLoadFailed = false
        residentLoadMisses = 0
        residentNeedsReload = false
        if model == nil {
            Task { await releaseWorkerIfIdle() }
        } else {
            observeWorkerInterruptions()
            loadResidentModelIfNeeded()
        }
    }

    /// Forgets that a model was prepared for this build, for example after it
    /// was downloaded again, so the next `prepareModels` loads it again. A
    /// model being prepared now may have loaded the old files: it is
    /// prepared once more after this run. A queued one loads the new files.
    /// A model kept loaded is loaded again from the new files.
    func forgetPreparedModel(_ model: String) {
        preparedModels.forget(model)
        if modelsBeingPrepared.contains(model) {
            preparedAgainAfterRun.insert(model)
        }
        if model == residentModel {
            residentNeedsReload = true
            residentIsLoaded = false
            residentLoadFailed = false
            residentLoadMisses = 0
            loadResidentModelIfNeeded()
        }
    }

    /// The worker ended while idle or during a recording: a model kept loaded
    /// went with it and is loaded again, in a fresh worker, once no recording
    /// runs. A pass or preparation in flight learns of it from its own call.
    /// A model that failed to load stays failed: the report of the crash that
    /// failed its last load can arrive after that load's run has ended.
    func workerWasInterrupted() {
        guard residentModel != nil, running == nil, !isPreparingModels else { return }
        Self.log.notice("The transcription worker ended; the live model is loaded again when the queue is free")
        residentIsLoaded = false
        workerNeedsReset = true
        loadResidentModelIfNeeded()
    }

    /// A recording stopped, and its live session finishes before
    /// `recordingDidStop` releases the queue. Until then its meeting shows as
    /// waiting for its turn, so its transcript reads as coming, not missing.
    func recordingIsEnding(_ recordingID: UUID) {
        guard activeRecordingID == recordingID, jobs[recordingID] == nil else { return }
        jobs[recordingID] = .queued(.waitingForTurn)
    }

    /// Closes this service's connection to the worker unless a pass runs. A
    /// live finish that ran out of time may have left the worker stuck in a
    /// decode; once the live service has closed its own connection too, the
    /// worker has none left and exits, and the next pass starts a fresh one.
    func releaseWorkerIfIdle() async {
        guard running == nil, !isPreparingModels else { return }
        await shutDownWorker()
    }

    /// A recording stopped. Ignored unless it is the recording in progress, so
    /// a late stop from an earlier recording leaves the queue held.
    func recordingDidStop(_ recordingID: UUID) {
        guard activeRecordingID == recordingID else { return }
        activeRecordingID = nil
        for (position, meetingID) in queue.enumerated() {
            // The head starts at once unless a cancelled pass is still ending.
            jobs[meetingID] = position == 0 && running == nil ? .transcribing : .queued(.waitingForTurn)
        }
        // A model kept loaded that left with the worker during the
        // recording loads again after the passes.
        loadResidentModelIfNeeded()
        startRunnerIfNeeded()
    }
}

extension TranscriptionService {
    /// - Parameter rerunsARunningPass: A re-transcribe of the meeting whose
    ///   pass is running queues one more pass, so it uses the vocabulary as
    ///   it is now; a plain request waits for the running pass.
    func enqueueAndWait(_ meetingID: UUID, rerunsARunningPass: Bool = false) async {
        let isRunning = running == meetingID
        let needsPass = !isRunning || rerunsARunningPass
        if needsPass, !queue.contains(meetingID) {
            // A running pass keeps its status; its rerun shows as queued once
            // the pass ends.
            if !isRunning {
                jobs[meetingID] = initialStatus()
            }
            queue.append(meetingID)
            startRunnerIfNeeded()
            stopPreparationForAPass()
        }
        await withCheckedContinuation { waiters[meetingID, default: []].append($0) }
    }

    /// A preparation never holds up a final pass: it stops after the model
    /// loading at the time, and the pass runs next. A worker that does not
    /// stop within `cancelTimeout` is shut down.
    private func stopPreparationForAPass() {
        guard isPreparingModels, !preparationIsCancelled else { return }
        let models = modelsBeingPrepared
        preparationIsCancelled = true
        let engine = engine
        let timeout = cancelTimeout
        Task { [weak self] in
            let answered = await Self.finishes(within: timeout) { await engine.cancelActiveWork() }
            guard !answered, let self, modelsBeingPrepared == models else { return }
            Self.log.error("The transcription worker did not stop preparing models within \(timeout, privacy: .public); shutting it down")
            await shutDownWorker()
        }
    }

    /// The status of a job joining the queue now.
    private func initialStatus() -> JobStatus {
        if activeRecordingID != nil {
            .queued(.waitingForRecording)
        } else if running != nil || !queue.isEmpty {
            .queued(.waitingForTurn)
        } else {
            // Starts at once; a "waiting" status would only flash.
            .transcribing
        }
    }

    private func startRunnerIfNeeded() {
        guard runner == nil, activeRecordingID == nil, !queue.isEmpty || !pendingPreparation.isEmpty else { return }
        runner = Task { [weak self] in
            await self?.runQueue()
        }
    }

    /// Final passes first, then any model preparation; nothing during a recording.
    private func runQueue() async {
        while activeRecordingID == nil {
            if queue.isEmpty, pendingPreparation.isEmpty {
                // A model to keep loaded is loaded again after a restart.
                loadResidentModelIfNeeded()
            }
            if !queue.isEmpty {
                await runNextPass()
            } else if !pendingPreparation.isEmpty {
                await runPreparation()
            } else {
                break
            }
        }
        runner = nil
    }

    /// No pass, preparation or recording waits.
    private var nothingWaits: Bool {
        queue.isEmpty && pendingPreparation.isEmpty && activeRecordingID == nil
    }

    /// The worker holds the model kept loaded, so it stays up.
    private var holdsResidentModel: Bool {
        residentModel != nil && residentIsLoaded
    }

    /// Ends the worker and its connection. A model kept loaded goes with it
    /// and is loaded again, in a fresh worker, once no recording runs.
    ///
    /// - Parameter reloadingResident: False after the kept model failed to
    ///   load, so a broken model does not restart the worker over and over.
    func shutDownWorker(reloadingResident: Bool = true) async {
        residentIsLoaded = false
        if reloadingResident {
            residentLoadFailed = false
        }
        await engine.shutdown()
        if reloadingResident, activeRecordingID == nil {
            loadResidentModelIfNeeded()
        }
    }

    private func observeWorkerInterruptions() {
        guard !observesWorkerInterruptions else { return }
        observesWorkerInterruptions = true
        let engine = engine
        Task { [weak self] in
            await engine.observeWorkerInterruptions { [weak self] in
                Task { @MainActor in self?.workerWasInterrupted() }
            }
        }
    }

    /// Queues the resident model's load first, unless it is loaded, queued,
    /// being prepared or failed to load in this worker.
    func loadResidentModelIfNeeded() {
        guard let model = residentModel, !residentIsLoaded, !residentLoadFailed,
              !pendingPreparation.joined().contains(model), !modelsBeingPrepared.contains(model)
        else { return }
        pendingPreparation.insert([model], at: 0)
        startRunnerIfNeeded()
    }

    private func runNextPass() async {
        let meetingID = queue.removeFirst()
        running = meetingID
        runningIsCancelledForRecording = false
        observeModelLoadsIfNeeded()
        // A crash left the client's interruption set (see
        // `workerNeedsReset`); the reset waits for this job rather than
        // running during the recording that held the queue.
        if workerNeedsReset {
            workerNeedsReset = false
            await shutDownWorker()
        }
        let outcome = await executeJob(meetingID: meetingID)
        endSlowLoadCheck()
        requeueIfNeeded(meetingID, after: outcome)
        // Release the XPC worker so its process (and multi-GB model
        // memory) is freed, unless more work or a recording needs it. With a
        // model kept loaded, the worker stays and only the pass's models go.
        //
        // `running` stays set through the shutdown. The `await` crosses
        // to the Transcriber actor and yields the MainActor; a request for
        // the same meeting made meanwhile must wait for this job instead
        // of queueing a second pass. A request for another meeting queues
        // and runs next, on a fresh connection.
        if nothingWaits {
            if holdsResidentModel, !workerNeedsReset {
                await engine.unloadFinalPassModels()
            } else {
                workerNeedsReset = false
                await shutDownWorker()
            }
        }
        running = nil
        // A meeting queued again (a re-transcribe during its pass) keeps
        // its callers waiting for the pass that follows.
        if outcome == .ended, !queue.contains(meetingID) {
            resumeWaiters(of: meetingID)
        }
        if outcome == .waitingForWorker {
            await engine.waitUntilWorkerIdle()
        }
    }

    /// Loads the next run's models once in the worker. Models it prepared are
    /// recorded for this build. After a stop for a recording or a pass, the
    /// rest goes back to the front of the queue; otherwise a model that was
    /// missing or failed waits for the next request.
    private func runPreparation() async {
        let models = pendingPreparation.removeFirst()
        modelsBeingPrepared = models
        preparationIsCancelled = false
        if workerNeedsReset {
            workerNeedsReset = false
            await shutDownWorker()
        }
        // A recording or a pass that came during the reset found no worker
        // to stop: this run must not start on the fresh one.
        guard !preparationIsCancelled, activeRecordingID == nil else {
            endPreparation(requeueing: models)
            return
        }
        let keep = residentModel.flatMap { models.contains($0) ? $0 : nil }
        let reload = keep != nil && residentNeedsReload
        Self.log.notice("Preparing \(models.count, privacy: .public) model(s) in the background\(keep == nil ? "" : ", keeping the live model loaded", privacy: .public)")
        var prepared: [String] = []
        var outcome = PreparationCall.answered
        do {
            prepared = try await engine.prepareModels(models, keepLoaded: keep, reloadingKept: reload)
        } catch {
            let transcriptionError = error as? TranscriptionError
            if transcriptionError == .workerInterrupted {
                workerNeedsReset = true
            }
            outcome = transcriptionError == .workerBusy ? .workerBusy : .failed
            if !preparationIsCancelled {
                Self.log.error("Preparing models failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // A model downloaded again during this run is prepared once more.
        let again = models.filter(preparedAgainAfterRun.contains)
        preparedAgainAfterRun.subtract(models)
        preparedModels.record(prepared.filter { !again.contains($0) })
        updateResident(afterPreparing: models, prepared: prepared, again: again, call: outcome)
        if outcome == .workerBusy {
            // Another connection's work holds the worker; trying again at once would spin.
            await engine.waitUntilWorkerIdle()
        }
        let rest = (preparationIsCancelled ? models.filter { !prepared.contains($0) } : []) + again.filter(prepared.contains)
        // The worker holds nothing but a model kept loaded after a run.
        if nothingWaits, rest.isEmpty, !holdsResidentModel {
            workerNeedsReset = false
            await shutDownWorker(reloadingResident: !residentLoadFailed)
        }
        endPreparation(requeueing: rest)
    }

    /// How a preparation call ended.
    enum PreparationCall {
        /// The worker replied with the models it prepared.
        case answered
        /// Another connection's work held the worker.
        case workerBusy
        /// The worker crashed or the connection failed.
        case failed
    }

    /// Loads of the kept model the worker may fail during, in a row, before
    /// it counts as failed, so a model that crashes the worker does not
    /// restart it over and over.
    static let residentLoadAttempts = 3

    /// The kept model stays loaded while other models are prepared. A load
    /// that did not happen because a recording or other work stopped it, or
    /// the worker was busy, is not a failure: the model loads again once the
    /// queue is free.
    private func updateResident(afterPreparing models: [String], prepared: [String], again: [String], call: PreparationCall) {
        guard let resident = residentModel, models.contains(resident) else { return }
        if prepared.contains(resident) {
            residentIsLoaded = !again.contains(resident)
            residentNeedsReload = again.contains(resident)
            residentLoadFailed = false
            residentLoadMisses = 0
            return
        }
        guard !preparationIsCancelled, activeRecordingID == nil else { return }
        switch call {
        case .answered:
            // The worker loaded what it could: the model is missing or broken.
            residentLoadFailed = true
        case .failed:
            residentLoadMisses += 1
            residentLoadFailed = residentLoadMisses >= Self.residentLoadAttempts
        case .workerBusy:
            break
        }
    }

    private func endPreparation(requeueing models: [String]) {
        if !models.isEmpty {
            pendingPreparation.insert(models, at: 0)
        }
        modelsBeingPrepared = []
        preparationIsCancelled = false
    }

    private func requeueIfNeeded(_ meetingID: UUID, after outcome: JobOutcome) {
        switch outcome {
        case .cancelledForRecording:
            queue.removeAll { $0 == meetingID }
            queue.insert(meetingID, at: 0)
            jobs[meetingID] = .queued(.waitingForRecording)
        case .waitingForWorker:
            queue.removeAll { $0 == meetingID }
            queue.insert(meetingID, at: 0)
            jobs[meetingID] = .queued(activeRecordingID == nil ? .waitingForTurn : .waitingForRecording)
        case .ended:
            if queue.contains(meetingID) {
                jobs[meetingID] = .queued(activeRecordingID == nil ? .waitingForTurn : .waitingForRecording)
            }
        }
    }

    private func resumeWaiters(of meetingID: UUID) {
        let waiting = waiters.removeValue(forKey: meetingID) ?? []
        waiting.forEach { $0.resume() }
    }

    /// Runs `operation` and returns whether it finished within `timeout`. An
    /// operation that runs late is left running; nothing waits for it. It
    /// starts on the MainActor, so an engine call in it leaves after the calls
    /// the MainActor has already made.
    static func finishes(within timeout: Duration, _ operation: @escaping @MainActor @Sendable () async -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let first = FirstResult(continuation)
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                first.resume(false)
            }
            Task {
                await operation()
                first.resume(true)
                timer.cancel()
            }
        }
    }
}

/// Resumes a continuation with whichever result comes first.
private final class FirstResult: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: Bool) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: value)
    }
}

import BiscottiTestSupport
import DataStore
import Foundation
import Testing
import Transcription
import TranscriptionService
import Vocabulary

// MARK: - Scripted engine

/// A `Transcribing` fake whose passes, cancellations and shutdowns the test
/// controls. Passes are named by their audio folder (`/tmp/<name>/mic.aac`).
private actor ScriptedTranscriber: Transcribing {
    /// How the worker answers `cancelActiveWork`.
    enum CancelReply {
        /// Stops the running pass (it throws `cancelled`) and returns.
        case acknowledge
        /// Waits for `answerCancel()`, then stops the pass and returns.
        case held
        /// Never answers; only a shutdown ends the wait.
        case never
        /// The worker crashes while it stops the pass.
        case crash
    }

    private(set) var events: [String] = []
    private let holdsPasses: Bool
    private let holdsShutdowns: Bool
    private let cancelReply: CancelReply
    private let failing: Set<String>
    private let crashing: Set<String>
    /// Preparations the worker crashes during, before the next one holds.
    private var crashingPreparations: Int
    /// Like `Transcriber`'s interruption flag: the next call throws
    /// `workerInterrupted` once, unless a shutdown clears it first.
    private var isInterrupted: Bool
    /// While set, the worker refuses passes as busy, as during a live start.
    private var isBusy: Bool
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var passes: [String: CheckedContinuation<TranscriptResult, any Error>] = [:]
    private var preparation: CheckedContinuation<[String], any Error>?
    /// What a preparation a cancel stops reports as prepared.
    private var preparedBeforeCancel: [String] = []
    private var cancels: [CheckedContinuation<Void, Never>] = []
    private var interruptionHandler: (@Sendable () -> Void)?
    private var shutdowns: [CheckedContinuation<Void, Never>] = []

    init(
        holdsPasses: Bool = true,
        holdsShutdowns: Bool = false,
        cancelReply: CancelReply = .acknowledge,
        failing: Set<String> = [],
        crashing: Set<String> = [],
        crashingPreparations: Int = 0,
        startsInterrupted: Bool = false,
        startsBusy: Bool = false
    ) {
        self.holdsPasses = holdsPasses
        self.holdsShutdowns = holdsShutdowns
        self.cancelReply = cancelReply
        self.failing = failing
        self.crashing = crashing
        self.crashingPreparations = crashingPreparations
        isInterrupted = startsInterrupted
        isBusy = startsBusy
    }

    func ensureModelsDownloaded(status _: (@Sendable (String) -> Void)?) async throws {
        try reportInterruption()
    }

    func processAudio(mic: URL, system _: URL, customVocabulary _: [String]) async throws -> TranscriptResult {
        try reportInterruption()
        let name = mic.deletingLastPathComponent().lastPathComponent
        if isBusy {
            events.append("busy \(name)")
            throw TranscriptionError.workerBusy
        }
        events.append("pass \(name)")
        if failing.contains(name) {
            throw TranscriptionError.transcriptionFailed("scripted failure")
        }
        if crashing.contains(name) {
            isInterrupted = true
            throw TranscriptionError.workerInterrupted
        }
        guard holdsPasses else { return FakeTranscriber.defaultResult }
        return try await withCheckedThrowingContinuation { passes[name] = $0 }
    }

    func modelsPresent() async -> Bool {
        true
    }

    /// Runs until `finishPreparation` or a cancel.
    func prepareModels(_ models: [String], keepLoaded: String?, reloadingKept: Bool) async throws -> [String] {
        try reportInterruption()
        if isBusy {
            events.append("busy prepare")
            throw TranscriptionError.workerBusy
        }
        events.append("prepare \(models.joined(separator: ","))\(keepLoaded.map { " keep \($0)" } ?? "")\(reloadingKept ? " reload" : "")")
        if crashingPreparations > 0 {
            crashingPreparations -= 1
            isInterrupted = true
            throw TranscriptionError.workerInterrupted
        }
        return try await withCheckedThrowingContinuation { preparation = $0 }
    }

    func observeWorkerInterruptions(_ handler: @escaping @Sendable () -> Void) async {
        interruptionHandler = handler
    }

    func unloadFinalPassModels() async {
        events.append("unload final models")
    }

    func cancelActiveWork() async {
        events.append("cancel")
        switch cancelReply {
        case .acknowledge:
            stopPasses(throwing: .cancelled)
            stopPreparation()
        case .held:
            await withCheckedContinuation { cancels.append($0) }
            stopPasses(throwing: .cancelled)
            stopPreparation()
        case .never:
            await withCheckedContinuation { cancels.append($0) }
        case .crash:
            isInterrupted = true
            stopPasses(throwing: .workerInterrupted)
            preparation?.resume(throwing: TranscriptionError.workerInterrupted)
            preparation = nil
        }
    }

    func waitUntilWorkerIdle() async {
        events.append("wait for idle")
        guard isBusy else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func shutdown() async {
        events.append("shutdown")
        isInterrupted = false
        // The connection is gone: work still waiting for its reply fails.
        stopPasses(throwing: .workerUnavailable)
        preparation?.resume(throwing: TranscriptionError.workerUnavailable)
        preparation = nil
        answerCancel()
        if holdsShutdowns {
            await withCheckedContinuation { shutdowns.append($0) }
        }
    }

    // MARK: Test controls

    /// The worker crashes with no call in flight.
    func crashWhileIdle() {
        isInterrupted = true
        interruptionHandler?()
    }

    var observesInterruptions: Bool {
        interruptionHandler != nil
    }

    func isRunning(_ name: String) -> Bool {
        passes[name] != nil
    }

    var isPreparing: Bool {
        preparation != nil
    }

    func finishPreparation(_ prepared: [String]) {
        preparation?.resume(returning: prepared)
        preparation = nil
    }

    /// The next preparation a cancel stops has prepared these.
    func prepareBeforeCancel(_ models: [String]) {
        preparedBeforeCancel = models
    }

    private func stopPreparation() {
        preparation?.resume(returning: preparedBeforeCancel)
        preparation = nil
    }

    func finish(_ name: String) {
        passes.removeValue(forKey: name)?.resume(returning: FakeTranscriber.defaultResult)
    }

    /// The live session ended: the worker is idle again.
    func freeWorker() {
        isBusy = false
        let waiting = idleWaiters
        idleWaiters = []
        waiting.forEach { $0.resume() }
    }

    var idleWaitersCount: Int {
        idleWaiters.count
    }

    func answerCancel() {
        let waiting = cancels
        cancels = []
        waiting.forEach { $0.resume() }
    }

    func releaseShutdowns() {
        let waiting = shutdowns
        shutdowns = []
        waiting.forEach { $0.resume() }
    }

    var shutdownsWaiting: Int {
        shutdowns.count
    }

    private func reportInterruption() throws {
        guard isInterrupted else { return }
        isInterrupted = false
        throw TranscriptionError.workerInterrupted
    }

    private func stopPasses(throwing error: TranscriptionError) {
        let running = passes
        passes = [:]
        running.values.forEach { $0.resume(throwing: error) }
    }
}

// MARK: - Fixture

@MainActor
private struct QueueFixture {
    let service: TranscriptionService
    let store: DataStore
    let engine: ScriptedTranscriber

    init(engine: ScriptedTranscriber, cancelTimeout: Duration = .seconds(5)) throws {
        store = try DataStore(storage: .inMemory)
        self.engine = engine
        service = TranscriptionService(store: store, engine: engine, vocabulary: VocabularyService(store: store), cancelTimeout: cancelTimeout)
    }

    /// A meeting whose audio sits in `/tmp/<name>/`, so its pass is named `name`.
    func meeting(_ name: String) async throws -> UUID {
        let meetingID = try await store.createMeeting(title: name)
        try await store.attachAudio([
            AudioFileRef(role: .mic, path: "/tmp/\(name)/mic.aac", byteSize: 100, isPresent: true),
            AudioFileRef(role: .system, path: "/tmp/\(name)/system.aac", byteSize: 100, isPresent: true)
        ], to: meetingID)
        return meetingID
    }

    /// Starts `transcribe` and records when it returns.
    func transcribe(_ meetingID: UUID) -> TranscribeCall {
        let call = TranscribeCall()
        call.task = Task { @MainActor in
            await service.transcribe(meetingID: meetingID)
            call.hasReturned = true
        }
        return call
    }
}

@MainActor
private final class TranscribeCall {
    var task: Task<Void, Never>?
    var hasReturned = false

    func value() async {
        await task?.value
    }
}

/// Waits until `condition` holds, failing the test after two seconds.
@MainActor
private func until(_ condition: @MainActor () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    for _ in 0 ..< 400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for a condition", sourceLocation: sourceLocation)
}

// MARK: - Tests

@Suite("TranscriptionService -- queue")
@MainActor
struct TranscriptionServiceQueueTests {
    @Test("a second job queues instead of failing")
    func secondJobQueuesInsteadOfFailing() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let first = try await fix.meeting("a")
        let second = try await fix.meeting("b")

        let firstCall = fix.transcribe(first)
        try await until { await fix.engine.isRunning("a") }
        let secondCall = fix.transcribe(second)
        try await until { fix.service.jobs[second] != nil }

        #expect(fix.service.jobs[second] == .queued(.waitingForTurn))

        await fix.engine.finish("a")
        try await until { await fix.engine.isRunning("b") }
        await fix.engine.finish("b")
        await firstCall.value()
        await secondCall.value()

        #expect(fix.service.jobs[first] == .completed)
        #expect(fix.service.jobs[second] == .completed)
    }

    @Test("transcribe returns when its own job completes")
    func transcribeReturnsWhenItsJobCompletes() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let first = try await fix.meeting("a")
        let second = try await fix.meeting("b")
        let firstCall = fix.transcribe(first)
        try await until { await fix.engine.isRunning("a") }
        let secondCall = fix.transcribe(second)

        await fix.engine.finish("a")
        await firstCall.value()
        try await until { await fix.engine.isRunning("b") }

        #expect(!secondCall.hasReturned)
        await fix.engine.finish("b")
        await secondCall.value()
        #expect(secondCall.hasReturned)
    }

    @Test("a duplicate request waits on the same job")
    func duplicateRequestWaitsOnTheSameJob() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let meetingID = try await fix.meeting("a")

        let firstCall = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("a") }
        let repeatCall = fix.transcribe(meetingID)
        let queuedCall = fix.transcribe(meetingID)
        await fix.engine.finish("a")
        await firstCall.value()
        await repeatCall.value()
        await queuedCall.value()

        #expect(await fix.engine.events == ["pass a", "shutdown"])
        #expect(fix.service.jobs[meetingID] == .completed)
    }
}

@Suite("TranscriptionService -- queue and recordings")
@MainActor
struct TranscriptionServiceRecordingQueueTests {
    @Test("no final pass starts during a recording")
    func noFinalPassStartsDuringARecording() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(holdsPasses: false))
        let meetingID = try await fix.meeting("a")
        let recording = UUID()
        await fix.service.recordingDidStart(recording)

        let call = fix.transcribe(meetingID)
        try await until { fix.service.jobs[meetingID] != nil }
        try await Task.sleep(for: .milliseconds(50))

        #expect(fix.service.jobs[meetingID] == .queued(.waitingForRecording))
        #expect(await fix.engine.events.isEmpty)

        fix.service.recordingDidStop(recording)
        await call.value()
        #expect(await fix.engine.events == ["pass a", "shutdown"])
        #expect(fix.service.jobs[meetingID] == .completed)
    }

    @Test("a recording start cancels the running pass and requeues it at the front")
    func recordingStartCancelsAndRequeuesTheRunningPassAtTheFront() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let running = try await fix.meeting("a")
        let waiting = try await fix.meeting("b")
        let runningCall = fix.transcribe(running)
        try await until { await fix.engine.isRunning("a") }
        let waitingCall = fix.transcribe(waiting)
        let recording = UUID()

        await fix.service.recordingDidStart(recording, liveTranscription: true)
        try await until { fix.service.jobs[running] == .queued(.waitingForRecording) }
        fix.service.recordingDidStop(recording)

        try await until { await fix.engine.isRunning("a") }
        await fix.engine.finish("a")
        try await until { await fix.engine.isRunning("b") }
        await fix.engine.finish("b")
        await runningCall.value()
        await waitingCall.value()

        // With a live session, the worker stays up while the recording holds the queue.
        #expect(await fix.engine.events == ["pass a", "cancel", "pass a", "pass b", "shutdown"])
        #expect(fix.service.jobs[running] == .completed)
        #expect(fix.service.jobs[waiting] == .completed)
    }

    @Test("a cancelled pass is not reported as failed")
    func cancelledPassIsNotReportedAsFailed() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let meetingID = try await fix.meeting("a")
        let call = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("a") }
        let recording = UUID()

        await fix.service.recordingDidStart(recording)
        try await until { fix.service.jobs[meetingID] == .queued(.waitingForRecording) }
        try await Task.sleep(for: .milliseconds(20))

        // A failed job would have ended and let its caller return.
        #expect(!call.hasReturned)
        #expect(fix.service.jobs[meetingID] == .queued(.waitingForRecording))

        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isRunning("a") }
        await fix.engine.finish("a")
        await call.value()
        #expect(fix.service.jobs[meetingID] == .completed)
    }

    @Test("the queue runs in order after the recording stops")
    func queueRunsInOrderAfterRecordingStops() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(holdsPasses: false))
        let recording = UUID()
        await fix.service.recordingDidStart(recording)
        var calls: [TranscribeCall] = []
        for name in ["a", "b", "c"] {
            let meetingID = try await fix.meeting(name)
            calls.append(fix.transcribe(meetingID))
            try await until { fix.service.jobs[meetingID] != nil }
        }

        fix.service.recordingDidStop(recording)
        for call in calls {
            await call.value()
        }

        #expect(await fix.engine.events == ["pass a", "pass b", "pass c", "shutdown"])
    }

    @Test("a failed job does not block the queue")
    func failedJobDoesNotBlockTheQueue() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(holdsPasses: false, failing: ["a"]))
        let recording = UUID()
        await fix.service.recordingDidStart(recording)
        let failing = try await fix.meeting("a")
        let next = try await fix.meeting("b")
        let failingCall = fix.transcribe(failing)
        try await until { fix.service.jobs[failing] != nil }
        let nextCall = fix.transcribe(next)
        try await until { fix.service.jobs[next] != nil }

        fix.service.recordingDidStop(recording)
        await failingCall.value()
        await nextCall.value()

        #expect(fix.service.jobs[failing] == .failed(message: "Transcription failed: scripted failure", retriable: false))
        #expect(fix.service.jobs[next] == .completed)
    }

    @Test("the worker shuts down only when the queue is idle")
    func workerShutsDownOnlyWhenIdle() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let first = try await fix.meeting("a")
        let second = try await fix.meeting("b")
        let firstCall = fix.transcribe(first)
        try await until { await fix.engine.isRunning("a") }
        let secondCall = fix.transcribe(second)

        await fix.engine.finish("a")
        try await until { await fix.engine.isRunning("b") }
        #expect(await fix.engine.events == ["pass a", "pass b"])

        let recording = UUID()
        await fix.service.recordingDidStart(recording, liveTranscription: true)
        try await until { fix.service.jobs[second] == .queued(.waitingForRecording) }
        #expect(await fix.engine.events == ["pass a", "pass b", "cancel"])

        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isRunning("b") }
        await fix.engine.finish("b")
        await firstCall.value()
        await secondCall.value()
        #expect(await fix.engine.events == ["pass a", "pass b", "cancel", "pass b", "shutdown"])
    }

    @Test("queued meetings wait for the recording, then for their turn")
    func queuedStatusShowsWaitingForRecording() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let running = try await fix.meeting("a")
        let waiting = try await fix.meeting("b")
        let runningCall = fix.transcribe(running)
        try await until { await fix.engine.isRunning("a") }
        let waitingCall = fix.transcribe(waiting)
        try await until { fix.service.jobs[waiting] != nil }
        #expect(fix.service.jobs[waiting] == .queued(.waitingForTurn))

        let recording = UUID()
        await fix.service.recordingDidStart(recording)
        #expect(fix.service.jobs[waiting] == .queued(.waitingForRecording))
        try await until { fix.service.jobs[running] == .queued(.waitingForRecording) }

        fix.service.recordingDidStop(recording)
        // The head starts at once, so it does not show as waiting.
        #expect(fix.service.jobs[running] == .transcribing)
        #expect(fix.service.jobs[waiting] == .queued(.waitingForTurn))

        try await until { await fix.engine.isRunning("a") }
        await fix.engine.finish("a")
        try await until { await fix.engine.isRunning("b") }
        await fix.engine.finish("b")
        await runningCall.value()
        await waitingCall.value()
    }

    @Test("a stop from an earlier recording does not end the active recording")
    func stopFromEarlierRecordingDoesNotEndTheActiveRecording() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(holdsPasses: false))
        let earlier = UUID()
        let current = UUID()
        await fix.service.recordingDidStart(earlier)
        await fix.service.recordingDidStart(current)
        let meetingID = try await fix.meeting("a")
        let call = fix.transcribe(meetingID)
        try await until { fix.service.jobs[meetingID] != nil }

        fix.service.recordingDidStop(earlier)
        try await Task.sleep(for: .milliseconds(50))

        #expect(fix.service.jobs[meetingID] == .queued(.waitingForRecording))
        #expect(await fix.engine.events.isEmpty)

        fix.service.recordingDidStop(current)
        await call.value()
        #expect(fix.service.jobs[meetingID] == .completed)
    }

    @Test("a recording's start waits for the worker to acknowledge that it is idle")
    func admissionWaitsForWorkerIdleAcknowledgement() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(cancelReply: .held))
        let meetingID = try await fix.meeting("a")
        let call = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("a") }

        let recording = UUID()
        var startReturned = false
        let start = Task { @MainActor in
            await fix.service.recordingDidStart(recording)
            startReturned = true
        }
        try await until { await fix.engine.events.contains("cancel") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!startReturned)

        await fix.engine.answerCancel()
        await start.value
        #expect(startReturned)
        try await until { fix.service.jobs[meetingID] == .queued(.waitingForRecording) }
        #expect(!call.hasReturned)

        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isRunning("a") }
        await fix.engine.finish("a")
        await call.value()
    }

    @Test("a cancel the worker never answers shuts the worker down")
    func unansweredCancelShutsTheWorkerDown() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(cancelReply: .never), cancelTimeout: .milliseconds(100))
        let meetingID = try await fix.meeting("a")
        let call = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("a") }
        let recording = UUID()

        await fix.service.recordingDidStart(recording)

        #expect(await fix.engine.events == ["pass a", "cancel", "shutdown"])
        try await until { fix.service.jobs[meetingID] == .queued(.waitingForRecording) }
        #expect(!call.hasReturned)

        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isRunning("a") }
        await fix.engine.finish("a")
        await call.value()
        #expect(fix.service.jobs[meetingID] == .completed)
    }

    @Test("a request made while the worker shuts down runs after the shutdown")
    func requestDuringShutdownRunsAfterIt() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(holdsPasses: false, holdsShutdowns: true))
        let first = try await fix.meeting("a")
        let second = try await fix.meeting("b")
        let firstCall = fix.transcribe(first)
        try await until { await fix.engine.shutdownsWaiting == 1 }

        // The same meeting waits for the job that is ending; another one queues.
        let repeatCall = fix.transcribe(first)
        let secondCall = fix.transcribe(second)
        try await until { fix.service.jobs[second] != nil }
        await fix.engine.releaseShutdowns()
        await firstCall.value()
        await repeatCall.value()

        try await until { await fix.engine.shutdownsWaiting == 1 }
        await fix.engine.releaseShutdowns()
        await secondCall.value()

        #expect(await fix.engine.events == ["pass a", "shutdown", "pass b", "shutdown"])
        #expect(fix.service.jobs[first] == .completed)
        #expect(fix.service.jobs[second] == .completed)
    }
}

@Suite("TranscriptionService -- queue and the worker's lifetime")
@MainActor
struct TranscriptionServiceWorkerLifetimeTests {
    @Test("a job starting at once shows it is transcribing, never waiting")
    func jobStartingAtOnceShowsTranscribing() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let meetingID = try await fix.meeting("a")

        let call = fix.transcribe(meetingID)
        try await until { fix.service.jobs[meetingID] != nil }

        #expect(fix.service.jobs[meetingID] == .transcribing)
        try await until { await fix.engine.isRunning("a") }
        await fix.engine.finish("a")
        await call.value()
    }

    @Test("a worker lost by one pass is reset before the next pass")
    func workerLostByAPassIsResetBeforeTheNext() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(holdsPasses: false, crashing: ["a"]))
        let recording = UUID()
        await fix.service.recordingDidStart(recording)
        let lost = try await fix.meeting("a")
        let next = try await fix.meeting("b")
        let lostCall = fix.transcribe(lost)
        try await until { fix.service.jobs[lost] != nil }
        let nextCall = fix.transcribe(next)
        try await until { fix.service.jobs[next] != nil }

        fix.service.recordingDidStop(recording)
        await lostCall.value()
        await nextCall.value()

        #expect(fix.service.jobs[lost] == .failed(message: "Transcription worker stopped unexpectedly. Tap Retry.", retriable: true))
        #expect(fix.service.jobs[next] == .completed)
        #expect(await fix.engine.events == ["pass a", "shutdown", "pass b", "shutdown"])
    }

    @Test("a pass whose worker crashed while it was cancelled runs after the recording")
    func passInterruptedWhileCancelledRunsAfterTheRecording() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(cancelReply: .crash))
        let meetingID = try await fix.meeting("a")
        let call = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("a") }
        let recording = UUID()

        await fix.service.recordingDidStart(recording, liveTranscription: true)
        try await until { fix.service.jobs[meetingID] == .queued(.waitingForRecording) }
        try await Task.sleep(for: .milliseconds(20))
        // The reset waits for the next job, not to run beside the live session.
        #expect(await fix.engine.events == ["pass a", "cancel"])

        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isRunning("a") }
        await fix.engine.finish("a")
        await call.value()

        #expect(await fix.engine.events == ["pass a", "cancel", "shutdown", "pass a", "shutdown"])
        #expect(fix.service.jobs[meetingID] == .completed)
    }

    @Test("without a live session, the worker shuts down once the pass has stopped")
    func recordingWithoutLiveShutsTheWorkerDown() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let meetingID = try await fix.meeting("a")
        let call = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("a") }
        let recording = UUID()

        await fix.service.recordingDidStart(recording)

        #expect(await fix.engine.events == ["pass a", "cancel", "shutdown"])
        try await until { fix.service.jobs[meetingID] == .queued(.waitingForRecording) }
        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isRunning("a") }
        await fix.engine.finish("a")
        await call.value()
        #expect(await fix.engine.events == ["pass a", "cancel", "shutdown", "pass a", "shutdown"])
    }

    @Test("with a live session, the worker stays up for it")
    func recordingWithLiveKeepsTheWorker() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let meetingID = try await fix.meeting("a")
        let call = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("a") }
        let recording = UUID()

        await fix.service.recordingDidStart(recording, liveTranscription: true)
        try await until { fix.service.jobs[meetingID] == .queued(.waitingForRecording) }
        try await Task.sleep(for: .milliseconds(20))

        #expect(await fix.engine.events == ["pass a", "cancel"])
        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isRunning("a") }
        await fix.engine.finish("a")
        await call.value()
        #expect(await fix.engine.events == ["pass a", "cancel", "pass a", "shutdown"])
    }

    @Test("a stopped recording whose live session still finishes shows as waiting for its turn")
    func recordingIsEndingShowsWaitingForTurn() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let recording = try await fix.meeting("a")
        await fix.service.recordingDidStart(recording, liveTranscription: true)
        fix.service.recordingIsEnding(UUID())
        #expect(fix.service.jobs.isEmpty, "another recording is ignored")
        fix.service.recordingIsEnding(recording)
        #expect(fix.service.jobs[recording] == .queued(.waitingForTurn))

        fix.service.recordingDidStop(recording)
        let call = fix.transcribe(recording)
        try await until { await fix.engine.isRunning("a") }
        #expect(fix.service.jobs[recording] == .transcribing)
        await fix.engine.finish("a")
        await call.value()
    }

    @Test("releasing an idle worker shuts its connection down, but never under a running pass")
    func releaseWorkerIfIdleShutsDownOnlyWithoutAPass() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        await fix.service.releaseWorkerIfIdle()
        #expect(await fix.engine.events == ["shutdown"])

        let meetingID = try await fix.meeting("a")
        let call = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("a") }
        await fix.service.releaseWorkerIfIdle()
        #expect(await fix.engine.events == ["shutdown", "pass a"])

        await fix.engine.finish("a")
        await call.value()
        #expect(fix.service.jobs[meetingID] == .completed)
    }

    @Test("a cancel deadline that passes after the next pass started leaves that pass alone")
    func lateTimeoutDoesNotShutDownTheNextPass() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(cancelReply: .never), cancelTimeout: .milliseconds(500))
        let first = try await fix.meeting("a")
        let second = try await fix.meeting("b")
        let firstCall = fix.transcribe(first)
        try await until { await fix.engine.isRunning("a") }
        let secondCall = fix.transcribe(second)
        try await until { fix.service.jobs[second] != nil }
        let recording = UUID()
        let start = Task { @MainActor in
            await fix.service.recordingDidStart(recording, liveTranscription: true)
        }
        try await until { await fix.engine.events.contains("cancel") }

        // The cancelled pass finishes anyway, the recording stops and the next pass starts.
        await fix.engine.finish("a")
        await firstCall.value()
        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isRunning("b") }
        await start.value

        #expect(await !fix.engine.events.contains("shutdown"))
        await fix.engine.finish("b")
        await secondCall.value()
        #expect(await fix.engine.events == ["pass a", "cancel", "pass b", "shutdown"])
        #expect(fix.service.jobs[first] == .completed)
        #expect(fix.service.jobs[second] == .completed)
    }
}

@Suite("TranscriptionService -- queue and a busy or crashed worker")
@MainActor
struct TranscriptionServiceWorkerStateTests {
    @Test("a pass the worker refuses as busy waits and runs once the worker is idle")
    func passRefusedAsBusyRunsOnceTheWorkerIsIdle() async throws {
        // A live session is still loading its model when the pass arrives.
        let fix = try QueueFixture(engine: ScriptedTranscriber(startsBusy: true))
        let meetingID = try await fix.meeting("a")
        let call = fix.transcribe(meetingID)
        try await until { await fix.engine.idleWaitersCount == 1 }

        #expect(fix.service.jobs[meetingID] == .queued(.waitingForTurn))
        #expect(!call.hasReturned)

        await fix.engine.freeWorker()
        try await until { await fix.engine.isRunning("a") }
        await fix.engine.finish("a")
        await call.value()

        #expect(await fix.engine.events == ["busy a", "wait for idle", "pass a", "shutdown"])
        #expect(fix.service.jobs[meetingID] == .completed)
    }

    @Test("a crash while no pass ran resets the worker and the job runs again once")
    func crashBetweenJobsResetsTheWorkerAndRunsAgain() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(holdsPasses: false, startsInterrupted: true))
        let meetingID = try await fix.meeting("a")

        await fix.service.transcribe(meetingID: meetingID)

        #expect(fix.service.jobs[meetingID] == .completed)
        #expect(await fix.engine.events == ["shutdown", "pass a", "shutdown"])
    }

    @Test("a re-transcribe during the meeting's pass runs again after it")
    func reTranscribeDuringItsPassRunsAgainAfterIt() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let meetingID = try await fix.meeting("a")
        let firstCall = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("a") }
        var reTranscribed = false
        let again = Task { @MainActor in
            await fix.service.reTranscribe(meetingID: meetingID)
            reTranscribed = true
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(fix.service.jobs[meetingID] == .transcribing)

        await fix.engine.finish("a")
        try await until { await fix.engine.events == ["pass a", "pass a"] }
        #expect(!reTranscribed)
        #expect(!firstCall.hasReturned)
        try await until { await fix.engine.isRunning("a") }
        await fix.engine.finish("a")
        await again.value
        await firstCall.value()

        #expect(reTranscribed)
        #expect(await fix.engine.events == ["pass a", "pass a", "shutdown"])
        #expect(fix.service.jobs[meetingID] == .completed)
    }

    @Test("a re-transcribe queued during a pass that a recording cancels runs once")
    func reTranscribeDuringACancelledPassRunsOnce() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let meetingID = try await fix.meeting("a")
        let firstCall = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("a") }
        let again = Task { @MainActor in await fix.service.reTranscribe(meetingID: meetingID) }
        try await Task.sleep(for: .milliseconds(20))
        let recording = UUID()

        await fix.service.recordingDidStart(recording, liveTranscription: true)
        try await Task.sleep(for: .milliseconds(20))
        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isRunning("a") }
        await fix.engine.finish("a")
        await again.value
        await firstCall.value()

        #expect(await fix.engine.events == ["pass a", "cancel", "pass a", "shutdown"])
        #expect(fix.service.jobs[meetingID] == .completed)
    }
}

@Suite("TranscriptionService -- model preparation")
@MainActor
struct TranscriptionServicePreparationTests {
    @Test("a preparation runs while the queue is idle, then the worker shuts down")
    func preparationRunsWhenTheQueueIsIdle() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())

        fix.service.prepareModels(["live", "final"])
        try await until { await fix.engine.isPreparing }
        #expect(fix.service.isPreparingModels)
        await fix.engine.finishPreparation(["live", "final"])
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["prepare live,final", "shutdown"])
    }

    @Test("models already prepared for this build are not prepared again")
    func preparedModelsAreNotPreparedAgainForTheSameBuild() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        fix.service.prepareModels(["live", "final"])
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        fix.service.prepareModels(["live", "final"])
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["final"])
        try await until { !fix.service.isPreparingModels }
        fix.service.prepareModels(["live", "final"])
        try await Task.sleep(for: .milliseconds(20))

        #expect(await fix.engine.events == ["prepare live,final", "shutdown", "prepare final", "shutdown"])
    }

    @Test("a preparation waits for the final passes queued before it")
    func preparationWaitsForQueuedPasses() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let meetingID = try await fix.meeting("a")
        let call = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("a") }

        fix.service.prepareModels(["live"])
        try await Task.sleep(for: .milliseconds(20))
        #expect(!fix.service.isPreparingModels)
        await fix.engine.finish("a")
        await call.value()
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["pass a", "prepare live", "shutdown"])
    }

    @Test("a recording cancels the preparation at once; the rest runs after the recording")
    func recordingStartCancelsPreparationAndItResumesAfter() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        fix.service.prepareModels(["live", "final"])
        try await until { await fix.engine.isPreparing }
        await fix.engine.prepareBeforeCancel(["live"])
        let recording = UUID()

        await fix.service.recordingDidStart(recording, liveTranscription: true)
        try await until { !fix.service.isPreparingModels }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await fix.engine.events == ["prepare live,final", "cancel"])

        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["final"])
        try await until { !fix.service.isPreparingModels }
        #expect(await fix.engine.events == ["prepare live,final", "cancel", "prepare final", "shutdown"])
    }

    @Test("a recording shuts down a worker that does not stop preparing in time")
    func unansweredCancelShutsThePreparingWorkerDown() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(cancelReply: .never), cancelTimeout: .milliseconds(50))
        fix.service.prepareModels(["live"])
        try await until { await fix.engine.isPreparing }

        await fix.service.recordingDidStart(UUID(), liveTranscription: true)

        try await until { !fix.service.isPreparingModels }
        #expect(await fix.engine.events == ["prepare live", "cancel", "shutdown"])
    }

    @Test("separate requests run one after the other, each showing only its own models")
    func separateRequestsRunSeparately() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        fix.service.prepareModels(["live"])
        fix.service.prepareModels(["final"])

        try await until { await fix.engine.isPreparing }
        #expect(fix.service.modelsBeingPrepared == ["live"])
        await fix.engine.finishPreparation(["live"])
        try await until { fix.service.modelsBeingPrepared == ["final"] }
        await fix.engine.finishPreparation(["final"])
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["prepare live", "prepare final", "shutdown"])
    }

    @Test("a forgotten model is prepared again")
    func forgottenModelIsPreparedAgain() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        fix.service.prepareModels(["live"])
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        fix.service.forgetPreparedModel("live")
        fix.service.prepareModels(["live"])
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["prepare live", "shutdown", "prepare live", "shutdown"])
    }

    @Test("a recording that starts while the worker resets keeps the preparation from starting until it stops")
    func recordingDuringTheResetHoldsThePreparation() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(holdsShutdowns: true, crashing: ["a"]))
        let meetingID = try await fix.meeting("a")
        // The pass crashes the worker; the preparation queued behind it resets it first.
        let call = fix.transcribe(meetingID)
        fix.service.prepareModels(["live"])
        await call.value()
        try await until { await fix.engine.shutdownsWaiting == 1 }

        let recording = UUID()
        await fix.service.recordingDidStart(recording, liveTranscription: true)
        await fix.engine.releaseShutdowns()
        try await until { !fix.service.isPreparingModels }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await fix.engine.events == ["pass a", "shutdown", "cancel"], "nothing reaches the fresh worker")

        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { await fix.engine.shutdownsWaiting == 1 }
        await fix.engine.releaseShutdowns()
        try await until { !fix.service.isPreparingModels }
        #expect(await fix.engine.events == ["pass a", "shutdown", "cancel", "prepare live", "shutdown"])
    }

    @Test("a final pass queued during a preparation stops it and runs first")
    func passQueuedDuringPreparationCancelsIt() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        let meetingID = try await fix.meeting("a")
        fix.service.prepareModels(["live"])
        try await until { await fix.engine.isPreparing }

        let call = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("a") }
        #expect(fix.service.jobs[meetingID] == .transcribing)
        await fix.engine.finish("a")
        await call.value()
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["prepare live", "cancel", "pass a", "prepare live", "shutdown"])
    }
}

/// Keeps "live" loaded and waits until it is.
@MainActor
private func keepLive(_ fix: QueueFixture) async throws {
    fix.service.keepModelLoaded("live")
    try await until { await fix.engine.isPreparing }
    await fix.engine.finishPreparation(["live"])
    try await until { !fix.service.isPreparingModels }
}

@Suite("TranscriptionService -- live model kept loaded")
@MainActor
struct TranscriptionServiceResidentModelTests {
    @Test("the live model is loaded to keep, and the worker stays up for it")
    func residentModelLoadsAndKeepsTheWorker() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())

        fix.service.keepModelLoaded("live")
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }
        try await Task.sleep(for: .milliseconds(20))

        #expect(await fix.engine.events == ["prepare live keep live"])
    }

    @Test("after a worker shutdown, the live model is loaded again in a fresh worker")
    func residentModelIsLoadedAgainAfterAShutdown() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        fix.service.keepModelLoaded("live")
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        await fix.service.releaseWorkerIfIdle()
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["prepare live keep live", "shutdown", "prepare live keep live"])
    }

    @Test("releasing the live model shuts the idle worker down")
    func releasingTheResidentModelShutsTheWorkerDown() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        fix.service.keepModelLoaded("live")
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        fix.service.keepModelLoaded(nil)
        try await until { await fix.engine.events.last == "shutdown" }
        #expect(await fix.engine.events == ["prepare live keep live", "shutdown"])
    }

    @Test("a recording lets the live model's load in progress finish, for its live session")
    func recordingKeepsTheLiveModelsLoad() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        fix.service.keepModelLoaded("live")
        try await until { await fix.engine.isPreparing }
        let recording = UUID()

        await fix.service.recordingDidStart(recording, liveTranscription: true, keepingPreparationOf: "live")
        #expect(fix.service.isPreparingModels)
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }
        try await Task.sleep(for: .milliseconds(20))

        #expect(await fix.engine.events == ["prepare live keep live"], "no cancel and no shutdown")
        fix.service.recordingDidStop(recording)
    }

    @Test("a recording still cancels the final pass's model's preparation")
    func recordingCancelsTheFinalModelsPreparation() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        fix.service.prepareModels(["final"])
        try await until { await fix.engine.isPreparing }

        await fix.service.recordingDidStart(UUID(), liveTranscription: true, keepingPreparationOf: "live")
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["prepare final", "cancel"])
    }

    @Test("the live model's run goes before runs already queued")
    func liveRunGoesFirst() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        fix.service.prepareModels(["a"])
        try await until { await fix.engine.isPreparing }
        fix.service.prepareModels(["final"])
        fix.service.prepareModels(["live"], first: true)

        for model in ["a", "live", "final"] {
            try await until { fix.service.modelsBeingPrepared == [model] }
            await fix.engine.finishPreparation([model])
        }
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["prepare a", "prepare live", "prepare final", "shutdown"])
    }

    @Test("a model downloaded again while it is being prepared is prepared once more")
    func modelForgottenDuringItsRunIsPreparedAgain() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        fix.service.prepareModels(["live"])
        try await until { await fix.engine.isPreparing }

        fix.service.forgetPreparedModel("live")
        await fix.engine.finishPreparation(["live"])
        try await until { await fix.engine.events == ["prepare live", "prepare live"] }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["prepare live", "prepare live", "shutdown"])
    }

    @Test("after a final pass the kept model stays loaded and the pass's own models are unloaded, the worker staying up")
    func passKeepsTheKeptModelAndUnloadsItsOwn() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        try await keepLive(fix)

        let call = try await fix.transcribe(fix.meeting("one"))
        try await until { await fix.engine.isRunning("one") }
        await fix.engine.finish("one")
        await call.value()
        try await Task.sleep(for: .milliseconds(20))

        #expect(await fix.engine.events == ["prepare live keep live", "pass one", "unload final models"])
    }

    @Test("passes in a row keep their models until the last one; then they are unloaded")
    func passesInARowUnloadOnce() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        try await keepLive(fix)

        let first = try await fix.transcribe(fix.meeting("one"))
        let second = try await fix.transcribe(fix.meeting("two"))
        try await until { await fix.engine.isRunning("one") }
        await fix.engine.finish("one")
        try await until { await fix.engine.isRunning("two") }
        await fix.engine.finish("two")
        await first.value()
        await second.value()
        try await Task.sleep(for: .milliseconds(20))

        #expect(await fix.engine.events == ["prepare live keep live", "pass one", "pass two", "unload final models"])
    }

    @Test("preparing the final pass's model keeps the live model loaded and the worker up")
    func otherPreparationKeepsTheKeptModel() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        try await keepLive(fix)

        fix.service.prepareModels(["final"])
        try await until { fix.service.modelsBeingPrepared == ["final"] }
        await fix.engine.finishPreparation(["final"])
        try await until { !fix.service.isPreparingModels }
        try await Task.sleep(for: .milliseconds(20))

        #expect(await fix.engine.events == ["prepare live keep live", "prepare final"])
    }

    @Test("a worker crash while idle loads the kept model again in a fresh worker")
    func idleCrashReloadsTheKeptModel() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        try await keepLive(fix)
        try await until { await fix.engine.observesInterruptions }

        await fix.engine.crashWhileIdle()
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["prepare live keep live", "shutdown", "prepare live keep live"])
    }

    @Test("a kept model downloaded again is loaded again from its new files")
    func redownloadReloadsTheKeptModel() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        try await keepLive(fix)

        fix.service.forgetPreparedModel("live")
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }
        fix.service.keepModelLoaded("live")
        try await Task.sleep(for: .milliseconds(20))

        #expect(await fix.engine.events == ["prepare live keep live", "prepare live keep live reload"])
    }

    @Test("a kept model the worker was too busy to load is loaded once it is free, not counted as failed")
    func busyWorkerDoesNotFailTheKeptModel() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(startsBusy: true))
        fix.service.keepModelLoaded("live")
        try await until { await fix.engine.idleWaitersCount == 1 }
        await fix.engine.freeWorker()
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["busy prepare", "wait for idle", "shutdown", "prepare live keep live"])
    }

    @Test("a worker crash while loading the kept model is tried again in a fresh worker")
    func crashDuringTheKeptModelsLoadIsRetried() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(startsInterrupted: true))
        fix.service.keepModelLoaded("live")
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["shutdown", "prepare live keep live"])
    }

    @Test("a recording's live session that stops the kept model's load does not count as a failure")
    func recordingStoppingTheKeptModelsLoadIsNotAFailure() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        fix.service.keepModelLoaded("live")
        try await until { await fix.engine.isPreparing }
        let recording = UUID()
        await fix.service.recordingDidStart(recording, liveTranscription: true, keepingPreparationOf: "live")
        // The live service's start cancels it before the model loaded.
        await fix.engine.cancelActiveWork()
        try await until { !fix.service.isPreparingModels }

        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }

        #expect(await fix.engine.events == ["prepare live keep live", "cancel", "prepare live keep live"])
    }

    @Test("a kept model that fails to load does not restart the worker over and over")
    func failedKeptModelStopsTrying() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        fix.service.keepModelLoaded("live")
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation([])
        try await until { !fix.service.isPreparingModels }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await fix.engine.events == ["prepare live keep live", "shutdown"])
    }
}

@Suite("TranscriptionService -- live model kept loaded through crashes and releases")
@MainActor
struct ResidentModelRecoveryTests {
    @Test("a crash reported after the kept model's last failed load does not start its loads again")
    func lateCrashReportAfterThreeFailedLoadsDoesNotRetry() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(crashingPreparations: 3))
        fix.service.keepModelLoaded("live")
        try await until { await fix.engine.events.count == 6 }
        try await until { !fix.service.isPreparingModels }
        try await until { await fix.engine.observesInterruptions }

        // The client reports the last crash after its load's run has ended.
        await fix.engine.crashWhileIdle()
        try await Task.sleep(for: .milliseconds(50))

        let loads = await fix.engine.events.filter { $0.hasPrefix("prepare") }
        #expect(loads.count == 3, "three loads in a row the worker failed during, then none")
    }

    @Test("turning the live transcript off during a recording drops the kept model's queued load")
    func releasingTheKeptModelDropsItsQueuedLoad() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber())
        try await keepLive(fix)
        try await until { await fix.engine.observesInterruptions }
        let recording = UUID()
        await fix.service.recordingDidStart(recording, liveTranscription: true)
        // The worker crashes during the recording: the reload waits for its end.
        await fix.engine.crashWhileIdle()
        try await Task.sleep(for: .milliseconds(20))

        fix.service.keepModelLoaded(nil)
        fix.service.recordingDidStop(recording)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await fix.engine.events == ["prepare live keep live", "shutdown"], "no load of a model nothing keeps")
    }

    @Test("a crash during a final pass with the model kept restarts the worker instead of unloading in place, then loads the model again")
    func crashDuringAPassWithTheModelKeptRestartsAndReloads() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(crashing: ["one"]))
        try await keepLive(fix)
        let meetingID = try await fix.meeting("one")

        await fix.transcribe(meetingID).value()
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }
        try await Task.sleep(for: .milliseconds(20))

        #expect(fix.service.jobs[meetingID] == .failed(message: "Transcription worker stopped unexpectedly. Tap Retry.", retriable: true))
        #expect(await fix.engine.events == ["prepare live keep live", "pass one", "shutdown", "prepare live keep live"])
    }

    @Test("Record during a pass whose load does not stop shuts the worker down; the kept model loads again after the pass")
    func recordDuringAPassThatDoesNotStopShutsTheWorkerDown() async throws {
        let fix = try QueueFixture(engine: ScriptedTranscriber(cancelReply: .never), cancelTimeout: .milliseconds(50))
        try await keepLive(fix)
        let meetingID = try await fix.meeting("one")
        let call = fix.transcribe(meetingID)
        try await until { await fix.engine.isRunning("one") }
        let recording = UUID()

        await fix.service.recordingDidStart(recording, liveTranscription: true)
        #expect(await fix.engine.events == ["prepare live keep live", "pass one", "cancel", "shutdown"])

        fix.service.recordingDidStop(recording)
        try await until { await fix.engine.isRunning("one") }
        await fix.engine.finish("one")
        await call.value()
        try await until { await fix.engine.isPreparing }
        await fix.engine.finishPreparation(["live"])
        try await until { !fix.service.isPreparingModels }
        try await Task.sleep(for: .milliseconds(20))

        #expect(fix.service.jobs[meetingID] == .completed)
        #expect(await fix.engine.events == [
            "prepare live keep live", "pass one", "cancel", "shutdown", "pass one", "prepare live keep live"
        ])
    }
}

---
status: complete
---

# Phase 7: Shared Worker and Job Queue

## Overview

Let a live Whisper session and the final pass share the one `BiscottiTranscriber` worker safely. The worker gets live-session XPC messages and a process-wide `EngineHost` that owns the one final-pass engine and at most one live session, keeps them from overlapping and can stop either and say when it is idle. `Transcriber` gains a live client. `TranscriptionService` replaces "Another transcription is already in progress." with a queue keyed by recording: no final pass runs while a recording runs, and a recording that starts during a pass cancels it and puts it back at the front. AppCore tells the queue when recordings start and stop. Phase 5 chose Whisper (whisper-small, unprompted, two-track, 1 s), so the full Whisper path is built.

`EngineHost` and the exported XPC object move into a new `TranscriberWorker` library target in `Packages/Transcription`, so they are tested with `swift test`; the worker's `main.swift` keeps only the listener. The worker and `Packages/Transcription` change, so the recordable `tx_*` manual-test steps must be `not-run` (they already are).

## Steps

1. **Package** (`Packages/Transcription/Package.swift`):
   - `Transcription` depends on `LiveTranscriptModel` (the XPC messages carry live types).
   - New library target and product `TranscriberWorker` (depends on `Transcription`, `LiveTranscription`, `LiveTranscriptModel`, WhisperKit) and test target `TranscriberWorkerTests`.
   - `App/project.yml` and `ManualTestApp/project.yml`: the `BiscottiTranscriber` target also depends on the `TranscriberWorker` product.

2. **Errors** (`Transcription/TranscriptionError.swift`, new `TranscriptionError+XPC.swift`):
   - New cases `cancelled` (a final pass stopped by `cancelActiveWork`) and `workerBusy` (the worker's exclusion guard).
   - `TranscriptionError: CustomNSError` with a fixed domain, one code per case and the payload in `userInfo`, plus `init?(bridged: NSError)`. Today a worker error reaches the app as an opaque NSError and becomes `transcriptionFailed`; the app must recognize `cancelled`, `workerBusy` and `needsDownload` (live model missing).

3. **XPC protocol** (`TranscriberServiceProtocol.swift`):
   ```swift
   func startLiveSession(configData: Data, reply: @escaping @Sendable (Error?) -> Void)
   func appendLiveAudio(sessionID: String, generation: Int, chunkData: Data, reply: @escaping @Sendable () -> Void)
   func cancelActiveWork(reply: @escaping @Sendable () -> Void)
   func setLiveUpdateInterval(sessionID: String, seconds: Double)
   func setLivePaused(sessionID: String, paused: Bool)
   func finishLiveSession(sessionID: String, timeoutSeconds: Double, reply: @escaping @Sendable (Data?, Error?) -> Void)
   func cancelLiveSession(sessionID: String, reply: @escaping @Sendable () -> Void)
   // TranscriberStatusReporting
   func liveSessionDidUpdate(_ updateData: Data)
   func liveSessionDidEnd(sessionID: String, generation: Int)
   ```
   `liveSessionDidEnd` is not in the component spec: the worker sends it when a session ends without the owner's finish or cancel (a decode failure, or `cancelActiveWork` from another connection), so the client's update stream ends and phase 8 can restart once.

4. **Final-pass cancellation and model sharing** (`InProcessTranscriptionEngine.swift`):
   - The WhisperKit transcription callback returns `false` once the calling task is cancelled; `Task.checkCancellation()` runs before diarization; `CancellationError` becomes `TranscriptionError.cancelled`.
   - `package nonisolated var whisperModelName: String`.
   - `package func loadedWhisperKit() async throws -> LoadedWhisperKit`: loads the final model if needed and returns it in an `@unchecked Sendable` box. `EngineHost` uses it only while no final pass can run (see step 9).
   - `package static func loadLocalWhisperKit(model:) async throws -> LoadedWhisperKit`: loads a model folder from `ModelStorage` (`download: false`, tokenizer from the same `downloadBase`); a missing folder throws `needsDownload`.

5. **Client connection** (`XPCConnection.swift`, `XPCEngineAdapter.swift`, new `LiveUpdateRoute.swift`):
   - `TranscriberXPCConnecting` gains `remoteObjectProxy(errorHandler:)` and `setLiveUpdateRoute(_:)`.
   - `XPCEngineAdapter` uses the error-handler proxy, so an interrupted or invalidated connection resumes a pending call with an error instead of leaving it waiting forever (the 5 s cancel deadline in step 12 relies on this). It maps bridged `TranscriptionError`s first.
   - `LiveUpdateRoute` (Mutex): the current session's ID, generation and stream continuation. `liveSessionDidUpdate` yields a decoded update only when its session ID and generation match; `liveSessionDidEnd` and interruption finish the stream.

6. **`Transcriber` live client** (new `Transcriber+Live.swift`):
   ```swift
   public func startLiveSession(_ config: LiveSessionConfig) async throws -> AsyncStream<LiveTrackUpdate>
   @discardableResult public func appendLiveAudio(_ chunk: LiveAudioChunk) throws -> Bool  // false: 8 chunks of its track in transit, or no session
   public func setLiveUpdateInterval(_ seconds: TimeInterval)
   public func setLivePaused(_ paused: Bool)
   public func finishLiveSession(timeout: Duration) async throws -> [LiveTrackUpdate]
   public func cancelLiveSession() async
   public func cancelActiveWork() async   // returns when the worker replies idle; no-op without a connection
   ```
   - The component spec has a `liveUpdates` property. The update stream is returned by `startLiveSession` instead and ends with its session, as `LiveTranscriptionSession.updates` does, so a restart gets a fresh stream.
   - At most 8 unacknowledged chunks per track (`LiveChunkWindow`, Mutex); an acknowledgement or a send error frees a slot.
   - An interruption ends the session's stream; the next live call throws `workerInterrupted`. The `.inProcess` backend has no worker and throws `workerUnavailable`.

7. **Live decoder** (`LiveTranscription/WhisperKitLiveDecoder.swift`): `public func unloadModels() async`, for a live model loaded apart from the final pass.

8. **Worker seams** (`TranscriberWorker/`):
   - `HostedTranscriptionEngine: TranscriptionEngine` adds `whisperModel` and `sharedLiveDecoder()`; `InProcessTranscriptionEngine` conforms (a `WhisperKitLiveDecoder` on the engine's loaded model).
   - `LiveModelLoading.load(model:) -> LoadedLiveModel` (`decoder`, `unload`); `LocalWhisperModelLoader` is the real one.
   - `LiveSessionOwner` (Sendable): `deliver(_ update:)`, `sessionDidEnd(sessionID:generation:)`; the exported object implements it over the reverse proxy.
   - `TrackedLiveDecoder` (actor): forwards decodes and lets the host wait until none is in flight. A cancelled `WhisperLiveSession` returns before its last decode does; nothing may unload the model or start new work until that decode returns.

9. **`EngineHost`** (actor, `EngineHost.shared` per process):
   - `Activity`: `.idle`, `.finalPass(task)`, `.live(HostedLiveSession)`, `.endingLive(task)`.
   - `processAudio` runs in a task the host keeps. During `.live` or `.finalPass` it throws `workerBusy`; during `.endingLive` it waits for the end, then runs.
   - `startLiveSession(config, owner)`: validates storage once; `workerBusy` during `.finalPass` or `.live`; waits out `.endingLive`. Same model as the final pass: `sharedLiveDecoder()`. Different model: unload the final engine's models, then `LiveModelLoading.load`, so two Whisper models are never loaded together. Creates `WhisperLiveSession(decoder: TrackedLiveDecoder(...))` (its scheduler runs at `.userInitiated`) and a task that forwards `session.updates` to a `LiveUpdateRelay`.
   - `append`, `setUpdateInterval`, `setPaused` apply only to the matching session and generation.
   - `finishLiveSession`: `session.finish(timeout:)`, flush the relay, end the session (step below), then return the final updates, so the reply means the host is idle.
   - Ending a live session (finish, cancel, failure, owner gone): cancel the session if needed, stop the forwarder, wait for `TrackedLiveDecoder` to be idle, unload a separately loaded model, log footprint and wired memory, become `.idle`. An end the owner did not ask for calls `owner.sessionDidEnd`.
   - `cancelActiveWork()`: cancels a final-pass task (WhisperKit stops at its callback; diarization never starts) or ends the live session, waits for the work to return and replies when `.idle`.
   - `ownerDidDisconnect(_:)`: ends a live session owned by a closed connection.
   - `LiveUpdateRelay` (actor): merges pending updates per track with `LiveTrackUpdate.merge` (rows by ID, gaps accumulate) and sends at most one per track every 250 ms; `flush()` sends what is pending.
   - `WorkerMemory`: physical footprint (`TASK_VM_INFO`) and system wired memory (`HOST_VM_INFO64`), logged at `.notice` after a live model loads and after it unloads, for phase 11's memory check.

10. **Exported object** (`TranscriberWorker/TranscriberService.swift`, from `main.swift`):
    - Delegates to `EngineHost`. Live messages run through a `SerialInbox` (one consumer task at `.userInitiated`), because NSXPC delivers them in order but a `Task` per message would not keep that order. `processAudio`, `ensureModelsDownloaded`, `unloadModels`, `cancelActiveWork` and `healthCheck` run as today.
    - `connectionDidClose()`: finishes the inbox and calls `EngineHost.ownerDidDisconnect`.
    - `main.swift` keeps the connection counter, the listener delegate (now calling `connectionDidClose` from the invalidation handler) and the entry point.

11. **`TranscriptionService` job status** (`JobStatus.swift`, `Transcribing.swift`):
    - `case queued(QueueReason)`; `public enum QueueReason: Equatable, Sendable { case waitingForRecording, waitingForTurn }`.
    - `Transcribing.cancelActiveWork() async`, implemented by `LiveTranscriberAdapter`, `PreviewTranscriber` and `FakeTranscriber`.

12. **Queue** (`TranscriptionService.swift`, new `TranscriptionService+Queue.swift`):
    - State: `queue: [UUID]`, `running: UUID?`, `activeRecordingID: UUID?`, `cancelledForRecording`, waiters per meeting, one runner task.
    - `transcribe` / `reTranscribe`: enqueue unless queued or running, set `.queued(.waitingForRecording)` or `.queued(.waitingForTurn)`, start the runner, wait for the meeting's job to end.
    - Runner: while no recording runs, take the head and run `executeJob`. `executeJob` checks `cancelledForRecording` before `processAudio`; a pass that throws after the flag is set goes back to the front as `.queued(.waitingForRecording)` with no failure. After a job: shut the worker down only if the queue is empty and no recording runs, then clear `running`, then resume the meeting's waiters.
    - `recordingDidStart(id) async`: set the active recording, mark queued meetings waiting for the recording; if a pass runs, set the flag and await `engine.cancelActiveWork()` under a 5 s deadline (`init(..., cancelTimeout:)`); on no reply, `engine.shutdown()`.
    - `recordingDidStop(id)`: ignored unless `id` is the active recording; then queued meetings wait for their turn and the runner starts.
    - `mapEngineError`: `cancelled` and `workerBusy` are retriable.

13. **AppCore** (`AppCore.swift`):
    - `completeRecordingStartup`: after the recording starts and `runState` is set, `await transcription.recordingDidStart(meetingID)`.
    - `stopRecording`'s task: `transcription.recordingDidStop(meetingID)` before `transcribe`. `tearDownPartialRecording` calls `recordingDidStop` for the recording it stops.

14. **MeetingDetailUI** (`MeetingDetailViewModel.swift`, `LiveDraftSource.swift`):
    - `LiveDraftSource` loses `isWaitingForRecording` (phase 9's follow-up). The display switch maps `.queued(.waitingForRecording)` to `.waitingForRecording` and `.queued(.waitingForTurn)` to `.processing(message: "Waiting to transcribe…")`; a draft's status comes from the same job status.
    - `canReTranscribe` is false and the pipeline's "Transcribing" stage is active while queued.

15. **Docs**:
    - `components/live_session.md`, `promptTokens` row, and `architecture.md`, "Vocabulary" line: live Whisper decodes unprompted (`WhisperKitLiveDecoder.defaultPrompt`), so no vocabulary reaches live text.
    - `specs/research/live_transcription/README.md` follow-ups: the worker never keeps both models loaded (per `components/transcriber_worker.md`); it logs footprint and wired memory at live model load and unload for phase 11.

16. **Manual tests**: confirm every recordable `tx_*` step in `ManualTestApp/Results/manual_test_results.json` is `not-run`.

## Tests

`TranscriptionServiceQueueTests` (`BiscottiKit`, a scriptable fake `Transcribing`):
- `secondJobQueuesInsteadOfFailing`: a second meeting shows `.queued(.waitingForTurn)` while the first runs, then completes.
- `transcribeReturnsWhenItsJobCompletes`: `transcribe` returns after its own job, not the one ahead of it.
- `duplicateRequestWaitsOnTheSameJob`: a second request for a running meeting runs no second pass and returns with the first.
- `noFinalPassStartsDuringARecording`: a request during a recording does not reach the engine until the recording stops.
- `recordingStartCancelsAndRequeuesTheRunningPassAtTheFront`: the running pass is cancelled and runs again first, before a meeting queued earlier.
- `cancelledPassIsNotReportedAsFailed`: the cancelled meeting never shows `.failed`.
- `queueRunsInOrderAfterRecordingStops`: queued meetings run first in, first out.
- `failedJobDoesNotBlockTheQueue`: a failure is reported and the next meeting runs.
- `workerShutsDownOnlyWhenIdle`: no shutdown between queued jobs or while a recording runs; one when the queue empties.
- `queuedStatusShowsWaitingForRecording`: queued meetings switch between the two reasons as a recording starts and stops.
- `stopFromEarlierRecordingDoesNotEndTheActiveRecording`: a stop with an old ID leaves the queue held.
- `admissionWaitsForWorkerIdleAcknowledgement`: `recordingDidStart` returns only after `cancelActiveWork` returns.
- `unansweredCancelShutsTheWorkerDown`: no reply within the deadline shuts the worker down, and the pass is requeued.
- `requestDuringShutdownRunsAfterIt`: a request made while the worker shuts down runs next and the worker is shut down again after it (replaces the in-flight guard's re-entrancy test).

`EngineHostTests` (`TranscriberWorkerTests`; fake engine, fake model loader, real `WhisperLiveSession` with a fake decoder or a fake session):
- `rejectsFinalPassWhileLive`, `rejectsLiveWhileFinalPass`
- `cancelStopsTheFinalPassAndRepliesWhenIdle`
- `cancelEndsTheLiveSessionAfterItsDecodeReturns`
- `pendingUpdatesAreMergedNotDropped`
- `validatesStorageOncePerLiveSession`
- `sharesLoadedWhisperWhenModelsMatch`
- `unloadsSeparateLiveModelBeforeFinalPass`: the order is final models unloaded, live model loaded, live model unloaded, final pass.
- `finishRepliesWhenTheHostIsIdle`
- `failedSessionTellsItsOwner`
- `closedConnectionEndsItsLiveSession`
- `chunksForAnotherGenerationAreIgnored`

`LiveUpdateRelayTests`: `sendsAtMostOneUpdatePerTrackEveryQuarterSecond`, `flushSendsPendingUpdates`.

`SerialInboxTests`: `runsWorkInArrivalOrder`.

`TranscriberLiveClientTests` (`TranscriptionTests`, mock connection and service):
- `updatesFromOldGenerationAreDropped`
- `interruptionSurfacesOnNextLiveCall`
- `atMostEightChunksInTransitPerTrack`
- `workerEndedSessionEndsTheStream`
- `finishReturnsFinalUpdatesAndEndsTheStream`

`TranscriptionErrorBridgingTests`: `everyCaseRoundTripsThroughNSError`, `foreignErrorsAreNotBridged`.

`XPCEngineAdapter` round-trip tests: `bridgedWorkerErrorKeepsItsCase`, `connectionErrorResumesPendingCall`.

`MeetingDetailDraftTests` (updated): the waiting tests set `jobs[id] = .queued(.waitingForRecording)`; new `queuedForTurnShowsWaitingToTranscribe`.

`AppCore` (`RecordingCoordinationTests` or the existing recording suite): `finalPassWaitsWhileRecording`: a meeting transcribed during a recording stays `.queued(.waitingForRecording)` until stop, then completes.

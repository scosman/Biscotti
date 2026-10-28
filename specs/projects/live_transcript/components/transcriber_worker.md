---
status: complete
---

# Component: Transcriber Worker and Job Queue

## Purpose and scope

Let the live session and the final pass share the existing `BiscottiTranscriber` XPC worker safely:

- XPC messages for live sessions.
- One engine per worker process, so Whisper stays warm from the live transcript into the final pass.
- A queue in `TranscriptionService` with live-first admission, replacing the "Another transcription is already in progress." failure.

Not in scope: the session logic itself ([live_session](live_session.md)).

## XPC protocol additions (`Transcription` target)

```swift
@objc public protocol TranscriberServiceProtocol {
    // existing: processAudio, ensureModelsDownloaded, unloadModels, healthCheck

    func startLiveSession(configData: Data, reply: @escaping @Sendable (Error?) -> Void)
    func appendLiveAudio(sessionID: String, generation: Int, chunkData: Data,
                         reply: @escaping @Sendable () -> Void)                         // reply = chunk accepted
    func cancelActiveWork(reply: @escaping @Sendable () -> Void)                         // reply = engine idle
    func setLiveUpdateInterval(sessionID: String, seconds: Double)                       // one-way
    func setLivePaused(sessionID: String, paused: Bool)                                  // one-way
    func finishLiveSession(sessionID: String, timeoutSeconds: Double,
                           reply: @escaping @Sendable (Data?, Error?) -> Void)           // JSON [LiveTrackUpdate]
    func cancelLiveSession(sessionID: String, reply: @escaping @Sendable () -> Void)
}

@objc public protocol TranscriberStatusReporting {
    // existing: reportDownloadStatus
    func liveSessionDidUpdate(_ updateData: Data)                                        // JSON LiveTrackUpdate
}
```

- Messages keep their order on one `NSXPCConnection`, so chunks arrive in order.
- Chunks use the binary codec from `LiveAudioChunk`; about 32 KB per second per track. The client keeps at most 8 unacknowledged chunks per track in transit; see the bounded-buffering table in the architecture.
- Pending updates for a track are merged before sending (rows keep their latest version by ID; gaps accumulate), at most 4 per second per track. Nothing is dropped.

`Transcriber` (client actor) gains `startLiveSession(_:)`, `appendLiveAudio(_:)`, `setLiveUpdateInterval(_:)`, `setLivePaused(_:)`, `finishLiveSession(timeout:)`, `cancelLiveSession()` and `liveUpdates: AsyncStream<LiveTrackUpdate>`. The exported status receiver forwards `liveSessionDidUpdate` into that stream, dropping updates whose session ID or generation does not match the current session.

## Worker changes (`XPCServices/BiscottiTranscriber`)

- **`EngineHost`**, a process-wide actor, owns the one `InProcessTranscriptionEngine` and the optional `WhisperLiveSession`. Each connection's `TranscriberService` delegates to it, replacing the per-connection engine.
- **Exclusion:** `EngineHost` tracks `.idle`, `.finalPass` or `.live`. `processAudio` during `.live`, and `startLiveSession` during `.finalPass`, fail with `TranscriptionError.workerBusy`. The app's queue prevents this; the check is a guard.
- **Shared model:** `WhisperLiveSession` uses the engine's loaded `WhisperKit` when the live model matches the final model. When it differs, `EngineHost` loads the live model separately and unloads it when the session finishes, before any final pass, so two large models are never loaded together on an 8 GiB Mac.
- **Paths:** a final pass reads the audio paths it is given, as before. Live appends carry samples, not paths.
- **Lifetime:** unchanged. The worker exits when its last connection closes; the live service keeps its connection open for the whole session.
- **Decode priority:** the live session's decode task runs at `.userInitiated`.
- **`cancelActiveWork`:** stops a running final pass (the WhisperKit transcription callback returns `false`, and a cancellation flag is checked before diarization starts) or cancels the live session, then replies once `EngineHost` is idle. The final pass returns `TranscriptionError.cancelled`.

## Job queue (`TranscriptionService`)

```swift
public enum JobStatus: Equatable, Sendable {
    case idle, downloadingModel(message: String), transcribing, completed
    case failed(message: String, retriable: Bool)
    case queued(QueueReason)                      // new
}
public enum QueueReason: Equatable, Sendable { case waitingForRecording, waitingForTurn }

extension TranscriptionService {
    public func transcribe(meetingID: UUID) async      // enqueues; returns when the job ends
    public func reTranscribe(meetingID: UUID) async    // same
    public func recordingDidStart(_ recordingID: UUID) async   // cancels and requeues a running pass; returns when the worker is idle
    public func recordingDidStop(_ recordingID: UUID)          // ignored unless it matches the active recording; then runs the queue
}
```

State: `queue: [UUID]` (first in, first out), `running: UUID?`, `activeRecordingID: UUID?`, and waiters per meeting ID.

- **Enqueue:** a meeting already queued or running is not added twice; the call just waits. The status is `.queued(.waitingForRecording)` while a recording runs, otherwise `.queued(.waitingForTurn)` until it starts.
- **Run next:** when not recording, nothing is running and the queue is not empty, take the head and run today's `executeJob`.
- **Recording starts while a pass runs:** set `cancelledForRecording` and await `engine.cancelActiveWork()`, which returns only when the worker reports it is idle. The in-flight `processAudio` throws `cancelled`; `executeJob` sees the flag, puts the meeting back at the front of the queue with `.queued(.waitingForRecording)`, and does not report a failure. `recordingDidStart` returns after the acknowledgement, so the live session never meets a running final pass. A worker that does not reply within 5 seconds is shut down and the next call starts a fresh one.
- **After a job:** shut the worker down only if the queue is empty and no recording is running.
- **Waiters** resume when their meeting's job completes or fails.

## AppCore wiring

- `startRecording`: start capture first, then `await transcription.recordingDidStart(meetingID)`, then start the live session if enabled (which cancels any earlier session still finishing). Capture never waits on transcription; the live pump buffers its first seconds.
- `stopRecording`: stop capture; `liveTranscription.stop(meetingID)` publishes the draft at once and returns its finishing task. Then, in a task: await that finishing task (at most 10 s), `transcription.recordingDidStop(meetingID)`, `await transcription.transcribe(meetingID)`, then `intelligence.runAutoEnhancements(meetingID)`, as today. If another recording has started meanwhile, `recordingDidStop` is ignored and the pass waits in the queue.
- This holds whether or not live transcription is on, per the functional spec: no final pass runs while a recording is in progress.

## Model preparation

Added in UI review on 25 October 2026. The first live start of a new build waited 1 min 51 s while macOS compiled whisper-small for the Neural Engine. Biscotti now loads the models once in the background, while nothing records, so that compile happens before the first meeting.

- **XPC:** `prepareModels(requestData:reply:)` takes JSON `[String]` of Whisper model folder names and replies with JSON `[String]`, the models prepared. `Transcriber.prepareModels(_:)` sends it from the client actor, so a later `cancelActiveWork` reaches the worker after it.
- **Worker:** `EngineHost` admits it like a final pass, only while idle (`.preparing`), through the admission inbox. It unloads the final pass's models, then for each model in order: stops if cancelled, skips one not on disk (`WhisperModelFiles.isPresent`, model and tokenizer, so nothing downloads), loads it through the live model loader and unloads it at once, and logs how long it took. `cancelActiveWork` and a closed connection stop it after the load in progress; a final pass or a live start meanwhile gets `workerBusy`.
- **Queue:** `TranscriptionService.prepareModels(_:)` queues the models not yet prepared for this build as one run, after the runs already queued. The runner runs final passes first and a preparation only when no recording runs and no pass waits. A recording or a pass that arrives while the worker resets before a run keeps the run from starting. `recordingDidStart` stops it like a running pass (`cancelActiveWork` within 5 s, otherwise the worker is shut down), and a pass queued during it stops it the same way. The models it prepared are recorded; after a stop, the rest goes back to the front and runs once the queue is free again. `modelsBeingPrepared` drives the Settings caption, which shows only while the live model's run does. A model downloaded again is forgotten first (`forgetPreparedModel`), so it is prepared again.
- **Once per update:** `PreparedModels` keeps, in `UserDefaults`, the models prepared for one build identity: the app's version and build number, the modification times of its executable and its XPC services' executables, and the macOS version. A new install, an update, a development rebuild or a macOS update starts empty.
- **When:** AppCore queues the live model in a run of its own (when live transcription is on and its model is on disk), then the final pass's Whisper model (when the final pass's models are on disk), at launch after onboarding, after onboarding completes, when the live transcript is turned on, and when the live model's download finishes.
- **Changed in the second UI review (25 October 2026):**
  - The XPC payload is a JSON `ModelPreparationRequest { models, keepLoaded }`; the reply is unchanged. `Transcriber.prepareModels(_:keepLoaded:)` sends it.
  - `prepareModels(_:first:)` puts the live model's run at the front of the queue, so it never waits behind the final pass's model.
  - `recordingDidStart(_:liveTranscription:keepingPreparationOf:)`: a recording that starts while the live model's own run is being prepared does not cancel it. The live session's start waits for that load (its `workerBusy` retry calls `cancelActiveWork`, which returns once the load ends). A run of the final pass's model is still cancelled.
  - A model forgotten (downloaded again) while it is queued stays queued; while it is being prepared, it is prepared again after that run (`preparedAgainAfterRun`).

## Keeping the live model loaded

Chosen by the user in the second UI review (25 October 2026), as the fallback for a compile cache that does not last.

**Why the compile came back.** Every live start in the user's meetings recompiled whisper-small for the Neural Engine: the drawer waited 2 min 0 s and 1 min 44 s, after a background preparation that took 100 s. A probe outside the app, loading the same three Core ML models with WhisperKit's compute units, showed that the cache itself works across processes: 112.7 s cold, then 0.32 s in a new process, whatever the exit mode, unloads or signing. The cache (`~/Library/Caches/<identity>/com.apple.e5rt.e5bundlecache/<OS build>/…`) is purgeable data, and macOS's CacheDelete purges it when the disk runs low: the startup disk had 7.1 GB free against a purge goal of about 14.8 GB, and each compile writes temporary weight copies of 176–420 MB, so the next low-disk check purges again. No public API moves the cache or marks it as not purgeable. Freeing disk space fixes it for the user; the app cannot ([research](../../../research/live_transcription/README.md)).

**One rule (chosen by the user on 25 October 2026).** While the live transcript is on, on a Mac with more than 8 GiB, whisper-small stays loaded in the worker at all times, also during a final pass. The final pass's models (large-v3 and SpeakerKit) load for a pass or a preparation and are unloaded after it. The two may be loaded together; about 0.3 GB on top of large-v3 is accepted. This replaces the round-two rule that the worker never holds both.

**What the worker does.** `EngineHost` keeps one `ResidentModel` (name and loaded model):
- A preparation request with `keepLoaded` loads each model in order and keeps `keepLoaded`; the others are unloaded after loading, the resident model staying. A model already resident counts as prepared, unless the request sets `reloadsKeptModel` (its files were downloaded again).
- A live session for the same model uses it with no load (the start logs "Live session started on the model kept loaded"). It first unloads the final pass's models, which a pass just cancelled for this recording may have left (the round-one guard). A session for another model releases it first.
- A final pass runs with it loaded and leaves it loaded. While a pass loads a model, the worker reports the load's start and end to the client (`TranscriberStatusReporting.reportModelLoading`).

**What the app does.** `TranscriptionService.keepModelLoaded(_:)` names the resident model. While no recording runs and nothing else waits, the queue runner loads it (`loadResidentModelIfNeeded`), at the front of the preparation queue, and the worker is not shut down while it holds it.
- After the last final pass, with the resident model loaded, the queue unloads the pass's models (`Transcribing.unloadFinalPassModels`) and the worker stays up. Without a model kept loaded (8 GiB Macs), or after a worker failure, the worker shuts down after a pass as before. A preparation of another model leaves the resident model loaded.
- A worker crash while idle or during a recording is reported by the client's interruption handler (`Transcribing.observeWorkerInterruptions`); the model loads again in a fresh worker once no recording runs.
- A model downloaded again is loaded again from its new files (`reloadsKeptModel`).
- A load counts as failed only when the worker answered without the model (missing or broken), or failed during it three times in a row (`residentLoadAttempts`); a failed load is not retried until something else restarts the worker, so a broken model does not restart it over and over. A load that a recording's live session stopped, or that found the worker busy, is not a failure: the model loads once the queue is free (after a busy refusal, once the worker is idle).
- `Transcribing.prepareModels(_:keepLoaded:reloadingKept:)` is the protocol's only preparation requirement, so no conformer can ignore a reload.
- AppCore keeps the live model loaded when live transcription can start and the Mac has more than 8 GiB (`keepsLiveModelLoaded(physicalMemory:)`, with `AppCore.physicalMemory`, which tests set); otherwise it prepares it at launch and loads it at Record, as before. It loads at every launch: a warm load takes about 0.3 s, and a load after a purge repairs the cache before the next meeting.
- Record while the live model loads takes that load over; Record during a pass cancels the pass, and the live session starts on the kept model with no load.
- **Exception (phase 11, 25 October 2026):** Record during a pass that is still loading its model. A Core ML load cannot be stopped, so the worker does not answer the cancel within 5 s and is shut down, and the kept model goes with it. The live session then loads whisper-small in a fresh worker: about 0.3 s from the compiled cache, or about 2 minutes if macOS purged that too. Backfill covers the wait, and the pass, requeued, loads its model again after the recording. Waiting for the load instead would hold the live start for as long as the compile runs (about 4 minutes for large-v3 after a purge), so the trade-off stays.
- Turning the live transcript off (`keepModelLoaded(nil)`) also drops a queued load of the kept model, for example one queued by a crash during the recording, so no compile runs for a model nothing keeps (phase 11).
- A crash report that arrives after the kept model's third failed load leaves it failed (phase 11): the report can come after that load's run has ended.

**Memory.** The worker's footprint is 0.07 GB with whisper-small loaded and 0.04 GB without it; the system's wired memory fell 0.27 GB when the model unloaded and rose 0.13 GB at the next load. So the resident model costs about 0.2–0.3 GB while the live transcript is on.

**Unloading in place.** A probe outside the app (25 October 2026, warm caches) loaded whisper-small, then large-v3 and SpeakerKit's four models, released them while the process lived on, and repeated that three times:

| Step | Footprint | System wired |
|---|---|---|
| Baseline | 0.001 GB | 4.58 GB |
| whisper-small loaded | 0.019 GB | 5.14 GB |
| Pass 1: large-v3 and SpeakerKit loaded | 0.289 GB | 6.16 GB |
| Pass 1: 13 s after unloading them | 0.289 GB | 4.70 GB |
| Pass 2: loaded / 13 s after unloading | 0.290 GB / 0.290 GB | 5.66 GB / 4.68 GB |
| Pass 3: loaded / 13 s after unloading | 0.292 GB / 0.292 GB | 5.66 GB / 4.70 GB |

The wired memory the final pass's models take (about 1 to 1.5 GB) comes back within 13 s of the unload. About 0.27 GB of footprint stays in the process after the first load and does not grow with later passes. So the worker unloads in place instead of restarting.

**Slow loads on a low disk.** See [Low disk space](#low-disk-space).

**Final pass.** large-v3 recompiles on each final pass for the same reason: 247 s cold in the probe (the audio encoder takes about 3.5 min, the text decoder about 8.5 s) against 1.05 s warm. Keeping large-v3 loaded is not an option: it is far larger. The cost stays until the disk has room; the app now says so (below).

## A decode that never returns

Added in the review of 26 October 2026. A live session that ends (finish, cancel or a closed connection) waits for its last decode before its model is unloaded or other work starts, because two calls must never use one WhisperKit at once, and a model must not be unloaded under a decode. A decode stuck in Core ML would hold that wait for good: the session's finish never replies, a language change never resumes, and a final pass waits behind it while the queue's connection (the kept model's) keeps the process alive.

- **Worker:** `EngineHost` waits at most `LiveWorkerLimits.stuckDecode` (10 s, shared with the app) for the last decode. One still out then is stuck: the worker process ends (`onStuckDecode`; the worker's `main` passes `_exit(70)` to `EngineHost.workerProcessHost`, so an in-process host is never ended), every connection is interrupted, and the next call starts a fresh worker. Nothing is unloaded under the decode.
- **App:** a language change waits for the old engine's finish for its timeout plus the worker's stuck limit plus a margin: a slow last decode only delays the switch, and a stuck one ends the worker, which ends the finish. Only a worker that never replies is given up on, by closing both connections (see [live_transcription_service](live_transcription_service.md#lifecycle)). A Stop during such a change, or during that reset, returns `.languageSwitchUnfinished`, and AppCore releases the queue's worker before the final pass, as after `.timedOut`.

## Loading without downloading

Added in the review of 26 October 2026, for offline reliability: models download when the user asks or onboarding does, never in the middle of a recording's start. `download: false` stops WhisperKit from downloading the model, but not its tokenizer fallback: when the local tokenizer fails to load, WhisperKit fetches one from the Hub, which fails offline and takes the live start with it.

- `WhisperModelFiles.isPresent` asks for both tokenizer files (`tokenizer.json` and `tokenizer_config.json`), as WhisperKit's local load does.
- `InProcessTranscriptionEngine.loadLocalWhisperKit` loads the tokenizer from the cache first (`tokenizerLoadsLocally`; the shape is checked before the tokenizer library, which stops the process on some malformed files). If it does not load, the loader throws `needsDownload`: the live start shows the model as needed, and the download repairs it.
- A tokenizer that loaded is recorded beside its files (`.biscotti-tokenizer-verified`: the build that checked it, then each file's size and modification date), so later loads skip the check until the files or the build change. A new build checks once more, so a newer WhisperKit or tokenizer library never trusts a record an older one wrote. Building whisper-small's tokenizer takes 0.85–1.1 s in a Debug build, and WhisperKit builds it again; the shape check alone takes about 65 ms.
- `WhisperModelFiles.download` removes tokenizer files that do not load (`config.json` and the record included) before fetching them, and checks that the new ones load.

## Low disk space

Chosen by the user on 25 October 2026: when a load is slow because the disk is low, say so.

- **Rule** (`SlowModelLoad`, `DiskSpace` in `TranscriptionService`): the disk is blamed only when a model load ran longer than `compileThreshold` (15 s; loads from the compiled cache took 0.32 s and 1.05 s, compiles about 113 s and 247 s) and the volume of `~/Library/Caches` has less than `DiskSpace.lowThreshold` (20 GB) available for important use. The purge goal measured on this Mac was about 14.8 GB. The free-space reading and the threshold are injected, so tests set both.
- **Reading the disk:** `TranscriptionService.refreshDiskSpace()` reads it and sets `isLowOnDiskSpace`, when Settings opens, when a live start has been slow for 10 s, and when a final pass's load passes the threshold. Nothing polls it. The query can block, so it runs off the main actor (phase 11). `volumeAvailableCapacityForImportantUsage` includes purgeable space, the compiled models among it: a disk with much purgeable data reads as roomy while macOS purges it, and no low-disk message shows then.
- **Final pass:** the worker reports a pass's model loads; the client hands them to `Transcribing.observeModelLoads`. A load that still runs after the threshold on a low disk sets `slowModelLoadOnLowDisk` to the meeting until the load or the pass ends, and its status reads "Transcribing… / Taking longer: your Mac is low on disk space" (or under "Draft · final transcript in progress").
- **Live start:** see [live_drawer](live_drawer.md).
- **Settings:** a warning row under the live transcript toggle while `isLowOnDiskSpace`.

**Hugging Face requests.** The HTTPS requests to Hugging Face before a load come from the final pass's `ensureModelsDownloaded` (`WhisperKit(download: true)` checks the Hub snapshot). They are not live-transcript code, so they are unchanged.

## Dependencies

- Depends on: `LiveTranscriptModel` (types), `LiveTranscription` (the Whisper session, in the worker), `Transcription` (engine, client).
- Used by: `LiveTranscriptionService` (the `Transcriber` live calls), `AppCore`, `MeetingDetailUI` (the new `.queued` status).

## Test plan

Model preparation (UI review): `EngineHostPreparationTests`, `TranscriptionServicePreparationTests`, `PreparedModelsTests`, `AppCorePreparationTests`, and `prepareModelsRoundTrips` in `TranscriberLiveClientTests`.

Resident model (second UI review): `keptModelServesLiveSessions`, `residentModelIsReplacedByAnotherLiveModel`, `finalPassKeepsTheKeptModel`, `recordDuringAPassStartsOnTheKeptModel`, `preparationKeepsTheKeptModel` and `finalPassReportsModelLoads` in `EngineHostTests`; `TranscriptionServiceResidentModelTests` (the resident loads and keeps the worker, reloads after a shutdown, release shuts down, a recording keeps the live load and cancels the final model's, the live run goes first, a model forgotten during its run is prepared again, a pass keeps the model and unloads its own, passes in a row unload once, another model's preparation keeps it, an idle crash reloads it, a re-download reloads it, a failed load is not retried, a busy worker or a recording's live session does not fail it, a crash during its load is retried); `AppCorePreparationTests` (both memory branches, at launch and after a second download); `preparationRequestDefaultsToNoReload` and `modelLoadsReachTheObserver` in `TranscriberLiveClientTests`. Low disk space: `TranscriptionServiceDiskSpaceTests`, `displayStateSaysWhenTheDiskSlowsTheLoad` (MeetingDetailUI), `lowDiskWarningShowsWhileTheDiskIsLow` (SettingsUI), `slowStartMessagesFollowTheDisk` (RecordingUI).

`TranscriptionServiceQueueTests` (fake `Transcribing`):
- `secondJobQueuesInsteadOfFailing`
- `transcribeReturnsWhenItsJobCompletes`
- `duplicateRequestWaitsOnTheSameJob`
- `noFinalPassStartsDuringARecording`
- `recordingStartCancelsAndRequeuesTheRunningPassAtTheFront`
- `cancelledPassIsNotReportedAsFailed`
- `queueRunsInOrderAfterRecordingStops`
- `failedJobDoesNotBlockTheQueue`
- `workerShutsDownOnlyWhenIdle`
- `queuedStatusShowsWaitingForRecording`
- `stopFromEarlierRecordingDoesNotEndTheActiveRecording`
- `admissionWaitsForWorkerIdleAcknowledgement`
- `unansweredCancelShutsTheWorkerDown`

`EngineHostTests` (worker target, fake engine):
- `rejectsFinalPassWhileLive`, `rejectsLiveWhileFinalPass`
- `cancelStopsTheFinalPassAndRepliesWhenIdle`
- `pendingUpdatesAreMergedNotDropped`
- `sharesLoadedWhisperWhenModelsMatch`
- `unloadsSeparateLiveModelBeforeFinalPass`

`TranscriberLiveClientTests`: `updatesFromOldGenerationAreDropped`, `interruptionSurfacesOnNextLiveCall`, `atMostEightChunksInTransitPerTrack`.

Changing the transcriber worker or `Packages/Transcription` marks the `tx_*` manual tests not-run.

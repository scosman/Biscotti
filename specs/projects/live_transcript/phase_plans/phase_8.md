---
status: complete
---

# Phase 8: Live Transcription Service

## Overview

Build the app-side coordinator from [live_transcription_service](../components/live_transcription_service.md) on the engine phase 5 chose (whisper-small, two-track, 1 s, unprompted) and the worker phase 7 built, and wire it into AppCore, so a recording with live transcription on gets a live transcript, a draft after Stop and snapshots. The service drains the recorder's live tap on a pump queue, resamples to 16 kHz chunks, runs one worker session per recording through its own `Transcriber`, keeps the store, drafts and status, and applies the power policy. The setting, the `openai_whisper-small` download and the Transcript tab's draft source come with it.

The phase also takes the follow-ups that earlier phases left for it (phase 1 snapshot, phase 2 duplicate gaps, phase 6 tap handling, phase 7 queue order and worker lifetime, phase 9 draft source). The drawer, Settings toggle and menu command stay in phase 10.

Starting a live session can take minutes the first time a build loads the model (Neural Engine compile). No start has a timeout; Stop during a start cancels it at once instead of waiting.

Review round 2 replaced the pump's `hold()`/`resume()` (step 6) with a 45 s per-track backlog in the pump: refused chunks wait and are offered again.

## Steps

1. **DataStore** (`Models/AppSettings.swift`, `DataStore+ReadModels.swift`):
   - `AppSettings.liveTranscriptEnabled: Bool?` (nil default), mapped in `settings()` and `updateSettings`.
   - `AppSettingsData.liveTranscriptEnabled: Bool?` and `func liveTranscriptResolved(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool`: nil is on, except at 8 GiB or less.

2. **Transcription package**:
   - `LiveTranscriptSnapshot`: fields become `public let`; the init sorts rows by start time (stable), so a snapshot is always frozen and in time order (phase 1 follow-up).
   - `LiveTranscription/WhisperLanguage.swift`: `public extension LiveLanguage { var isSupportedByWhisper: Bool }`, so the app checks the language before a start (a `LiveSessionError` reaches the app as `transcriptionFailed`).
   - New `Transcription/WhisperModelFiles.swift`: `public enum WhisperModelFiles` with `isPresent(model:)` (model folder with a `.mlmodelc` and the tokenizer's `tokenizer.json`, in the large-v3 layout) and `download(model:status:)` (`WhisperKit.download` into the model cache, then `ModelUtilities.loadTokenizer` with the cache as `tokenizerFolder`, which fetches the tokenizer into `models/openai/<name>`; never loads the model). The presence check takes the base folder, so it is tested on a temporary folder.

3. **AudioCapture** (`AudioRecorder.swift`): a `start(paths:liveTap:)` on a recorder that is already recording closes the new tap, so its consumer sees `.end` (phase 6 follow-up). The recordable `ac_*` steps are already not-run.

4. **Recording**:
   - `RecorderControlling.start(paths:liveTap:)` replaces `start(paths:)` (an extension keeps `start(paths:)`), and `timelineOffset() async -> TimeInterval?`.
   - `RecordingController.start(title:liveTap:)` passes the tap; `RecordingState.timelineOffset` is copied from the recorder after start (phase 6 follow-up).

5. **TranscriptionService**:
   - `Transcribing`'s methods and `LiveTranscriberAdapter`'s become `nonisolated(nonsending)`, and the cancel in `recordingDidStart` is sent from the MainActor, so the pass and the cancel leave in the MainActor's order (phase 7 follow-up).
   - `releaseWorkerIfIdle()`: shuts this service's connection down unless a pass runs. AppCore calls it when a live finish ran out of time, so a worker stuck in a live decode has no connection left and exits (phase 7 follow-up).

6. **`LiveTranscriptionService` module** (depends on AudioCapture, Transcription, LiveTranscriptModel, LiveTranscription):
   - `LiveStatus`, `PauseReason`, `UnavailableReason`, `RevealRequest`, `LiveModelState` (`missing`, `downloading(String)`, `ready`, `failed(String)`), `LiveFinishResult` (`finished`, `timedOut`, `cancelled`, `nothingToFinish`).
   - `LiveEngineSession: LiveTranscriptionSession` adds `offer(_:) async -> Bool` (false: the chunk was not taken). `WhisperXPCSession` (actor) implements it over a `LiveWorkerClient` protocol that `Transcriber` conforms to: one client per session, shut down when the session ends. A start refused as `workerBusy` (a final pass that reached the worker after the queue's cancel) calls `cancelActiveWork` and starts once more.
   - `LiveBlockSource` (`drain(_:)`), with `LiveAudioQueue` conforming; `LiveAudioSource` (mic and system sources), with `LiveAudioTap` conforming.
   - `TrackResampler`: downmix by averaging, a persistent `AVAudioConverter` per source format (rebuilt when rate or channels change), a fresh input buffer per call, flush at end of stream.
   - `LivePumpCore` (pure, one per pump): per track, a 20 ms late-block rule (gap and discontinuity), overlap trimming, `.notStarted` shifting the start, `.captureGap` and `.overflow` gaps, a discard-before time for a start mid-recording, 250 ms chunks offered to a sink (a refused chunk becomes a `queueOverflow` gap and the next chunk is discontinuous), levels (RMS of the last 50 ms of the louder track, −60…0 dBFS to 0…1) and per-track progress, end flushing.
   - `LiveAudioPump`: runs the core on a serial `.userInitiated` queue every 50 ms; `hold()`/`resume()` stop draining during an engine restart or language switch (the tap queues buffer meanwhile); events (`progress`, `gap`, `level` at most 12 Hz, `ended`) in an `AsyncStream`.
   - `LiveChunkPipe`: at most 8 chunks per track queued or in flight between the pump and the engine.
   - `LiveTranscriptStore` (value type): rows by ID in start-time order, append-only settled text (debug assertion through an injectable handler, error log), updates from another session or generation or with a lower revision ignored, gaps merged per track (the session's discontinuity gap and the pump's gap become one, phase 2 follow-up), per-track watermarks extended through recorded gaps, activity from pump progress (a track that has fallen 3 s behind the newest capture is stalled and not active, phase 6 follow-up), status (`catchingUp` over 10 s behind on an active track), generations (a restart drops the old generation's tails) and snapshots (tail stripped, open row's end clamped to the track's settled time, phase 1 follow-up).
   - `PowerPolicy` over a `PowerStateProviding` source (`ProcessInfo` and its two notifications in the app): Low Power Mode doubles the interval, `.serious`/`.critical` pauses.
   - `LiveRecordingSession` (MainActor, one per recording): pump, pipe, forwarder, engine, store, restart once (an `engineRestart` gap from each track's settled time to the last chunk the failed session got; a second failure is `unavailable(.stopped)`), language switch (finish, then a new generation), finishing under one 10 s deadline, and cancellation.
   - `LiveTranscriptionService` (`@MainActor @Observable`): the public interface from the component, plus `modelState`/`downloadModel()` and `canStartLive` for AppCore. `start(meetingID:tap:timelineOffset:recordingStartedAt:)` returns once the session is set up; the engine starts in the background. `stop(_:)` returns `Task<LiveFinishResult, Never>`. Drafts are owned by their recording's session; `releaseDraft` ends that.

7. **AppCore**:
   - `Notification.Name.liveTranscriptEnabledDidChange`; the settings observers re-read the setting and call `setEnabled`; `onLaunch` applies the stored setting.
   - `let liveTranscription: LiveTranscriptionService` (an init parameter; nil builds an inert service with no model); `AppCore.live` builds it with the hosted worker, `WhisperModelFiles`, `VocabularyService` and `ProcessInfo` power.
   - Start: a new `LiveAudioTap` per recording goes to `recording.start`; `recordingDidStart(meetingID, liveTranscription: liveTranscription.canStartLive)`; then `liveTranscription.start`.
   - Stop: `liveTranscription.stop(meetingID)` right after capture stops; the stop task awaits it (calling `releaseWorkerIfIdle` on `.timedOut`) before `recordingDidStop`, then transcribes and releases the draft once the job is `.completed`. The partial-startup teardown cancels live too.

8. **MeetingDetailUI**: `liveDrafts` becomes optional and defaults to `core.liveTranscription` (phase 9 follow-up); a completed job releases the meeting's draft.

9. **Onboarding**: the transcription download step also downloads the live model when live transcription is on, and the step counts as downloaded only when both are present.

## Tests

- `DataStoreTests`: `liveTranscriptSettingDefaultsToNil`, `liveTranscriptSettingResolvesByMemory`, `liveTranscriptSettingSurvivesUnrelatedWrite`.
- `LiveTranscriptSnapshotTests`: `rowsAreSortedByStartTime`.
- `WhisperModelFilesTests`: `presentNeedsModelAndTokenizer`, `variantFromFolderName`.
- `LiveLanguageSupportTests`: `whisperSupportsEnglishDetectAndKnownLocales`.
- `AudioRecorderLiveTapTests`: `startWhileRecordingClosesTheNewTap`.
- `RecordingControllerTests`: `startPassesTheLiveTapAndCopiesTimelineOffset`.
- `LiveAudioPumpTests` (scripted blocks): `resamples24kMicTo16kWithExactTimes`, `resamples48kStereoSystemByDownmixing`, `formatChangeRebuildsConverterWithoutTimeJump`, `lateBlockEmitsGapAndDiscontinuity`, `overlappingBlockIsTrimmed`, `notStartedGapShiftsStartWithoutVisibleGap`, `discardBeforeDropsEarlierAudio`, `refusedChunkRecordsGapAndMarksNextDiscontinuous`, `levelsMapDecibelsToUnitRange`, `endFlushesPartialChunks`, `pumpDrainsOnItsQueueAndEnds`.
- `LiveChunkPipeTests`: `atMostEightPerTrack`.
- `LiveTranscriptStoreTests`: `mergesTracksInTimeOrder`, `updateReplacesTailKeepsID`, `staleGenerationIsIgnored`, `lowerRevisionIsIgnored`, `nonAppendOnlySettledTextIsRejectedAndLogged`, `catchingUpAfterTenSecondsBehind`, `stalledTrackIsNotActive`, `duplicateGapsAreMerged`, `settledThroughExtendsThroughGaps`, `newGenerationDropsOldTails`, `snapshotClampsOpenRowEndWithoutTail`.
- `PowerPolicyTests`: `lowPowerDoublesInterval`, `seriousHeatPausesAndNominalResumes`.
- `WhisperXPCSessionTests` (fake client): `busyStartCancelsActiveWorkAndRetriesOnce`, `updatesEndWhenTheWorkerEndsTheSession`, `cancelShutsTheClientDown`.
- `LiveTranscriptionServiceTests` (fake engine, scripted tap): `startsWithResolvedLanguageAndVocabulary`, `missingModelIsUnavailable`, `unsupportedLanguageIsUnavailable`, `restartsOnceThenBecomesUnavailable`, `stopPublishesDraftImmediately`, `stopKeepsDraftUntilReleased`, `finishingSessionWritesOnlyItsOwnDraft`, `newRecordingCancelsEarlierFinishing`, `stopDeadlineCoversDrainAndFinish`, `stopDuringStartCancelsAtOnce`, `inTransitLimitRecordsGap`, `failedFinalPassKeepsDraft`, `enablingMidRecordingSetsStartMarker`, `disablingMidRecordingClearsLiveState`, `powerPolicyPausesAndSlowsTheEngine`, `languageChangeStartsANewGeneration`, `revealSetsRequest`, `drawerStatePersists`, `snapshotExcludesTailWhenAsked`, `downloadThenStartsMidRecording`.
- `TranscriptionServiceQueueTests`: `releaseWorkerIfIdleShutsDownOnlyWithoutAPass`.
- `AppCoreLiveTests` (fake engine): `startRecordingPassesTapAndStartsLiveAfterTheQueue`, `stopRecordingFinishesLiveThenQueuesFinalPass`, `completedPassReleasesTheDraft`, `settingChangeMidRecordingStartsOrStopsLive`.
- `MeetingDetailDraftTests`: `defaultSourceReadsTheLiveService`.

---
status: complete
---

# Component: Live Transcription Service

## Purpose and scope

The app-side coordinator, a new `LiveTranscriptionService` module in BiscottiKit (L1), owned by AppCore. It:

- drains the live audio tap and turns it into 16 kHz chunks on the recording timeline,
- runs the chosen engine,
- keeps the live transcript, the draft after Stop and the drawer state,
- publishes status and levels for the UI,
- applies the power and heat policy,
- provides snapshots to other features.

Not in scope: drawing anything ([live_drawer](live_drawer.md), [transcript_bubble_view](transcript_bubble_view.md)), decoding ([live_session](live_session.md)).

## Public interface

```swift
public enum LiveStatus: Equatable, Sendable {
    case off, starting, live, catchingUp
    case paused(PauseReason)                // .lowPowerHeat
    case unavailable(UnavailableReason)     // .modelMissing, .languageUnsupported, .stopped
}

@MainActor @Observable
public final class LiveTranscriptionService {
    public private(set) var status: LiveStatus
    public private(set) var level: Float                  // 0...1, about 12 updates per second
    public private(set) var rows: [LiveRow]               // time order across tracks
    public private(set) var gaps: [LiveGap]
    public private(set) var startMarker: TimeInterval?    // set when started mid-recording
    public private(set) var language: LiveLanguage
    public private(set) var detectedLanguageName: String?
    public var isDrawerExpanded: Bool                     // persisted in UserDefaults
    public private(set) var revealRequest: RevealRequest? // drawer scrolls to it, then clears it
    public var isEnabled: Bool { get }                    // resolved setting

    public func start(meetingID: UUID, tap: LiveAudioTap, timelineOffset: TimeInterval) async  // cancels earlier finishing work
    public func stop(_ meetingID: UUID) -> Task<Void, Never>   // publishes the draft now; returns the finishing task
    public func setEnabled(_ enabled: Bool) async         // from Settings; may start or stop mid-recording
    public func setLanguage(_ language: LiveLanguage) async
    public func toggleDrawer()
    public func reveal(atRecordingTime time: TimeInterval)
    public func snapshot(includeTail: Bool) -> LiveTranscriptSnapshot?
    public func draft(for meetingID: UUID) -> LiveTranscriptSnapshot?
    public func releaseDraft(for meetingID: UUID)
}
```

Engines implement the one `LiveTranscriptionSession` protocol from `LiveTranscriptModel`, so the service does not know which one runs. `WhisperXPCSession`, in this module, forwards to the worker through `Transcriber`. `SpeechAnalyzerLiveSession`, kept on the reference branch with the replay harness, would run in process.

Each recording gets its own internal `LiveRecordingSession` holding its pump, engine session, store and meeting ID. The service's observable state mirrors `current`; a detached session that is still finishing can write only to its own meeting's draft. The engine, the Whisper model and the update interval come from one code constant, `LiveTranscriptionDefaults`, which the experiment sets; they are not user settings.

## Audio pump

`LiveAudioPump` runs on its own thread (QoS `.userInitiated`) and wakes every 50 ms.

1. Drain both queues of the tap.
2. **Per track:** convert to 16 kHz mono Float32 with a persistent `AVAudioConverter` per source format, rebuilt when rate or channel count changes, with a fresh input buffer for every call. Downmix by averaging channels before converting.
3. **Timeline:** each block's `startTime` is the source of truth. If a block starts later than the previous block ended by more than 20 ms, emit a `LiveGap` and mark the next chunk `isDiscontinuity`. `.notStarted` gaps (system leading silence) move the track's start time without a visible gap.
4. **Chunks:** accumulate 250 ms per track, then send a `LiveAudioChunk` to the engine. At most 8 chunks per track may be unacknowledged; a chunk over the limit waits in the pump, oldest first, and is offered again. Waiting audio beyond `LiveAudioLimits.pumpBacklog` per track is dropped as a `queueOverflow` gap, silent when every dropped chunk was, and the next chunk is marked discontinuous. (The backlog was 45 s, then 35 s after the UI review of 25 October 2026, and is 15 minutes since the second UI review; see Backfill below.)
   - **Backfill (chosen by the user in the second UI review, 25 October 2026):** the pump keeps up to 15 minutes of waiting audio per track (`LiveAudioLimits.pumpBacklog`), as 16-bit samples (about 29 MB per track; a chunk the pipe takes at once is never converted). Only audio beyond it is a `queueOverflow` gap. `LiveChunkPipe` carries one stream per track, read by one forwarder per track, so a track that waits does not hold up the other. A forwarder hands a chunk to the engine only when its end is within `engineLead` (36 s) of how far this generation's engine has transcribed the track (from its own updates; the store keeps an earlier generation's time), or of the first chunk this generation took; otherwise it waits for the next update. While paused, chunks are handed over without waiting: the session drops them as one `paused` gap, and they count as handled when the pause ends. With the 4 s in transit, the session never holds more than its 45 s. A chunk handed over more than `backfillLag` (5 s) behind the track's newest captured audio is marked `isBackfill`, and the session catches up on it ([live_session](live_session.md#catch-up)).
5. **Mixed mode:** keep both tracks aligned by time and sum them once both have audio up to t, or after 500 ms, treating the missing track as silence.
6. **Levels:** RMS over the last 50 ms of the louder track, mapped from −60…0 dBFS to 0…1 and published to the main actor at 12 Hz.
7. **Stop:** on `.end` from both tracks, flush the converters and send the last partial chunks.

## Live transcript store

- Holds the rows by ID. An update replaces rows with the same ID and appends new ones; settled text is checked to be append-only (a debug assertion and an error log in release builds).
- Merges both tracks in start-time order. Pending updates are merged, never replaced, and applied to observable state at most 4 times per second.
- **Gaps:** the earlier report of a stretch wins. A new gap adds only the time no gap of its track covers, and joins touching gaps of the same silence. The session's gap for a discontinuity repeats the pump's report of the same stretch without knowing its audio, so the pump's silence is kept. An `engineRestart` gap is silent when no chunk with sound the engine took ends after its start.
- Ignores updates whose session ID or generation does not match.

**Status:**

| Status | When |
|---|---|
| `starting` | Until the first update |
| `live` | Normally |
| `catchingUp` | `now − transcribedThrough > 10 s` on any active track |
| `paused` | From the power policy |
| `unavailable(reason)` | On start failure or after a second engine failure |

## Power and heat policy

`PowerPolicy` observes `ProcessInfo.isLowPowerModeEnabled` (`NSProcessInfoPowerStateDidChange`) and `ProcessInfo.thermalState` (`thermalStateDidChangeNotification`).

- Low Power Mode doubles the update interval.
- `.serious` or `.critical` pauses the engine; status becomes `paused`.
- Returning to `.nominal` or `.fair` resumes it.

## Lifecycle

- **Start:**
  1. Resolve the setting and engine availability; on failure, show `unavailable`.
  2. Read vocabulary with `VocabularyService.effectiveVocabulary(meetingID:)`.
  3. Pick the language from the menu default: English when the Mac's language is English, otherwise Detect.
  4. Build the config with a new session ID and generation, start the engine, then start the pump.
- **Restart once:** on an engine error or worker interruption, start a new session with generation + 1. A second failure sets `unavailable(.stopped)` and stops the pump; the drawer keeps what it has.
  - Since the second UI review (25 October 2026), nothing is lost at a restart: the session keeps the chunks the engine took past its track's settled time (16-bit, trimmed on each update, at most 2 minutes), and the new engine gets them first, from the settled time on, before newer chunks (`replayUnsettledAudio`). The audio that arrives meanwhile waits in the pump. A language change replays what the old engine's finish left unsettled the same way; a replay still running keeps what it has not delivered, after it. Audio the replay no longer holds is an `engineRestart` gap. Otherwise an `engineRestart` gap marks only audio the engine took that a Stop or finish could not settle.
  - A finish that runs out of time, or a Stop with no engine, also marks the audio no engine took (still waiting in the pump, the pipe or a replay) as a `queueOverflow` gap, so the draft shows it as not transcribed live. The gap is silent when no chunk the pump made after its start had sound (`LivePumpCore.chunkExtents`), so a silent backlog shows no marker.
  - Offers in flight are counted across the forwarders and replays, so a restart waits for all of them before it takes the unsettled audio.
- **Language change** (review fix, 26 October 2026): the worker replies to the old engine's finish only once its last decode returns, which a slow decode can delay past the finish's own timeout, and a decode that never returns makes the worker end itself after `LiveWorkerLimits.stuckDecode`. So the switch waits `languageSwitchTimeout` plus `workerStuckDecode` plus `finishMargin`: a healthy worker, and its kept model, survive a slow switch. A finish still unanswered then is cancelled, which closes that session's connection, and `onWorkerNeedsReset` (AppCore: `TranscriptionService.releaseWorkerIfIdle`) closes the queue's connection, the one that keeps the live model loaded; with no connection left, the worker exits, and the new engine starts in a fresh one. The kept model loads again after the recording.
- **Stop:**
  1. Publish `draft[meetingID] = snapshot(includeTail: true)` at once, detach the recording's session from `current`, and reset live state.
  2. In the returned task, under one 10-second deadline: wait for the pump's end, call `finish`, and apply the final updates to that meeting's draft only.
  3. If a new recording starts first, `start` cancels that task; the draft keeps what it has, with its tail marked incomplete.
  4. A Stop while a language change still waits for the old engine's finish, or resets the worker, returns `.languageSwitchUnfinished`. Like `.timedOut` (`LiveFinishResult.mayLeaveWorkerStuck`), it makes AppCore release the queue's worker before the final pass, so the pass never waits behind a stuck decode.
- **Drafts** are released when `TranscriptionService.jobs[meetingID]` becomes `.completed`, or on `releaseDraft`. A failed final pass keeps the draft.
- **Setting changes mid-recording:** off cancels the session and clears live state; on starts a session from now and sets `startMarker`.

## Snapshots

`snapshot(includeTail:)` copies the store on the main actor: session ID, revision, the capture watermark (the newest chunk end), transcribed-through and settled-through (the minimum across active tracks, where processed silence and recorded gaps count as resolved), rows (tails stripped when `includeTail` is false), and gaps. `meeting_chat` uses it; nothing in this project does.

## In-app latency (phase 11)

`LiveLatency`, one per `LiveRecordingSession`, measures what a real call adds to the harness's session latency, for the hardware check. Signposts go to the `live.latency` category (Instruments, or `log show --signpost`):

- **"Live chunk"**, per live chunk: from the engine taking it to the drawer drawing the update that covers it (`transcribedThrough` reaches the chunk's end). A "Covered" event marks that update; an update without rows ends the interval there. Backfill, replayed and paused chunks are not measured: they wait by design.
- **"Update to drawn"**: from the first update with rows after a drawing to the next drawing. The drawer reports a drawing on the next main-queue turn after `rowsRevision` changes (`rowsDrawn()`), after the frame that shows it is committed.
- A covered chunk or update the drawer does not draw within 5 s is not measured (the drawer is closed or off screen). At most 256 chunks wait per track.

Histograms of 10 ms buckets up to 10 s keep chunk to update, chunk to drawn, update to drawn and the worker's decode time. A `.notice` line in the `live` category gives p50, p95, the maximum and the count for the last 5 minutes, and once more for the whole session when it ends ("Live latency, whole session: …").

## DataStore and settings

- `AppSettings.liveTranscriptEnabled: Bool?` (default nil) and `AppSettingsData.liveTranscriptEnabled`. Resolution: nil means on, except on Macs with 8 GiB or less of physical memory, where it means off.
- `DataStore.currentUserPersonIDs() -> Set<UUID>`: the distinct non-nil `CalendarSnapshot.currentUserPersonID` values.
- `Notification.Name.liveTranscriptEnabledDidChange`, declared in AppCore like `.stopRecordingAutomaticallyDidChange`; AppCore re-reads the setting and calls `setEnabled`.

## Dependencies

- Depends on: `AudioCapture`, `Transcription`, `LiveTranscriptModel`, `LiveTranscription`.
- Used by: `AppCore` (owns it), `RecordingUI`, `MeetingDetailUI`, the `App` commands.

## Test plan

`LiveAudioPumpTests` (scripted queues):
- `resamples24kMicTo16kWithExactTimes`
- `resamples48kStereoSystemByDownmixing`
- `formatChangeRebuildsConverterWithoutTimeJump`
- `lateBlockEmitsGapAndDiscontinuity`
- `notStartedGapShiftsStartWithoutVisibleGap`
- `mixedModeAlignsTracksByTime`
- `levelsMapDecibelsToUnitRange`
- `endFlushesPartialChunks`

`LiveTranscriptStoreTests`:
- `mergesTracksInTimeOrder`, `updateReplacesTailKeepsID`, `staleGenerationIsIgnored`
- `nonAppendOnlySettledTextIsRejectedAndLogged`, `catchingUpAfterTenSecondsBehind`

`PowerPolicyTests`: `lowPowerDoublesInterval`, `seriousHeatPausesAndNominalResumes`.

`LiveTranscriptionServiceTests` (fake engine, fake tap):
- `startsWithResolvedLanguageAndVocabulary`
- `restartsOnceThenBecomesUnavailable`
- `stopKeepsDraftUntilFinalPassCompletes`
- `stopPublishesDraftImmediately`
- `finishingSessionWritesOnlyItsOwnDraft`
- `newRecordingCancelsEarlierFinishing`
- `stopDeadlineCoversDrainAndFinish`
- `inTransitLimitRecordsGap`
- `failedFinalPassKeepsDraft`
- `enablingMidRecordingSetsStartMarker`
- `disablingMidRecordingClearsLiveState`
- `revealSetsRequest`, `drawerStatePersists`
- `snapshotExcludesTailWhenAsked`

Second UI review (25 October 2026):
- `LiveTranscriptionServiceBackfillTests`: `forwarderPacesAudioToTheEngine`, `backlogIsMarkedBackfill`, `waitingTrackDoesNotHoldTheOther`, `longPauseDoesNotStopTheLiveTranscript`, `restartDuringCatchUpPacesTheReplay`, `timedOutFinishMarksTheWaitingAudio`, `timedOutFinishMarksSilentWaitingAudioSilent`
- `restartReplaysUnsettledAudio`, `replayChunkStartsAtTheSettledTime`, `languageSwitchTimeoutReplaysTheUnsettledAudio`, `drawerHeightPersists`, `replayChunksAreOrderedFromTheSettledTime`
- `LivePumpCoreBacklogTests`: `backlogBeyondRetentionBecomesGap` (15 minutes, 16-bit, under 30 MB), `waitingAudioKeepsItsSamples`, `chunkExtentsTrackSound`, `retentionIsThePumpBacklog`
- `LiveChunkPipeTests.eachTrackHasItsOwnStream`

`DataStoreTests`: `currentUserPersonIDsCollectsDistinctIDs`, `liveTranscriptSettingDefaultsToNil`, `liveTranscriptSettingResolvesByMemory`.

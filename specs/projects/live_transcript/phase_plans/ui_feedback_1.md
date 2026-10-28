---
status: complete
---

# UI Feedback 1: Startup, Layout, Gap Markers and Conversation Order

## Overview

The user recorded a real meeting with the phase 10 test build and chose four changes in UI review:

1. **Prepare in the background.** The live engine took 1 min 51 s to start: the one-time Neural Engine compile of whisper-small for a new build. After an install, an update or a model download, while no recording runs, Biscotti loads the live model and the final pass's Whisper model once in the worker, so macOS compiles them before the first meeting. Settings shows "Preparing live transcript…" while it runs. A recording cancels it at once through the queue's `recordingDidStart` and `cancelActiveWork`; a final pass that arrives cancels it too. What is prepared is remembered per app build and model. Nothing is downloaded.
2. **Wider drawer, notes move.** The drawer spans most of the window width, up to 880 pt. When it opens, the notes column moves up so the note field sits just above the drawer; the header scrolls up with it. The collapsed toggle sits where the open drawer's footer toggle sits.
3. **Quieter gap markers.** No marker for a stretch whose audio was silent (where the samples are known) or for one under 5 s. The rest read "Not transcribed live · 0:12" with the tooltip "Recording continued. The saved transcript includes this part." The cause of the false marker the user saw is fixed: the pump keeps less backlog than the worker retains, so a backlog handed over at start is never dropped.
4. **Bubbles in conversation order.** A live row also closes when the other track starts speaking, at a sentence end once it is 8 s long, and at a word boundary once it reaches 20 s.

## Steps

### 1. Gap markers and retention

1. `LiveTranscriptModel/LiveTypes.swift`: `LiveGap` gains `public var isSilent: Bool` (init default `false`, decoded with `decodeIfPresent`, default `false`). True only when the live path had the samples and every 250 ms frame was below −45 dBFS.
2. New `LiveTranscriptModel/LiveAudioLimits.swift`:
   ```swift
   public enum LiveAudioLimits {
       public static let sessionRetention: TimeInterval = 45
       public static let inTransit: TimeInterval = 4          // 8 chunks in the app's pipe + 8 unacknowledged over XPC
       public static let firstDecodesAllowance: TimeInterval = 6
       public static let pumpBacklog: TimeInterval = sessionRetention - inTransit - firstDecodesAllowance  // 35
   }
   ```
   `TrackAudio.retentionLimit` uses `sessionRetention`; `LivePumpCore.retention` uses `pumpBacklog`.
3. `LiveTranscription/AudioLevel.swift`: make `AudioLevel` and `isSilent` public, so the app's pump and forwarder use the same per-frame test.
4. `TrackAudio.enforceRetentionLimit`: each overflow gap's `isSilent` comes from the dropped samples; `add(_:to:)` joins a gap only with one of the same reason and silence.
5. `WhisperLiveSession`: `PausedSpan` tracks whether every dropped chunk was silent; `TrackState.receive(_:after:gapIsSilent:)` and `finishLastWindow` carry it into the `.paused` gap.
6. `LivePumpCore.dropBeyondRetention`: the lost gap is silent when every dropped chunk is.
7. `LiveRecordingSession`: the forwarder records, per track, the end of the newest non-silent chunk the engine took. `recordRestartGaps` marks an `engineRestart` gap silent when no such chunk ends after its start.
8. `LiveTranscriptStore.addGap`: earlier reports win for the time they cover. A new gap adds only the stretches no recorded gap of its track covers; each new stretch joins touching gaps of the same silence. (The worker's discontinuity gap repeats the pump's report of the same stretch without knowing its samples.)
9. `TranscriptUI/TranscriptItemBuilder.live`: drop silent gaps, merge the rest across tracks as today, then drop merged markers shorter than `minimumGapMarker = 5` s. The draft and the drawer both use it.
10. `TranscriptItemRow`: the gap caption reads "Not transcribed live · 0:12" with `.help("Recording continued. The saved transcript includes this part.")`; VoiceOver reads both.

### 2. Conversation order

1. `LiveTranscriptModel`: `TimedWord.endsSentence` (moved from `LocalAgreementReducer.Token`).
2. `LiveRowBuilder`:
   - `sentenceRowLength = 8`, `maxRowLength = 20`.
   - `OpenRow.closes(before:breaks:)`: a pause of `rowPause`; a row at least 8 s long whose last word ends a sentence; a row at least 20 s long; or a break time after the row's start that the word starts at or after.
   - `settle` closes the open row by that rule. A new row drops the breaks at or before its first word.
   - The tail splits by the same rule: the words the open row would take stay in it, the rest show on the tail row (whose ID the next new row takes, as today). Recomputed in `setTail`, `closeOpenRow` and `breakRow(at:)`.
   - `breakRow(at:)`: records a break when the open row, or the tail's own row, started before it.
   - `latestSpeechStart`: the start of the newest word that follows a pause of `rowPause` (or the track's first word), settled or in the tail. Rows split by the length or break rules are not speech starts, so two tracks cannot split each other back and forth.
3. `LocalAgreementReducer`: `public mutating func breakRow(at:) -> [LiveRow]` and `public var latestSpeechStart: TimeInterval?`.
4. `WhisperLiveSession`: after every reducer change on a track (`decodeWindow`, `finishWindow`, `commitTail`, `finishLastWindow`), when its `latestSpeechStart` moved past the last one handled, break the other track's row at that time and emit the other track's changed rows.

### 3. Layout

1. `LiveTranscriptOverlay`: the overlay spans `drawerWidth(forAvailableWidth:) = min(width − 2 × spacingMD, 880)`, centered. The drawer card fills it. The toggle sits `LiveTranscriptDrawer.outset` (12 pt) inside the card's leading edge, collapsed or open. The card's negative padding goes away.
2. `RecordingView.recordingContent`: in a `ScrollViewReader`. Collapsed (or live off), the column stays centered as today. Expanded, the column aligns to the top, the bottom margin stays drawer height + 16 pt, and the view scrolls the note composer (`id "note-composer"`, set in `RecordingNotesView`) to the bottom of the visible area when the drawer opens, when the drawer height changes and when the recording screen appears with the drawer open. Animated with the drawer's spring (cross-fade timing with Reduce Motion).
3. `DrawerFooter`: its leading spacer still reserves the toggle's slot (outset + toggle − spacing).

### 4. Background preparation

Worker (`Packages/Transcription`):

1. `TranscriberServiceProtocol.prepareModels(requestData:reply:)`: JSON `[String]` of Whisper model folder names in; JSON `[String]` of the names prepared out.
2. `EngineHost`: activity `.preparing(Preparation)`. `startPreparation(models:)` waits while a live session ends, refuses with `workerBusy` unless idle, unloads the final pass's models, then for each model in order: stop if cancelled; skip one not on disk (`WhisperModelFiles.isPresent`, a seam); load it through `liveModels` (never downloads) and unload it at once; log the time. `cancelActiveWork` cancels it and waits for the load in progress; `ownerDidDisconnect` cancels it. A final pass or live start meanwhile gets `workerBusy`, as during other work.
3. `TranscriberService.prepareModels`: admitted through the admission inbox, like a final pass, so a later `cancelActiveWork` always stops it; cancelled when its connection closes. Replies with the models prepared, also after a cancel.
4. `Transcriber.prepareModels(_:)` (hosted only; `.inProcess` returns `[]`).
5. `TranscriptionMethod.whisperModel` becomes public.

App (`Packages/BiscottiKit`):

6. `Transcribing.prepareModels(_:)`; `LiveTranscriberAdapter`, `PreviewTranscriber` and the test fakes implement it.
7. New `TranscriptionService/PreparedModels.swift`: remembers, in `UserDefaults` (nil keeps it in memory), which models are prepared for one build identity; a different identity starts empty. `PreparedModels.buildIdentity(of:)` combines the bundle's version, build number, the modification times of its executable and its XPC services' executables, and the OS version, so every installed or rebuilt app and every OS update counts as new.
8. `TranscriptionService`:
   - `prepareModels(_ models:)` queues the models not yet prepared for this build and not already queued.
   - Observable `isPreparingModels`.
   - The runner runs the preparation only when no recording runs and no final pass waits.
   - A recording that starts cancels it like a running pass (`recordingDidStart`: `cancelActiveWork` within `cancelTimeout`, else shut the worker down). A final pass queued during it cancels it the same way.
   - Prepared models are recorded. After a cancel, the unprepared ones run again once the queue is free; otherwise, failures and missing models wait for the next trigger.
   - The worker is shut down after the preparation when nothing else waits.
9. `AppCore`: `prepareModelsInBackground()` queues the live model (when live transcription is on and its model is on disk), then the final pass's Whisper model (when its models are on disk). Called at the end of `onLaunch` (onboarding complete), after `completeOnboarding`, when the live setting turns on, and when the live model download finishes (`LiveTranscriptionService.onModelDownloaded`, set by AppCore).
10. `SettingsUI`: under "Show live transcript while recording", while the toggle is on and `core.transcription.isPreparingModels`: a small spinner and "Preparing live transcript…" in the caption style.

### 5. Docs

`ui_design.md` and `components/live_drawer.md`: the wider drawer, the toggle position, the notes moving up and the gap marker copy, with a dated note (25 October 2026) that the user chose them in UI review. `functional_spec.md` (gaps rule and drawer layout), `architecture.md` and `components/live_transcription_service.md` (pump backlog 35 s), `components/live_session.md` (row closing rules), `components/transcriber_worker.md` (the preparation message and queue item) and `components/transcript_bubble_view.md` (gap markers) follow.

## Tests

- `LiveTypesCodecTests.gapWithoutSilenceFieldDecodesAsNotSilent`: older JSON decodes.
- `LiveAudioLimitsTests.pumpBacklogFitsTheSessionWithChunksInTransit`: backlog + in transit + allowance = session retention.
- `TrackAudioTests.silentOverflowIsMarkedSilent`, `overflowOfSpeechIsNotSilent`, `silentAndSpokenOverflowStaySeparate`.
- `WhisperLiveSessionTests.backlogHandedOverAtStartIsNotDropped`: both tracks get the pump's whole backlog plus what is in transit at once, then real-time audio during slow first decodes; no `queueOverflow` gap.
- `WhisperLiveSessionTests.silentPauseGapIsSilent`.
- `LiveAudioPumpTests.droppedSilenceIsASilentGap`, `droppedSpeechIsNotSilent`, `retentionIsThePumpBacklog`.
- `LiveTranscriptStoreTests.duplicateReportKeepsTheEarlierSilence`, `newStretchesJoinOnlyGapsOfTheSameSilence`.
- `LiveTranscriptionServiceTests.restartGapOverSilenceIsSilent`.
- `TranscriptItemBuilderTests.silentGapShowsNoMarker`, `gapUnderFiveSecondsShowsNoMarker`, `silentPartsDoNotCountTowardTheMarker`.
- `LiveRowBuilder` / reducer: `rowClosesAtSentenceEndAfterEightSeconds`, `rowStaysOpenBeforeEightSeconds`, `rowClosesAtWordBoundaryAfterTwentySeconds`, `breakClosesRowBeforeLaterWords`, `breakSplitsTheTail`, `breakBeforeRowStartIsIgnored`, `speechStartIgnoresRuleSplits`, `rowIDsStayStableAcrossSplits`; the 500-run append-only property test also breaks rows at random.
- `WhisperLiveSessionTests.otherTrackStartingClosesTheRow`, `interleavedConversationAlternatesRows`.
- `EngineHostTests.preparationLoadsAndUnloadsEachPresentModel`, `preparationSkipsMissingModels`, `cancelActiveWorkStopsPreparationBetweenModels`, `preparationRefusesWhileBusy`, `finalPassDuringPreparationIsBusy`, `disconnectCancelsPreparation`.
- `TranscriberLiveClientTests.prepareModelsRoundTrips`.
- `TranscriptionServiceQueueTests`: `preparationRunsWhenTheQueueIsIdle`, `preparationWaitsForQueuedPasses`, `recordingStartCancelsPreparationAndItResumesAfter`, `passQueuedDuringPreparationCancelsIt`, `preparedModelsAreNotPreparedAgainForTheSameBuild`, `newBuildPreparesAgain`, `isPreparingModelsWhileRunning`.
- `PreparedModelsTests.identityChangesWithBuildAndExecutable`.
- `AppCoreTests`: `launchPreparesPresentModels`, `liveModelDownloadPreparesIt`, `enablingLivePreparesItsModel`.
- `SettingsViewModelTests.preparingCaptionShowsWhileLiveIsOn`.
- `LiveTranscriptOverlayTests`: `drawerWidthSpansWindowUpTo880`, `notesAlignTopOnlyWhileExpanded`.

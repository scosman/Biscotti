---
status: complete
---

# UI Feedback 2: Fast Starts, Backfill and a Height Handle

## Overview

The user reviewed the round 1 test build:

1. **The live start is still slow.** Each new worker process compiles whisper-small for the Neural Engine again (1 min 44 s and 2 min in the user's meetings), even after the background preparation. The user chose "Fix the cache": find why the compile result is not reused, fix it so a start takes seconds, and keep the live model loaded while the live transcript is on only if the cache cannot be fixed.
2. **Backfill.** The live transcript should cover the recording from its start: audio recorded before the engine runs, and during restarts, is kept (up to 15 minutes per track) and transcribed in a catch-up mode, then the drawer streams at the live edge.
3. **A height handle.** The drawer keeps its width (at most 880 pt). Its top edge can be dragged to change the height, which is remembered.
4. **Round 1 leftovers:** re-apply the notes offset when the drawer opens; prepare a model downloaded again while it is queued or being prepared; prepare the live model before a final-pass model batch.

## Steps

### 1. The compile cache

1. Measure, with fresh processes outside the app, how long whisper-small takes to load the first and the second time, and how the worker differs: a probe executable loading the three Core ML models with WhisperKit's compute units, varying how the process ends, its signing identity and its environment, compared with the worker's logs (aned's `existsInCache`, ANECompilerService's "Calling ANE compiler") and the e5 bundle cache under `~/Library/Caches/<identity>/com.apple.e5rt.e5bundlecache`.
2. Fix the cause in the worker (or in how the app starts and ends it), so the second and later loads of a model take seconds. Record the cause and before and after times in `specs/research/live_transcription/README.md`.
3. Check whether the final pass's large-v3 compiles on every run; report the cost, and apply the same fix if it covers it.
4. If the cache cannot persist: keep the live model loaded in the worker while the live transcript is on, and report the memory cost and the evidence.
5. Report what makes the worker's HTTPS requests to Hugging Face before a load; change it only if it is live-transcript code.

### 2. Preparation

1. `TranscriptionService.recordingDidStart(_:liveTranscription:keepingPreparationOf:)`: a recording that starts while the live model's own run is being prepared does not cancel it; the live session's start waits for that load (its `workerBusy` retry calls `cancelActiveWork`, which returns once the load in progress ends). A final-pass model run is still cancelled.
2. `prepareModels(_:first:)`: the live model's run goes to the front of the queue.
3. `forgetPreparedModel` while the model is queued keeps it queued; while it is being prepared, it is prepared again after that run.
4. Decide, from the measured warm-load time, whether to prepare at every launch and whether to key the record on the OS build too.

### 3. Backfill

1. `LiveAudioLimits`: `sessionRetention` 45 s; `inTransit` 4 s; `engineLead` 36 s (how far past a track's settled time the app hands audio to the engine), with `engineLead + inTransit < sessionRetention`; `pumpBacklog` 15 minutes; `backfillLag` 5 s.
2. `LivePumpCore`: waiting chunks are stored as 16-bit samples (about 29 MB per track for 15 minutes) and converted back when offered.
3. `LiveChunkPipe`: one stream per track, read by one forwarder per track, so one track waiting does not hold up the other.
4. `LiveRecordingSession`: a forwarder hands a chunk to the engine only when its end is within `engineLead` of the track's settled time, and waits for updates otherwise. A chunk handed over more than `backfillLag` behind the newest captured audio is marked `isBackfill`.
5. `LiveAudioChunk.isBackfill` (in the XPC header, decoded as false when missing).
6. `WhisperLiveSession`, catch-up mode:
   - A track that receives backfill audio catches up. While any track catches up, no streaming decode runs.
   - A catch-up decode takes the first 30 s of the track's window (or what is left once live audio arrives or a gap follows) and keeps the words that end at least 1 s before the decoded audio's end, or all of them at a gap, the live edge or the finish. The window is trimmed at the last kept word.
   - Kept words wait in a per-track queue and are settled in start-time order across tracks, up to the time every catching-up track has decoded through, so rows break where the other side starts speaking, as in streaming.
   - Silent windows are skipped. Decodes follow the update interval and pause as the power policy says.
   - When no track has backfill left, the queues are settled and the tracks stream from the remaining window at 1 s.
   - `finish` settles the queues before its final decodes.
7. The drawer header shows "Catching up…" with a mini spinner while the status is `.catchingUp`; the footer no longer repeats it.
8. Gap markers appear only for audio beyond the 15-minute backlog (and for capture gaps), with the round 1 rules.
9. Restarts lose nothing: `LiveRecordingSession` keeps the chunks the engine took past its track's settled time (16-bit, at most 45 s), and a restarted engine, or the next generation after a language change, gets them first, from the settled time on. An `engineRestart` gap marks only what a Stop or finish could not settle.

### 4. Height handle

1. `LiveTranscriptionService.drawerHeight: CGFloat?` (UserDefaults `liveTranscript.drawerHeight`).
2. `LiveTranscriptOverlay.openLayout(..., preferredHeight:, firstRowsHeight:)`: a chosen height is clamped between 240 pt and the height that keeps the status row (and the auto-stop card) in view; without one, the round 1 default applies. The notes offset follows the height.
3. A drag area along the drawer's top edge, with the vertical-resize pointer and a small grabber that shows on hover. Dragging changes the height live and saves it at the end; double-click restores the default; VoiceOver adjusts it in 40 pt steps.

### 5. Round 1 leftovers

1. The notes scroll is keyed on the offset and on the drawer being open.

### 6. Docs

`ui_design.md`, `components/live_drawer.md`, `components/transcriber_worker.md`, `components/live_session.md`, `components/live_transcription_service.md`, `functional_spec.md`, `architecture.md` with dated notes that the user chose these; `specs/research/live_transcription/README.md` with the cache cause and fix. The recordable `tx_*` steps stay not-run.

## Tests

- `LiveAudioLimitsTests`: the lead and transit fit the retention; the backlog is 15 minutes.
- `LiveAudioPumpTests`: waiting audio is kept for 15 minutes in 16-bit samples; only audio beyond it is a gap.
- `LiveTranscriptionServiceTests`: the forwarder holds a chunk until the engine is within the lead; backlog chunks are marked backfill and live ones are not; one track waiting does not hold the other; a restarted engine first gets the unsettled audio, from the settled time; a language change replays what its finish left; the drawer height persists.
- `LiveTypesCodecTests`: a chunk keeps `isBackfill`; older data decodes as live.
- `WhisperLiveSessionCatchUpTests`: backfill is decoded in 30 s windows with exact times; words near a window's end wait for the next window; two tracks settle in conversation order; a silent window is skipped; the handoff to streaming; the finish settles pending catch-up words; no streaming decode while catching up.
- `TranscriptionServicePreparationTests`: a recording keeps the live model's run; a recording cancels a final-pass model's run; the live run goes first; a model forgotten while being prepared is prepared again.
- `RecordingViewModelLiveTests`: a chosen height is kept within 240 pt and the status row; the default still shrinks to fit; double-click restores the default; the height persists.

## Review fixes

- **Kept model and final passes:** the worker releases the kept model before a final pass, before loading any other model, and unloads the final pass's models before a live session on the kept model. After a pass, the worker shuts down when nothing waits, and the kept model loads in a fresh worker. An idle worker crash and a re-download load it again; a failed load is not retried in a loop. `AppCore.physicalMemory` lets tests cover both memory branches.
- **Pause:** while paused, forwarders hand audio over without the lead check, and a resume measures the lead from the last paused chunk.
- **Restarts:** the lead counts from the new generation's own progress; unsettled audio is trimmed from the settled time and kept up to 2 minutes; a replay gap marks what it no longer holds; a restart during a replay rebuilds it in time order; offers in flight are counted across deliverers.
- **Catch-up:** a stall keeps every word, the rest of a trimmed window counts as new audio, and a word repeated at a window boundary is committed once.
- **Stop:** a finish that runs out of time marks the audio no engine took as not transcribed live.
- **Drawer:** a drag the drawer's hiding cancels leaves no height behind.
- **Second review:** a catch-up stall counts from the latest catch-up decode's end, not only the last chunk; kept words also wait for a streaming track's window start; unforwarded gaps are silent when the pump made no chunk with sound after their start; a kept model's load fails only when the worker answered without it or crashed three times in a row; `prepareModels(_:keepLoaded:reloadingKept:)` is the single protocol requirement.

## The kept model's one rule and low disk space

The user chose "Option 1: keep the live model in memory while live transcript is on, plus the low-disk message" (25 October 2026).

1. **One rule.** On Macs with more than 8 GiB, whisper-small stays loaded in the worker while the live transcript is on, also during final passes and preparations. Removed: releasing it before a pass, releasing it before preparing another model and loading it last, and reloading it after a pass. After the last pass, the queue unloads the final pass's models in place (`Transcribing.unloadFinalPassModels`) and the worker stays up; on 8 GiB Macs, or after a worker failure, the worker shuts down as before. Kept: the crash reload, the re-download reload flag, real-failure counting, the load at launch, Record taking over a live load in progress, and Record during a pass (cancel, unload the final models, start live on the kept model).
2. **Unload probe.** Load whisper-small, then large-v3 and SpeakerKit, unload them in a live process three times, and compare footprint and system wired memory; restart the worker after a pass only if the memory does not come back.
3. **Low disk space.** `DiskSpace` (20 GB threshold, injectable reading) and `SlowModelLoad` (15 s compile threshold) in `TranscriptionService`. The worker reports a final pass's model loads to the client; a load past the threshold on a low disk sets `slowModelLoadOnLowDisk`, and the meeting's status says "Taking longer: your Mac is low on disk space". The drawer's slow-start text (now after 10 s) names low disk space when the disk is low. Settings shows a warning row while the disk is low, read when Settings opens and when a slow load is seen.
4. **Tests:** the worker keeps the model through a pass and a preparation, reports a pass's loads, and starts live on the kept model after Record during a pass; the queue unloads the final models once after passes in a row and keeps the model through other preparations; the disk rule, the slow-load status, its clearing, the Settings row and the drawer copy.

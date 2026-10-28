---
status: complete
---

# Phase 11: Hardware Validation

## Overview

Validate the live transcript on one Mac with a test build, per `specs/research/audio/hardware_debugging_workflow.md`: the user runs each scenario; the agent reads the unified log, measures the recording files with `Tools/aac_track_report.py`, and records the numbers below. The phase also adds the in-app latency signposts the architecture names, two test-only overrides that let a scenario force a late live start and a low disk, and fixes five mild issues from the final review of the second UI feedback round.

The user does all recording, on a fresh test build.

## Steps

### 1. Review fixes (`TranscriptionService`)

1. `TranscriptionService+Queue.swift` `workerWasInterrupted`: remove `residentLoadFailed = false`. A crash report that arrives after the kept model's third failed load must not start the loads again.
2. `keepModelLoaded(_:)`: when the kept model changes (live turned off, or another model), drop the queued runs that hold only the old model, so no needless compile runs after the recording.
3. `DiskSpace` reading off the main actor: `refreshDiskSpace()` becomes `async` and reads `diskSpace.isLow` in a detached task. Callers (`SettingsViewModel.load`, `RecordingViewModel.checkDiskSpaceForSlowStart`, the slow-load check) await it. The `DiskSpace` comment and `transcriber_worker.md` say the reading includes purgeable space.
4. Record during a pass whose model is still loading: keep the trade-off (the cancel cannot stop a Core ML load; after 5 s the worker is shut down and the live session loads whisper-small in a fresh worker; backfill covers the wait). A comment at the timeout and an exception in `transcriber_worker.md`.
5. Test: a crash during a final pass with the model kept.

### 2. Latency signposts (`LiveTranscriptionService`)

New `LiveLatency.swift` (internal, `@MainActor`), owned by `LiveRecordingSession`:

```swift
final class LiveLatency {
    static let signposter = OSSignposter(subsystem: "net.scosman.biscotti", category: "live.latency")
    func chunkTaken(_ chunk: LiveAudioChunk)       // live chunks only: not backfill, replay or paused
    func updateApplied(_ update: LiveTrackUpdate)  // current generation, after the store applied it
    func rowsDrawn()                               // the drawer drew the rows
    func generationChanged()                       // a restart drops the chunks waiting
    var summary: String
}
struct LatencyHistogram { mutating func record(_: Duration); func percentile(_: Double) -> TimeInterval? }
```

- "Live chunk" interval per live chunk, from the engine taking it to the drawer drawing the update that covers it (`transcribedThrough ≥ end`), with a "Covered" event when that update arrives. An update without rows ends the interval at the update.
- "Update to drawn" interval, from the first update with rows after the last drawing to the next drawing.
- Covered chunks the drawer does not draw within 5 s are dropped (the drawer is closed or off screen). At most 256 chunks wait per track.
- Histograms (10 ms buckets to 10 s): chunk to update, chunk to drawn, update to drawn, and the worker's `decodeMilliseconds`. A `.notice` summary every 5 minutes (that window) and at the session's end (whole session).
- `LiveTranscriptionService.rowsRevision` (incremented when it assigns rows) and `rowsDrawn()`; the drawer calls it on the next main-queue turn after a revision change (`RecordingViewModel.liveRowsDrawn()`).

### 3. Test-only overrides

Two overrides in the test build, read from the launch environment, let a scenario force the slow paths: a delay before every live engine start, to check the slow-start text and catch-up, and the free disk space the app reads, to check the low-disk text and the Settings warning. They stayed in the test build and are not part of the shipped code.

### 4. Docs

- `components/transcriber_worker.md`: the exception to "starts on the kept model with no load", the purgeable-space note, the dropped run on release.
- `components/live_transcription_service.md`: the latency signposts and how to read them.
- `components/live_drawer.md`: the drawn hook.

### 5. Hardware checklist

Run in the phase 11 test build, live transcript on. Results are filled in as each scenario is measured.

| # | Check | Scenario | Pass when | Result |
|---|---|---|---|---|
| H1 | Live start on the kept model | Record | "The live engine runs" within 1 s of "Live transcription starting" | Pass. A: 51 ms (21:15:08.975 → 09.026), first text 1.5 s later; B: 44 ms. Launch loads were warm: whisper-small 1 s, large-v3 2 s. |
| H2 | 10-minute call, built-in speakers and mic | A | Tracks within 0.2 s of each other and of wall time; no new dropped-buffer or ring-overflow lines; no `overflow` gaps | A ran 6:44 (stopped early). mic 403.93 s, system 403.93 s, wall 404.1 s; no overflow gaps; only capture gaps at the route changes. |
| H3 | Route change mid-call (AirPods in and out) | A | Gap fills in the log add up to the missing time; live text continues; a marker only for a lost stretch of 5 s or more that held speech | Recording correct: AirPods in, mic fill 5.20 s, system 0.86 s; out, mic 3.37 + 3.07 s (three VPIO rebuilds in 6 s), system 0.60 + 0.38 s. The live gaps match the fills exactly; the joined stretches (5.8 s and 7.3 s) show markers. Finding: the marker's tooltip says the saved transcript includes the part, which is false for a capture gap. |
| H4 | Low Power Mode during a call | A | Recording unaffected; the live interval doubles in the log while on | Interval 1 → 2 s at 21:21:16; Low Power Mode was still on for B (2 s). Recording unaffected. |
| H5 | Mic echo or bleed | A, S1 | "Others" rows are not split by echoed "You" rows | Pass on S1: none of the 10 "You" rows held words of the clip played through the speakers; 9 were non-speech annotations ("[typing]", "[COUGH]", "[BLANK" …), now filtered (section 6). |
| H6 | In-app latency | S1 | Chunk-to-drawn p95 within 3 s; update-to-drawn p95 under 0.5 s | Pass on S1 (clean 10 min, Low Power Mode off): chunk to update p50 0.84 s, p95 1.74 s; chunk to drawn p50 1.25 s, p95 2.21 s, max 6.13 s (2428); update to drawn p50 0.14 s, p95 0.26 s; worker decode p50 0.46 s, p95 1.11 s. Accuracy against the soak reference (first 600 s, bench scoring): WER 16.7% (1058 counted words), critical words 44 of 52 (84.6%), as the bench (small mixed 15.3% WER on calibration; 84.1% critical words). Scenario A (route changes, Low Power Mode, a video) was slower: chunk to drawn p95 4.01 s, decode p50 0.71 s. |
| H7 | Wired memory | A, D | No step of more than 1 GB in system wired memory not explained by a model load | During A 5.23–5.84 GB, B 5.10–5.94 GB, the final pass of A up to 6.57 GB. One step to 15.9 GB from 21:23:02 to 21:24:18 matches BiscottiLLM (pid 21711, the post-meeting AI enhancements), not live transcription. |
| H8 | Worker crash mid-recording | B | One restart; the replay leaves no hole in the text; no `engineRestart` marker; the kept model loads again after the pass | Pass. Scenario B: kill at 21:25:43.154, new engine 1.35 s later, replayed 31 mic and 27 system chunks, caught up in 3.4 s, 0 gaps; the kept model loaded again at 21:26:22 after the pass. S2 (second test build): kill at 22:07:15.058, generation 2 at 22:07:16.325 on a fresh worker, replayed 3 mic and 13 system chunks, 0 gaps; no visible status change in the drawer, new text within 3 s, nothing missing around the kill. S2 accuracy (val-ib4003-names-negations, first 160 s): WER 13.3% (354 counted words), critical words 20 of 26. |
| H9 | Late start and catch-up | C | "Catching up…" shows; the transcript covers the recording from 0:00 in conversation order; then live | Pass (S3, live start delayed by 75 s): the engine ran at 22:11:01.262, 75 s after Record; "Catching up…" showed in the header and the text filled in from 0:00 in conversation order; the 75 s backlog caught up in 7.3 s (catchingUp 22:11:01.374, live 22:11:08.653); 21 rows, 0 gaps. S4 (20 s delay) caught up in 2.1 s. S3 accuracy (val-es2009a-fast-turns-names, first 175 s): WER 18.1% (216 counted words); critical words 12 of 15, plus 5 names in the last 7 s that the copy, taken before Stop, did not yet hold. A "[ Silence ]" bubble on Others is the annotation defect, fixed in section 6. |
| H10 | Slow-start and low-disk text | C | The low-disk copy at 10 s with a low disk, the plain copy with room; the Settings warning row | Pass. With the free space overridden to 5 GB: the Settings warning row with its text and the ochre triangle; at 0:16 the drawer showed the low-disk text with "Starting" and a spinner. With room (S4): "Preparing the speech model." / "The first time takes a couple of minutes. The transcript will catch up from the start." at 0:17. |
| H11 | Light and dark mode against the mockups | A, C | The user approves | Light mode reviewed in S1 (drawer with the collapse button, collapsed toggle, Return to live, find "1 of 7", the draft label, the final transcript). Dark mode not checked: the system appearance was not changed for the run. Defects found: reopen and find-close parking (fixed, section 6). |
| H12 | Final pass after a purge | any | large-v3 load time in the log; the status line while it runs | Not seen: the compiled models stayed warm all day (whisper-small 1 s, large-v3 1–2 s at each launch), so no final pass recompiled after a purge. Covered by the unit tests of the slow-load status. |
| H13 | 60-minute call | D | No `overflow` gaps; latency does not grow from window to window; tracks aligned | Skipped by the user for time on 25 October 2026 (not failed). The 10-minute S1 showed no lag growth between its two 5-minute windows (chunk to drawn p95 2.20 s, then 2.21 s for the whole session). |

**Confirmation run S5 on the third test build** (22:22:44–22:25:50, `val-ib4003-numbers/mixed.wav` through the speakers): after collapsing and reopening with the list overflowing, the drawer landed at the newest text with no "Return to live"; find "office" showed "1 of 3", and closing it returned to live. No "You" rows and no annotations; the room was quiet, so this does not prove the filter on noise. Chunk to update p50 0.85 s, p95 1.71 s; chunk to drawn p50 1.31 s, p95 2.07 s, max 3.02 s; 15 rows, 0 gaps. Accuracy (first 175 s; the copy was taken before Stop): WER 12.3% (358 counted words), critical words 15 of 17. Files: mic 183.51 s, system 183.59 s.

### 6. Changes from the hardware review (25 October 2026)

Asked for by the user after scenario A and run S1:

1. **Collapse button** in the drawer header, after Copy ("minus", "Hide transcript (⌘T)").
2. **Device-switch marker:** a stretch made only of capture gaps reads "Audio paused while switching devices · 0:07" ("Your microphone or speakers were switching; nothing was recorded here."). A stretch that also holds possibly spoken audio the live path missed keeps "Not transcribed live". `GapCause` on `TranscriptItem.Kind.gap`; `GapStretch.cause` in `TranscriptItemBuilder`.
3. **Reopened drawer lands at the live edge:** `FollowController.listAppeared()` (called when the list's state is created) gives the list `appearanceSettle` (1 s) in which a following list that lands away from the bottom scrolls to the newest item instead of stopping. A stop logs its offsets.
4. **Closing find returns to live** when the drawer was following when find opened (`followsAfterFind`), as the functional spec's "stops following while the search field is open" implies; a reader who was reading back stays put.
5. **Non-speech annotations** are dropped from live decodes (`NonSpeechAnnotations` in `LiveTranscription`, applied in `WhisperKitLiveDecoder.spokenWords`). An opener with no closer within six words or 3 s drops only itself; an annotation open at a decode's end is reported (`LiveDecodeResult.openAnnotationStart`), and streaming holds the settled time before it while catch-up ends its window there. A decode no later one can hear more than reads the opener as stray and keeps the words after it (`wordsWithoutOpener`). Words made only of punctuation or symbols go; combining marks stay. `Packages/Transcription` changed; the recordable `tx_*` steps are already not-run.
6. **Gaps join only gaps of the same reason** in `LiveTranscriptStore`, so a capture gap never takes over a touching pause, overflow or restart gap and turns recorded audio into a device-switch marker.

Decided by the user:

- **Ducking:** other audio is ducked while recording by voice processing at `.min`, set in `abff8de` (June 2026), before this project. The user accepted it on 25 October 2026; no change. Recorded in `specs/research/audio/README.md`.
- **Mic gap on a device switch** (3–5 s per VPIO rebuild): out of scope for this project. A separate fix based on `main` handles AudioCapture's reconnect path.

Open items:

- **Draft-to-final swap parked mid-way** (S1): the draft was at its top, never scrolled, with the "Draft · final transcript in progress" label visible; after the final transcript replaced it (about 22:05), the tab showed the final text from about 1:26 with the tab header scrolled off. The swap is meant to leave a reader at the top there (`draftAnchorTime` is nil while the header shows). The cause was not found cheaply; it needs a repro with the list's scroll offsets logged.
- **Focus ring on the meeting title** during S1, after the find bar opened: unverified. The review used background accessibility presses only, so it may come from them; nothing changed.
- **Catch-up opener at a window's start** (final review, mild): catch-up still drops the words after an opener that sits at a catch-up window's start (`openAnnotationStart <= window.start`) when the speaker stops within 3 s of it. Follow-up: apply the stray reading when `openAnnotationStart <= window.start`, with a two-window catch-up test.
- **Inner words of a real annotation** (final review, mild): the stray reading can let a real annotation's inner words through, such as " Silence" from " [", " Silence", " ]" when the closer is cut past the window end in a decode that uses the stray reading. Follow-up: keep the drop-everything reading for "[", and the stray reading only for "*" and "(".
- **Forced-boundary stray reading** (final review, mild): no session test covers the stray reading at the 30 s forced boundary. Follow-up: add one.

### 7. Manual tests

The recordable `ac_*` and `tx_*` steps stay `not-run` unless the user runs them in ManualTestApp and reports results; only reported results are recorded.

## Tests

- `TranscriptionServiceResidentModelTests.lateCrashReportAfterThreeFailedLoadsDoesNotRetry`
- `TranscriptionServiceResidentModelTests.releasingTheKeptModelDropsItsQueuedLoad`
- `TranscriptionServiceResidentModelTests.crashDuringAPassWithTheModelKeptRestartsAndReloads`
- `TranscriptionServiceResidentModelTests.recordDuringAPassThatDoesNotStopShutsTheWorkerDown`
- `TranscriptionServiceDiskSpaceTests.diskIsReadOffTheMainThread`; `refreshFollowsTheDisk` becomes async
- `LiveLatencyTests`: `chunkToUpdateCountsFromTakenToTheCoveringUpdate`, `chunkToDrawnWaitsForTheDrawing`, `updateWithoutRowsEndsTheChunkAtTheUpdate`, `undrawnChunksExpire`, `generationChangeDropsWaitingChunks`, `waitingChunksAreBounded`, `summaryReportsPercentiles`, `histogramPercentiles`
- `LiveTranscriptionServiceTests.drawnRowsReachTheSessionsLatency`: only live chunks are measured, and a drawing after a revision records it
- `TranscriptItemBuilderTests.deviceSwitchStretchGetsItsOwnMarker`, `stretchMixingDeviceSwitchAndMissedAudioIsNotTranscribedLive`; `BubbleRowEquatableTests.deviceSwitchMarkerCopy`
- `FollowControllerTests.closingFindReturnsToLiveWhenItWasFollowing`, `closingFindKeepsReadingBack`, `layoutRightAfterAppearingKeepsFollowing`, `scrollingUpAfterTheSettleStopsFollowing`
- `NonSpeechAnnotationsTests`: annotations go and words stay; an open annotation at the end is reported; a split annotation, and "[ Silence ]", goes whole; a stray opener takes only itself; punctuation and symbol words go; numbers, currency and combining marks stay; the decoder applies it
- `WhisperLiveSessionSilenceTests.openAnnotationHoldsTheSettledTime`, `strayOpenerBeforeSilenceKeepsTheWordsAfterIt`, `strayOpenerAtStopKeepsTheWordsAfterIt`; `WhisperLiveSessionCatchUpTests.openAnnotationInCatchUpIsDecodedAgain`, `strayOpenerBeforeAGapKeepsTheWordsAfterIt`; `NonSpeechAnnotationsTests.openAnnotationOffersTheStrayReading`
- `LiveTranscriptStoreTests.captureGapsJoinOnlyCaptureGaps`
- `FollowControllerTests.revealDuringFindKeepsItsPlace`

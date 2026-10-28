---
status: complete
---

# Phase 6: Live Audio Branch in AudioCapture

## Overview

Give `AudioRecorder` an optional live tap: a pair of bounded, lock-free queues that receive a copy of every block each track writes to its AAC file, timed on the recording timeline (t = 0 is the first mic frame in the file). The writers also report the gaps they fill and the system track's leading silence, so the live timeline matches the files frame for frame. `AudioRecorder` exposes `timelineOffset` so note times can be placed on that timeline. Nothing drains the queues yet; phase 8's pump does. What the writers put in the AAC files does not change, and a recording-safety test proves it for both tracks. All changes are in `Packages/AudioCapture`, so the recordable `ac_*` manual-test steps become `not-run`.

## Steps

1. **Queue types** (`Sources/AudioCapture/LiveAudioQueue.swift`, new):
   - `public enum LiveAudioGapKind: Sendable, Equatable { case notStarted, captureGap, overflow }`.
   - `public struct LiveAudioBlock` with `startTime`, `kind` and a public `init(startTime:kind:)` (so phase 8 can build blocks for pump tests). `Kind`: `.samples(UnsafeBufferPointer<Float>, sampleRate:, channelCount:)` (interleaved, valid only inside the drain callback), `.gap(duration:kind:)`, `.end`.
   - `public final class LiveAudioQueue: @unchecked Sendable`, `init(slotCount: Int = 128, slotCapacityFloats: Int = 8192)`:
     - Preallocated sample memory (`slotCount × slotCapacityFloats` Floats) and slot headers (`startTime` plus samples or gap content). Monotonic `published`/`consumed` counters (`Atomic<Int>`, release/acquire); slot index is `counter % slotCount`, so all slots are usable.
     - Producer (internal, never allocates, locks or logs): `pushSamples(_:frameCount:sampleRate:channelCount:startTime:)` splits a block at frame boundaries across `ceil(frames / (slotCapacityFloats / channelCount))` slots with continuous start times and publishes them together; `pushGap(startTime:duration:kind:)`. A push that does not fit is dropped whole and its time joins a pending overflow (start of the first dropped block, summed duration). The next push that fits for itself plus one slot is preceded by one `.gap(kind: .overflow)`. Pushes after `close()` are ignored.
     - `close()` (internal): records the close time (end of the last block pushed or dropped) and sets an atomic closed flag. It needs no slot.
     - `public func drain(_:)` (consumer only): reads the closed flag, then the published counter, hands each slot to the callback and advances `consumed` only after the callback returns. Once closed and empty, it emits any pending overflow as a final `.overflow` gap, then `.end` at the close time, once.
     - `public private(set) var droppedDuration` (consumer only): the sum of the `.overflow` gaps drained.
   - `public final class LiveAudioTap: Sendable { public let mic, system: LiveAudioQueue; public init() }`.

2. **Frame-exact written time** (`Sources/AudioCapture/AudioFrameCount.swift`): `struct WrittenTimeline` with `seconds` and `mutating advance(frames:sampleRate:)`. It counts integer frames per sample-rate segment and starts a new segment when the rate changes, so times stay frame-exact and continuous across a reconnect at a new rate. Both writers use it for the spec's `liveWrittenFrames` / `liveWrittenSeconds`.

3. **Engine seam** (`CaptureEngine.swift`): `func setLiveQueue(_ queue: LiveAudioQueue?)`, with a no-op default. It applies to the next `start(writingTo:)`.

4. **Mic writer** (`MicCaptureSession.swift`, `LiveMicCaptureEngine.swift`):
   - `MicCaptureSession.init(url:encoder:onFirstBuffer:liveQueue: LiveAudioQueue? = nil)`; the queue is fixed for the session, like `onFirstBuffer`.
   - Writer-thread `liveTimeline: WrittenTimeline` at the processing rate (24 kHz).
   - `fillGapWithSilence`: before writing the silence, `pushGap(startTime: liveTimeline.seconds, duration: frames / rate, kind: .captureGap)`, then advance by the frames.
   - Just before `VPIOBufferHelper.writeBuffer(bufferToWrite, to: file)`: push channel 0 of `bufferToWrite` (`channelCount: 1`) at `liveTimeline.seconds`, then advance. When `convert` returns nil nothing is pushed and the timeline does not move.
   - `LiveMicCaptureEngine` keeps the queue in a `Mutex` (`setLiveQueue`) and passes it to each new session in `start`.

5. **System writer** (`SystemWriteStep.swift`, new; `LiveSystemCaptureEngine.swift`):
   - `final class SystemWriteStep` (writer-thread only) takes over the leading silence, the `SystemGapFillWriter`, the byte-size check and `ExtAudioFileWrite` from `LiveSystemCaptureEngine.processEntry`, unchanged, and adds the live copy:
     - `begin(micAnchorSeconds:systemStartWall:liveQueue:)` for each new file: resets the gap writer, the leading-silence flag, the timeline and `writeError`. Reconnects keep the step.
     - `write(_ entry: AudioRingBuffer.Entry, sampleRate:, to file:)`: leading silence on the first buffer, then `pushGap(startTime: 0, duration: frames / rate, kind: .notStarted)`; the gap fill, then `.captureGap` for the returned frame count; the samples (`entry.data` as interleaved Float32 with `entry.channelCount`) just before `ExtAudioFileWrite`. Each step advances the timeline at the current client rate.
     - `writeError`: the first failed gap fill or buffer write since `begin`.
   - The engine keeps the permission feed, the client-format setup (a failed format still writes and pushes nothing) and the DEBUG heartbeat, calls `writeStep.begin` in `start`, `writeStep.write` per entry, and copies `writeStep.writeError` into `_writeError`. `setLiveQueue` stores the queue for the next `start`.

6. **Recorder** (`AudioRecorder.swift`):
   - `public func start(paths:liveTap:)`; `start(paths:)` calls it with `nil`. It sets both engines' queues (or `nil`) before starting them, and detaches them again if the start fails.
   - `public private(set) var timelineOffset: TimeInterval?`: `startTimestamp − micAnchor` after a successful start; `nil` before, and `nil` when the mic reported no host time (anchor 0).
   - `stop()`: after both engines have stopped (their writers have joined), detach the queues from the engines and close both queues of the tap.

7. **Manual-test staleness**: set `"status": "not-run"` for every recordable `ac_*` step in `ManualTestApp/Results/manual_test_results.json` (the file holds no `.instruction` steps).

## Tests

Shared support: `LiveAudioTestSupport.swift` (a value copy of drained blocks, `drainAll()`, a continuity check); the private system-file context in `SystemGapFillTests` moves to a shared `SystemTestFile` with channel count and mid-stream client-rate changes.

`LiveAudioQueueTests`:
- `pushThenDrainPreservesOrderAndTimes`: samples and gaps come out in order with their times, rates, channel counts and values.
- `blockLargerThanSlotIsSplitWithContinuousTimes`: mono and stereo blocks larger than a slot split at frame boundaries with continuous times and the original samples.
- `overflowDropsNewestAndEmitsOneGapBeforeNextBlock`: a full queue keeps the oldest blocks; two dropped blocks become one `.overflow` gap at the first one's start, before the next block.
- `overflowGapDurationEqualsDroppedDuration`: dropped samples and a dropped gap add up to the gap's duration and to `droppedDuration`.
- `blockNeedingMoreSlotsThanFreeIsDroppedWhole`: a split block that does not fit is dropped whole, and a pending overflow waits for room for itself and the next block.
- `closeIsSeenEvenWhenQueueIsFull`: closing a full queue drains every block, then `.end` at the end of the last block.
- `pendingOverflowIsEmittedBeforeEnd`: drops at the end of input come out as one `.overflow` gap before `.end`.
- `slotMemoryValidUntilCallbackReturns`: a push made from inside the drain callback of a full queue is dropped, and the slot being read is unchanged.
- `endIsDrainedOnceAndLaterPushesAreIgnored`.

`WrittenTimelineTests` (in `AudioFrameCountTests.swift`):
- `timesAreFrameExact` and `rateChangeContinuesFromTheWrittenEnd`.

`MicCaptureLiveCopyTests` (real AAC files, decoded):
- `liveCopyCarriesTheSamplesWrittenToFile`: 24 kHz tone in; the live samples equal the input exactly and the decoded file is the same tone.
- `liveCopyFrom48kInputIs24kWithFrameExactTimes`: every block is 24 kHz mono, its start is the frames written before it / 24 000, and the total matches the file's length.
- `liveCopyReportsGapFillAtTheRightTime`: a 500 ms gap on the 48 kHz path becomes one `.captureGap` of 0.5 s at the written position, and the next block starts after it.
- `oddBufferSizesKeepTimelineContinuous`: 441-frame 4-channel 48 kHz buffers give a continuous, clean 400 Hz live copy.
- `fullLiveQueueNeverChangesTheFile`: a two-slot queue that is never drained overflows, and the decoded file is identical to one written without a queue.

`SystemWriteStepTests` (real ADTS files, interleaved Float32 client format):
- `leadingSilenceIsNotStartedGapAtZero`: a system start 1.5 s after the mic anchor gives `.notStarted` 1.5 s at 0, then samples at 1.5 s; the file length includes it.
- `gapFillEmitsCaptureGap`: a 2 s host-time gap gives `.captureGap` 2 s at the written position.
- `rateChangeOnReconnectKeepsTimelineContinuous`: 48 kHz, then a 0.5 s reconnect gap and 44.1 kHz; the gap and the new blocks start where the written time ends.
- `twoChannelTapIsPassedInterleaved`: a stereo tap reaches the queue unchanged, interleaved, with `channelCount` 2.

`AudioRecorderLiveTapTests` (fakes):
- `liveTapIsSetOnBothEnginesBeforeStart`.
- `timelineOffsetIsStartTimestampMinusMicAnchor` (and `nil` before start).
- `timelineOffsetIsNilWithoutAMicAnchor`.
- `startWithoutLiveTapBehavesAsToday`: no queue reaches either engine; capture starts and stops as before.
- `stopClosesAndDetachesTheLiveTap`: both queues drain `.end` after stop, and neither engine keeps a queue.
- `failedStartDetachesTheLiveTap`.

`LiveBranchSafetyTests` (real writers and files), parameterized over a queue drained by another thread while writing and a two-slot queue that is never drained: the same scripted input with and without a tap gives identical decoded samples for the mic track (48 → 24 kHz converter path, 441-frame 4-channel buffers, a 700 ms gap) and the system track (48 kHz client format into the 24 kHz file, a 1.5 s late start, a 1 s gap). The drained copy is continuous on both tracks.

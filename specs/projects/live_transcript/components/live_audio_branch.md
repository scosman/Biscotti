---
status: complete
---

# Component: Live Audio Branch

## Purpose and scope

Copy each track's audio, as written to the AAC file, into a bounded queue that the live transcription service drains. Report gap fills and leading silence so the live timeline matches the file. Expose the offset between note times and the recording timeline.

Not in scope: resampling to 16 kHz, levels and gap detection for the live path (the pump in [live_transcription_service](live_transcription_service.md) does those), and any change to how the AAC files are written.

## Public interface (AudioCapture)

```swift
/// Why a stretch of the live timeline has no samples.
public enum LiveAudioGapKind: Sendable, Equatable {
    case notStarted     // system track's leading silence; not shown as missed
    case captureGap     // the writer filled a capture gap with silence
    case overflow       // the live queue was full; samples were dropped
}

/// One block drained from a queue. `samples` is valid only inside the drain callback.
public struct LiveAudioBlock {
    public enum Kind {
        case samples(UnsafeBufferPointer<Float>, sampleRate: Double, channelCount: Int)  // interleaved
        case gap(duration: TimeInterval, kind: LiveAudioGapKind)
        case end
    }
    public let startTime: TimeInterval   // recording timeline
    public let kind: Kind
}

/// Single-producer (writer thread), single-consumer (pump thread) queue.
public final class LiveAudioQueue: @unchecked Sendable {
    public init(slotCount: Int = 128, slotCapacityFloats: Int = 8192)
    public func drain(_ body: (LiveAudioBlock) -> Void)    // consumer only; ends with .end once closed and empty
    public var droppedDuration: TimeInterval { get }        // consumer only
}

/// The pair of queues a recording feeds.
public final class LiveAudioTap: Sendable {
    public let mic: LiveAudioQueue
    public let system: LiveAudioQueue
    public init()
}

extension AudioRecorder {
    public func start(paths: CapturePaths, liveTap: LiveAudioTap?) async throws  // existing start(paths:) calls this with nil
    public var timelineOffset: TimeInterval? { get }  // startTimestamp − micAnchorSeconds; nil before start completes
}
```

Internal additions:

- `CaptureEngine` gains `func setLiveQueue(_ queue: LiveAudioQueue?)` with a default no-op, so fakes and tests compile unchanged. `AudioRecorder.start` calls it on both engines before `start(writingTo:)`.
- `LiveAudioQueue` has internal producer methods: `pushSamples(_:frameCount:sampleRate:channelCount:startTime:)`, `pushGap(startTime:duration:kind:)` and `close(at:)`. They never allocate, lock or log.

## Internal design

### Queue

- 128 preallocated slots of 8,192 Floats each (4 MB per track). A slot holds one block. A writer buffer larger than a slot is split across consecutive slots.
- Head and tail are atomics (`Synchronization.Atomic<Int>`, acquire/release), following `AudioRingBuffer`'s pattern. Unlike `AudioRingBuffer.dequeue`, the consumer advances the tail only after the drain callback returns, so slot memory stays valid while it is read.
- **Overflow:** when no slot is free, the producer drops the block and adds its duration to a pending-overflow counter. The next successful push is preceded by a `.gap(kind: .overflow)` block covering the dropped time. The producer never waits.
- **Closing never needs a slot:** `close(at:)` sets an atomic closed flag and the close time after the writer's final drain. The consumer emits any pending overflow as a final `.overflow` gap, then `.end` once the queue is closed and empty, so a full queue can never hide the end of input.

### Mic writer (`MicCaptureSession.processEntry`)

- A new `liveWrittenFrames: Int64` counts frames written to the file at 24 kHz, including gap fills.
- In `fillGapWithSilence`, before writing the silence: `pushGap(startTime: liveWrittenFrames / 24000, duration: frames / 24000, kind: .captureGap)`, then add the frames.
- Once `VPIOBufferHelper.writeBuffer(bufferToWrite, to: file)` succeeds: `pushSamples(bufferToWrite.floatChannelData![0], frameCount:, sampleRate: 24000, channelCount: 1, startTime: liveWrittenFrames / 24000)`, then add the frames. A failed write pushes nothing and leaves the counter, so the live copy never carries audio the file lacks. The converter output is a fresh buffer each call, so reading it is safe.
- When `convert` returns nil, nothing is pushed and the counter is unchanged, matching the file.

### System writer (`LiveSystemCaptureEngine.processEntry`)

The write step is extracted into an internal `SystemWriteStep` struct (leading silence, gap fill, write, live copy) so it can be unit-tested against a real ADTS file, like `SystemGapFillWriter`.

- A new `liveWrittenSeconds: Double` accumulates written duration at the current client rate, so a rate change on reconnect keeps the timeline continuous.
- Leading silence: `pushGap(startTime: 0, duration: leadingSeconds, kind: .notStarted)`.
- Gap fill: `gapFillWriter.processBuffer` already returns the filled frame count; push `.captureGap` for it.
- Samples: push `entry.data` with `tapSampleRate` and `entry.channelCount` (interleaved Float32) once `ExtAudioFileWrite` succeeds. A failed write pushes nothing and leaves the timeline where it was.
- If the client format failed, nothing is written and nothing is pushed.

### Timeline offset

`AudioRecorder` keeps the mic anchor (host seconds) it already passes to `setMicAnchor`, and after start sets `timelineOffset = startTimestamp − micAnchorSeconds` (both on the mach clock). `RecordingController` copies it into `RecordingState.timelineOffset` for the UI.

## Rules this component follows

- Callbacks and writers do no allocation, blocking locks or per-buffer logging after start (`MicCaptureSession.swift:9-15`).
- Durations come from frame counts, never from converter output (`hardware_debugging_workflow.md:125`).
- The live copy never changes what is written to the AAC files.

## Dependencies

- Depends on: Foundation, Synchronization, AVFoundation (existing).
- Used by: `LiveTranscriptionService` (drains the queues), `RecordingController` (passes the tap, reads the offset).

## Test plan

`LiveAudioQueueTests`:
- `pushThenDrainPreservesOrderAndTimes`
- `blockLargerThanSlotIsSplitWithContinuousTimes`
- `overflowDropsNewestAndEmitsOneGapBeforeNextBlock`
- `overflowGapDurationEqualsDroppedDuration`
- `closeIsSeenEvenWhenQueueIsFull`
- `pendingOverflowIsEmittedBeforeEnd`
- `slotMemoryValidUntilCallbackReturns`

`MicCaptureSessionTests` (real AAC files, decoded):
- `liveCopyCarriesTheSamplesWrittenToFile` (tone in, same tone in the live blocks)
- `liveCopyFrom48kInputIs24kWithFrameExactTimes`
- `liveCopyReportsGapFillAtTheRightTime` (500 ms gap)
- `oddBufferSizesKeepTimelineContinuous` (441-frame buffers)
- `fullLiveQueueNeverChangesTheFile` (tiny queue; file duration and content unchanged)

`SystemWriteStepTests` (real ADTS files, interleaved Float32 client format):
- `leadingSilenceIsNotStartedGapAtZero` (system starts 1.5 s late)
- `gapFillEmitsCaptureGap`
- `rateChangeOnReconnectKeepsTimelineContinuous` (48 kHz then 44.1 kHz)
- `twoChannelTapIsPassedInterleaved`

`AudioRecorderTests` (fakes):
- `liveTapIsSetOnBothEnginesBeforeStart`
- `timelineOffsetIsStartTimestampMinusMicAnchor`
- `startWithoutLiveTapBehavesAsToday`

Recording-safety gate (`LiveBranchSafetyTests`, real writers and files): the same scripted input with and without a live tap produces decoded AAC samples that are identical, for both tracks, including a gap, a late system start and a 48 → 24 kHz path.

## Hardware checks

Run in a test build with live transcription on, reading the unified log and measuring files with `Tools/aac_track_report.py`, per `specs/research/audio/hardware_debugging_workflow.md`:

1. A 10-minute call on built-in speakers and mic: both tracks' durations match within today's tolerance; no new dropped-buffer warnings.
2. Connect AirPods mid-call: the route change shows as a live gap, the recording keeps both tracks.
3. A 60-minute call: no `overflow` gaps in the log at the chosen update interval.
4. Low Power Mode on during a call: recording unaffected.

Changing this package marks the `ac_*` manual tests not-run.

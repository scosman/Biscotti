---
status: complete
---

# Phase 2: Post-processing queue

## Overview

Introduces `PostProcessingQueue`, an app-wide serial FIFO that sequences heavy post-recording work (transcribe then AI auto-enhancements). `stopRecording` and the existing test seam migrate onto it. MeetingDetailUI gains Retry and Re-transcribe enqueue calls, the "Waiting to transcribe..." display state, pipeline stage support for queued meetings, and a `canReTranscribe` guard against active queue entries. Deletion drops waiting entries from the queue.

## Steps

### PostProcessingQueue (new file)

1. **`AppCore/PostProcessingQueue.swift`** -- new `@MainActor @Observable` class per architecture section 4. `Kind` enum (`.transcribe`, `.reTranscribe`), `Entry` struct, `waiting` array, `running` optional, `enqueue`, `remove`, `isWaiting`, `isActive`, `awaitIdle`. Runner is an injected async closure. Worker loops FIFO.

### AppCore integration

2. **`AppCore.swift`** -- add `public let postProcessing: PostProcessingQueue` property. Build it in `init` with a runner closure that calls `transcription.transcribe`/`reTranscribe` then `intelligence.runAutoEnhancements`. Replace `pendingTranscriptionTask` usage in `stopRecording` with `postProcessing.enqueue(meetingID, kind: .transcribe)`. Reimplement `awaitPendingTranscription()` as `await postProcessing.awaitIdle()`. Delete `pendingTranscriptionTask`.

3. **`AppCore.swift`** -- add `enqueueTranscription(meetingID:)` and `enqueueReTranscription(meetingID:)` public methods.

4. **`AppCore.swift` (delete)** -- in `deleteSingleMeetingInternal`, call `postProcessing.remove(meetingID)` before file/DB deletion.

### MeetingDetailUI changes

5. **`MeetingDetailViewModel.swift`** -- change `reTranscribe()` to call `core.enqueueReTranscription(meetingID:)`. Change `retry()` to call `core.enqueueTranscription(meetingID:)`. Both become sync (or effectively sync calls).

6. **`MeetingDetailViewModel.swift`** -- add `isQueued` computed property: `core.postProcessing.isWaiting(meetingID)`.

7. **`MeetingDetailViewModel.swift` (displayState)** -- insert a check after `.downloadingModel`/`.transcribing` cases: if `isQueued`, return `.processing(message: "Waiting to transcribe\u{2026}")`.

8. **`MeetingDetailViewModel.swift` (canReTranscribe)** -- also return `false` when `core.postProcessing.isActive(meetingID)`.

9. **`MeetingDetailViewModel.swift` (pipelineStages)** -- treat `isQueued` as pipeline-visible. When queued, stage 1 is `PipelineStage(label: "Waiting to transcribe", state: .pending)`, gated later stages are `.pending`.

### Tests

## Tests

### PostProcessingQueue tests (`AppCoreTests/PostProcessingQueueTests.swift`)
- `enqueue_runsInFIFOOrder`: three enqueues, runner records order as [a, b, c].
- `enqueue_duplicateWhileWaiting_isNoOp`: enqueue same id twice while waiting, only one run.
- `enqueue_duplicateWhileRunning_isNoOp`: enqueue while the id is running, no second run.
- `remove_dropsWaitingEntry_notRunning`: remove a waiting entry, it never runs.
- `isWaiting_trueOnlyBeforeStart`: gated runner, check isWaiting transitions.
- `runnerFailure_doesNotStopQueue`: first runner throws, second still runs.

### AppCore queue integration tests (`AppCoreTests/AppCoreTests.swift` additions)
- `stopRecording_enqueuesTranscribe`: record, stop, verify FakeTranscriber called via queue.
- `twoMeetings_bothTranscribe_noAlreadyInProgressFailure`: enqueue two, both complete.
- `deleteQueuedMeeting_removesWaitingEntry`: enqueue, delete before it runs, verify not transcribed.

### MeetingDetailUI tests (`MeetingDetailUITests/`)
- `displayState_queued_showsWaitingToTranscribe`.
- `canReTranscribe_falseWhileQueued`.
- `pipelineStages_queued_firstStageWaiting`.
- `retry_enqueuesTranscribeKind`.
- `reTranscribe_enqueuesReTranscribeKind`.

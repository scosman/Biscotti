---
status: complete
---

# Phase 3: Transcription Download Cancel (Best-Effort)

## Overview

Add the ability to cancel an in-flight transcription model download. For the
`.hosted` backend (real app), cancel works by tearing down the XPC connection
via `shutdown()` which kills the worker process and its in-flight download,
then deleting partial model files via `ModelStorage.clearCache()`. For
`.inProcess` (CLI/tests), we rely on Task cancellation + cache cleanup.

The `Transcribing` seam gains a `cancelModelDownload()` method so
`TranscriptionService` can forward cancellation. `OnboardingViewModel` retains
the transcription download Task so it can be cancelled, and gains a
`cancelTranscriptionDownload()` action. The onboarding transcription row gains
a Cancel control below its progress spinner.

Finally, mark `tx_*` manual tests as `not-run` per the staleness rule since
this phase touches `Packages/Transcription`.

## Steps

1. **Add `cancelModelDownload()` to `Transcriber`** (`Packages/Transcription/Sources/Transcription/Transcriber.swift`)
   - New public method: `public func cancelModelDownload() async`
   - For `.hosted`: calls `shutdown()` (invalidates XPC connection, kills worker),
     then `try? ModelStorage.clearCache()`, then `emitStatus(.needsDownload)`.
   - For `.inProcess`: calls `try? ModelStorage.clearCache()`, then
     `emitStatus(.needsDownload)`. (Caller cancels the Task; in-process has no
     worker to kill.)

2. **Add `cancelModelDownload()` to `Transcribing` seam** (`Packages/BiscottiKit/Sources/TranscriptionService/Transcribing.swift`)
   - Add `func cancelModelDownload() async` to the protocol.

3. **Add `cancelModelDownload()` to `FakeTranscriber`** (`Packages/BiscottiKit/Tests/BiscottiTestSupport/FakeTranscriber.swift`)
   - Add `cancelModelDownloadCalled` and `cancelModelDownloadCallCount` to `Backing`.
   - Implement the protocol method, recording the call.

4. **Add `cancelModelDownload()` to `TranscriptionService`** (`Packages/BiscottiKit/Sources/TranscriptionService/TranscriptionService.swift`)
   - New public method that forwards to `engine.cancelModelDownload()`.

5. **Make `startTranscriptionDownload()` synchronous + retained** (`Packages/BiscottiKit/Sources/OnboardingUI/OnboardingViewModel.swift`)
   - Add `private var transcriptionDownloadTask: Task<Void, Never>?`
   - Add `private var transcriptionCancelled = false`
   - Change `startTranscriptionDownload()` from `async` to synchronous:
     runs the disk check, then creates a retained Task that calls a new
     `runTranscriptionDownload()` async method (the old body), with
     `defer { self?.transcriptionDownloadTask = nil }`.
   - `runTranscriptionDownload()`: the old `startTranscriptionDownload` body,
     with `catch` guarded by `!transcriptionCancelled` (so cancel doesn't
     show failure), and success path guarded by `!transcriptionCancelled`
     (so cancel wins race against completion).

6. **Add `cancelTranscriptionDownload()`** (`OnboardingViewModel.swift`)
   - Guard on `isDownloading`.
   - Set `transcriptionCancelled = true`.
   - Cancel the retained task.
   - Fire a new Task that awaits `core.transcription.cancelModelDownload()`
     (kills worker + clears files), then resets state:
     `isDownloading = false`, `downloadStatus = nil`,
     `downloadComplete = false`, `downloadFailed = false`.

7. **Wire Cancel into onboarding transcription row** (`Packages/BiscottiKit/Sources/OnboardingUI/ModelDownloadCard.swift`)
   - Thread `onCancel` from `ModelCard.transcriptionRow` to the
     `ModelDownloadRow`, passing
     `{ viewModel.cancelTranscriptionDownload() }`.

8. **Update `resetForReplay()`** (`OnboardingViewModel.swift`)
   - Cancel any in-flight transcription download task.
   - Reset `transcriptionCancelled`.
   - Nil the task.

9. **Update callers of `startTranscriptionDownload()`**
   - `ModelCard.transcriptionRow` currently wraps the call in
     `Task { await viewModel.startTranscriptionDownload() }`. Since the method
     is now synchronous, remove the `Task`/`await` wrapper.

10. **Mark `tx_*` manual tests as `not-run`** (`ManualTestApp/Results/manual_test_results.json`)
    - Set `"status": "not-run"` and remove `"timestamp"` for all recordable
      `tx_*` steps (those already present in the file).

## Tests

- `Transcriber.cancelModelDownload`: test that after cancel, `currentStatus`
  is `.needsDownload`. (This is implicitly tested through the service/VM tests.)
- `TranscriptionService.cancelModelDownload`: forwards to the engine seam;
  verify `FakeTranscriber.cancelModelDownloadCalled`.
- `OnboardingViewModel.startTranscriptionDownload`: now synchronous, sets
  `isDownloading`, completes normally when not cancelled.
- `OnboardingViewModel.cancelTranscriptionDownload`: calls the engine seam's
  cancel, resets `isDownloading`/`downloadFailed`/`downloadComplete`/
  `downloadStatus`, does not set `downloadFailed` when cancelled.
- `OnboardingViewModel.cancelTranscriptionDownload` is a no-op when not
  downloading.
- `OnboardingViewModel.resetForReplay` cancels in-flight transcription
  download.
- Update existing tests that call `startTranscriptionDownload` with `await`
  to handle the new synchronous signature.

---
status: complete
---

# Phase 2: LLM Download Cancel

## Overview

Add the ability to cancel an in-flight LLM model download. The download Task is
retained in `ModelManager` so it can be cancelled; `ModelDownloader` maps
`NSURLErrorCancelled` to `CancellationError` so a user cancel lands in
`.notDownloaded` (not `.failed`); both Settings and Onboarding surfaces gain a
"Cancel" control below the download progress.

## Steps

1. **Fix `ModelDownloader` cancellation error mapping** (`LocalLLM/ModelDownloader.swift`)
   In `StreamingDownloadDelegate.urlSession(_:task:didCompleteWithError:)`, when
   the error is `NSURLErrorCancelled`, resume the continuation with
   `CancellationError()` instead of wrapping it in `LocalLLMError.downloadFailed`.
   Then in `ModelDownloader.download`'s outer `catch`, check for
   `CancellationError` and `NSURLErrorCancelled` before the generic
   `LocalLLMError.downloadFailed` wrap -- re-throw as `CancellationError()`.

2. **Add task retention + `startDownload`/`cancelDownload` to `ModelManager`**
   (`Intelligence/ModelManager.swift`)
   - Add `private var downloadTasks: [String: Task<Void, Never>] = [:]`
   - Add `public func startDownload(id: String)` that guards on
     `canStartDownload` + not-already-in-`downloadTasks`, creates a retained
     `Task` calling `runDownload(id:)`, stores it.
   - Rename `downloadModel(id:)` to `runDownload(id:)` (keep `public` for
     tests), add `defer { downloadTasks[id] = nil }`.
   - Add `public func cancelDownload(id: String)` that calls
     `downloadTasks[id]?.cancel()`.

3. **Swap VM call sites to `startDownload`**
   - `ManageModelsViewModel.download(id:)`: replace
     `Task { await core.modelManager.downloadModel(id:) }` with
     `core.modelManager.startDownload(id: id)`.
   - `OnboardingViewModel.startLanguageDownload()`: same replacement.

4. **Add `cancel(id:)` to `ManageModelsViewModel`**
   (`ModelManagementUI/ManageModelsSheet.swift`)
   - `public func cancel(id: String)` forwards to
     `core.modelManager.cancelDownload(id: id)`.

5. **Add Cancel button to `ManageModelsSheet` `ModelRowView`**
   - Add `onCancel` closure parameter to `ModelRowView`.
   - In `descriptionOrProgress`'s `.downloading` case, render a small bordered
     "Cancel" button below the progress, calling `onCancel`.
   - Thread `onCancel` from the `ForEach` as
     `{ viewModel.cancel(id: choice.model.id) }`.

6. **Add `cancelLanguageDownload()` to `OnboardingViewModel`**
   (`OnboardingUI/OnboardingViewModel.swift`)
   - `public func cancelLanguageDownload()` that resolves the downloading
     model id and calls `core.modelManager.cancelDownload(id:)`.

7. **Add Cancel control to onboarding `DownloadControl`**
   (`OnboardingUI/ModelDownloadCard.swift`)
   - Add `onCancel: (() -> Void)?` parameter to `DownloadControl`.
   - In `downloadingContent`, render a small bordered "Cancel" button below
     the progress/spinner, calling `onCancel`.
   - Thread `onCancel` through `ModelDownloadRow` and `ModelCard` to the
     language row's `cancelLanguageDownload()`. Transcription row passes
     `nil` for now (Phase 3 adds transcription cancel).

8. **Update `resetForReplay()`** to cancel any in-flight language download
   on reset.

## Tests

- `ModelDownloaderCancellationTests`: cancelled download throws
  `CancellationError` (not `LocalLLMError.downloadFailed`) and leaves no
  `.partial` file. Uses a controllable `URLProtocol` or slow-stream approach
  to cancel mid-flight.
- `ModelManager.startDownload`: retains a task; verify download proceeds.
- `ModelManager.cancelDownload`: cancel an in-flight download -> state becomes
  `.notDownloaded`, task entry cleared, subsequent download startable.
- `ModelManager` one-at-a-time: still holds with `startDownload`.
- `ManageModelsViewModel.cancel(id:)`: forwards to `ModelManager`.
- `ManageModelsViewModel.download(id:)`: still works with `startDownload`.
- `OnboardingViewModel.cancelLanguageDownload`: calls `cancelDownload` on the
  in-flight model id.
- Update existing tests that call `downloadModel` to use `runDownload` where
  needed.

---
status: complete
---

# Implementation Plan: Model Download UX

Three phases. Land Phase 1 first (it introduces the shared disk policy and touches
both surfaces); the two cancel phases are independent and can follow in either order.
Details live in `functional_spec.md`, `ui_design.md`, and `architecture.md` — this is
just the build order.

## Phases

- [x] **Phase 1 — Disk-space pre-check + remove proactive disk states.**
  Shared `DiskWarning` + `ModelDiskPolicy` (2 GB buffer, `warning(...)`, `formatBytes`)
  in `Intelligence`. Promote the transcription size estimate to public
  `TranscriptionDownloadSize.estimatedBytes(method:)` + `TranscriptionService.estimatedModelDownloadBytes`.
  Add `ModelManager.downloadDiskWarning(id:)`. Remove the old proactive disk machinery
  (`ModelSuitability.hasEnoughDisk`, `ModelChoice.hasEnoughDiskToDownload`,
  `ModelBlockedReason.insufficientDisk`, `modelChoices` disk read; onboarding
  `hasSufficientDisk`/`checkDiskSpace`/`requiredDiskSpaceMB`, `ModelRowState.insufficientDisk`,
  `DownloadControl` disk view). Wire the click-time check + `OK`-only alert into both
  surfaces' download actions. (Arch §1, §4, §5.1; ui_design §2.) Tests per arch §8.

- [x] **Phase 2 — LLM download cancel.**
  Retain the download `Task` in `ModelManager` (`startDownload`/`cancelDownload`,
  `runDownload` core, `defer` cleanup); swap VM call sites from fire-and-forget to
  `startDownload`. Map `NSURLErrorCancelled`/`CancellationError` → `CancellationError`
  in `ModelDownloader` (still deleting `.partial`) so cancel lands in `.notDownloaded`,
  not `.failed`. Add the "Cancel" control (below progress) to `ManageModelsSheet` and
  the onboarding language row. (Arch §2, §5.) Tests per arch §8.

- [x] **Phase 3 — Transcription download cancel (best-effort).**
  Add `Transcriber.cancelModelDownload()` (hosted: `shutdown()` → kill worker, then
  `ModelStorage.clearCache()`, emit `.needsDownload`), thread through the `Transcribing`
  seam + `TranscriptionService.cancelModelDownload()`. Make `OnboardingViewModel.startTranscriptionDownload()`
  synchronous + retained; add `cancelTranscriptionDownload()` + `transcriptionCancelled`
  guard. Add the "Cancel" control to the onboarding transcription row. (Arch §3, §5.)
  Tests per arch §8. Mark `tx_*` manual tests `not-run` (manual-test staleness rule);
  on-hardware verification of clean cancel + no leftover partials.

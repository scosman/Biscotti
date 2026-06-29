---
status: complete
---

# Phase 1: Disk-space pre-check + remove proactive disk states

## Overview

Replace the fragmented proactive disk-blocking machinery (three inconsistent
checks across Settings, Onboarding, and Transcription) with a single
click-time check + OK-only alert. Add shared `DiskWarning` + `ModelDiskPolicy`
in Intelligence. Promote the transcription size estimate to a public API.
Wire the click-time check into both Settings and Onboarding download actions.
Remove all proactive disk states (inline warnings, disabled buttons, row states).

## Steps

1. **Create `Intelligence/DiskWarning.swift`** -- new file with:
   - `DiskWarning` struct (modelName, requiredBytes, availableBytes)
   - `ModelDiskPolicy` enum with `downloadBufferBytes` (2 GB),
     `warning(modelName:downloadBytes:freeBytes:)`, and `formatBytes(_:)`

2. **Add `ModelManager.downloadDiskWarning(id:)`** -- click-time check
   using `ModelDiskPolicy.warning` with the model's `approxDownloadBytes`
   and `hardware.availableDiskBytes`.

3. **Promote transcription download size** -- add public
   `TranscriptionDownloadSize.estimatedBytes(method:)` in the Transcription
   package. Add `TranscriptionService.estimatedModelDownloadBytes` that
   delegates to it.

4. **Remove `ModelSuitability.hasEnoughDisk`** and all callers:
   - Remove `ModelChoice.hasEnoughDiskToDownload` and
     `ModelBlockedReason.insufficientDisk`
   - `blockedReason` computes from RAM only
   - `modelChoices()` drops the `freeBytes` read + `hasEnoughDisk` call
   - `canStartDownload` drops the disk check (the click-time warning
     replaces it; the download-time failure is the backstop)

5. **Remove onboarding proactive disk states:**
   - Remove `ModelRowState.insufficientDisk` enum case
   - Remove `DownloadControl.diskWarning` view (`.insufficientDisk` case)
   - Remove `transcriptionInsufficientDisk` computed property
   - Remove `hasSufficientDisk`, `requiredDiskSpaceMB`, `checkDiskSpace()`
     from `OnboardingViewModel`
   - Remove `checkDiskSpace()` call from `runModelProbes()`
   - Remove disk-block branch from `languageRowState()`
   - Remove `.insufficientDisk` from `transcriptionRowState()`

6. **Wire click-time disk check into `ManageModelsViewModel`:**
   - Add `var diskWarning: DiskWarning?`
   - `download(id:)` calls `downloadDiskWarning` first; sets warning and
     returns without starting on failure

7. **Wire click-time disk check into `OnboardingViewModel`:**
   - Add `var diskWarning: DiskWarning?`
   - `startLanguageDownload()` checks via `downloadDiskWarning`
   - `startTranscriptionDownload()` checks via `ModelDiskPolicy.warning`
     using `estimatedModelDownloadBytes` + `availableDiskBytes()`

8. **Add disk-warning alerts to UI surfaces:**
   - `ManageModelsSheet`: `.alert` bound to VM's `diskWarning`
   - `OnboardingStepViews.modelDownloadStep`: `.alert` bound to VM's `diskWarning`

9. **Remove `.insufficientDisk` from `ManageModelsSheet`:**
   - Download button no longer `.disabled` on insufficientDisk
   - Remove `warningLabel(for: .insufficientDisk)` path in `descriptionOrProgress`
   - Remove `.insufficientDisk` from `ModelBlockedReason.warningText`

10. **Update `resetForReplay()`** -- clear `diskWarning`, remove
    `hasSufficientDisk = true`

## Tests

- `ModelDiskPolicyTests`: `warning` below/at/above threshold (incl. +2 GB
  buffer boundary), nil freeBytes -> nil; `formatBytes` whole/fractional GB
- `ModelManager.downloadDiskWarning`: returns warning when disk low, nil
  when ample, nil when model not found
- `TranscriptionDownloadSize.estimatedBytes`: returns expected values per
  model variant
- `TranscriptionService.estimatedModelDownloadBytes`: delegates correctly
- `ManageModelsViewModel`: `download(id:)` with low disk sets `diskWarning`
  and does not start; normal download proceeds when disk OK
- `OnboardingViewModel`: `startTranscriptionDownload` with low disk sets
  `diskWarning` and does not start; `startLanguageDownload` with low disk
  sets `diskWarning`; language row state no longer shows `.insufficientDisk`
- Update existing tests that reference removed disk states
  (`hasEnoughDiskToDownload`, `.insufficientDisk`, `hasSufficientDisk`,
  `checkDiskSpace`, etc.)

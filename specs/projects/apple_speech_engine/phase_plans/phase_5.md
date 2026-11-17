---
status: complete
---

# Phase 5: Onboarding

## Overview

Transform the onboarding "Download Local AI Models" step from a 2-row card (Transcription & Speaker ID combined, Language Model) to a 3-row card (Transcription, Speaker ID, Language Model). Wire the Transcription row to `SpeechEngineManager` for engine-aware state, add the "See all options" link to the Speech to Text Model sheet, update `ModelRowState.ready` to carry an optional caption, update `RecommendationLine` to drop the "Recommended" prefix and support hiding the link, and change the footer to require all three rows started.

## Steps

1. **Update `ModelRowState.ready`** to `ready(caption: String?)`. Update `DownloadControl` to render the optional caption beneath `GrantedTag`. Update all existing references (tests, VM code) from `.ready` to `.ready(caption: nil)`.

2. **Update `RecommendationLine`**: remove `isRecommended` parameter (drop "Recommended ·" prefix entirely); add `showsSeeAll: Bool = true` to conditionally hide the link.

3. **Add transcription row-state derivation to `OnboardingViewModel`**: new `transcriptionRowState()` that reads from `core.speechEngines` (target, apple/whisper download state, availability). New `speakerIDRowState()` for the speaker ID row. New `startTranscriptionDownload()` and `startSpeakerIDDownload()` that delegate to `core.speechEngines.download(target)` and `core.speechEngines.downloadSpeakerID()`. Add `showSpeechSheet`, `transcriptionLineText`, `showsSpeechOptionsLink`.

4. **Rewrite derivation properties**: replace `bothModelsStarted`/`bothModelsReady` with `allModelsStarted`/`allModelsReady` (3 of 3). Add `speakerIDReady`, `speakerIDStarted`, `transcriptionStarted` (from engines), `transcriptionReady` (from engines). Update `footerButton` and `footerCaption` to use `allModelsStarted`/`allModelsReady`.

5. **Remove stale VM state**: remove `downloadStatus`, `isDownloading`, `downloadComplete`, `downloadFailed`, `transcriptionDownloaded`, `requiredDiskSpaceMB`, `checkDiskSpace`, `hasSufficientDisk` from the VM (state lives in `SpeechEngineManager`). Clean up `runModelProbes()` to call `core.speechEngines.refresh()`. Update `resetForReplay()`.

6. **Update `ModelCard`** to 3 rows: Transcription, Speaker ID, Language Model with `InsetDivider(leadingInset: 48)` between each. Transcription row extra content: `RecommendationLine` with `showsSeeAll`. Speaker ID row: no extra content. Language Model row: `RecommendationLine` without "Recommended ·" prefix (already done by step 2).

7. **Update `modelDownloadStep`** in `OnboardingStepViews.swift`: add `.sheet(isPresented: $viewModel.showSpeechSheet)` for the Speech to Text Model sheet.

8. **Wire `advance()` to persist target**: when `currentStep == .modelDownload`, call `await core.speechEngines.persistTargetIfUnset()` before `proceed()`.

9. **Update all existing tests** to use `.ready(caption: nil)` and `allModelsStarted`. Write new tests for the 3-row model.

## Tests

- `OnboardingModelRowStateTests` (extend): transcription row for each target state including `.ready(caption: "Built in")` for Apple ready, "System download"/"626 MB" captions for idle states; speaker ID row states (idle "~11 MB", downloading indeterminate, ready, failed).
- `OnboardingFooterButtonTests` (extend): Continue requires all three started (transcription + speaker ID + language).
- `OnboardingViewModelTests` (extend): Continue persists target when unset; Skip does not; `showsSpeechOptionsLink` hidden when Apple unavailable; `transcriptionLineText` returns the summary label.

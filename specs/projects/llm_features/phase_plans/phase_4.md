---
status: complete
---

# Phase 4: Settings: AI Enhancements + Model Download

## Overview

Add an "AI Enhancements" section to `SettingsView` with two toggles (Summarize Transcripts, Guess Speaker Names) and a conditional model-download row. The toggles are disabled and shown off when no model is downloaded. The download row shows idle/downloading/failed states and disappears once the model is downloaded, at which point the toggles become enabled and reflect their stored defaults. All state flows through `SettingsViewModel` additions that read from `AppCore.intelligence` and persist via `DataStore.updateSettings`.

## Steps

1. **Add `Intelligence` dependency to `SettingsUI` target** in `Package.swift`. The target already imports `AppCore` which has `Intelligence`, but the view/VM need to reference `ModelDownloadState` and `Intelligence` directly.

2. **Add AI settings state + methods to `SettingsViewModel`**:
   - `public private(set) var summarizeTranscripts: Bool = true`
   - `public private(set) var guessSpeakerNames: Bool = true`
   - Computed `var modelDownload: ModelDownloadState` (reads `core.intelligence.download`)
   - Computed `var modelAvailable: Bool` (reads `core.intelligence.isModelDownloaded`)
   - `func setSummarizeTranscripts(_ on: Bool) async` -- optimistic + `store.updateSettings`; revert on failure
   - `func setGuessSpeakerNames(_ on: Bool) async` -- same pattern
   - `func startModelDownload()` -- fires `Task { await core.intelligence.downloadModel() }`
   - Update `load()` to read the two new fields from `store.settings()` and call `core.intelligence.refreshModelState()`

3. **Add `aiEnhancementsSection` to `SettingsView`**:
   - Place after `generalSection`, before `notificationsSection`
   - Section header "AI Enhancements", footer "AI runs locally on your Mac."
   - Two toggle rows with subtitle text, using the existing `VStack(spacing: Tokens.spacingXS)` pattern
   - Both toggles `.disabled(!viewModel.modelAvailable)`, bindings show `false` when disabled
   - Conditional download row when `!modelAvailable`, switching on `modelDownload`:
     - `.notDownloaded`/`.unknown`: text + subtitle + Download button
     - `.downloading(fraction)`: ProgressView + percentage label
     - `.failed(msg)`: error text + Retry button
   - Row disappears when `.downloaded`; toggles flip to enabled via live observation

4. **Create bindings** for the toggles (following existing binding pattern in SettingsView).

## Tests

- **toggleSummarizeTranscriptsPersists**: Toggle on/off, verify persisted to store and reads back on load
- **toggleGuessSpeakerNamesPersists**: Same pattern for speaker names toggle
- **toggleSummarizeTranscriptsRevertsOnFailure**: Verify optimistic update reverts when store throws (validate via a failing-store or by checking post-error state)
- **noModelDisablesAIToggles**: When modelDownloaded=false, verify `modelAvailable` is false
- **modelAvailableWhenDownloaded**: When modelDownloaded=true, verify `modelAvailable` is true
- **downloadStateFromIntelligence**: Verify `modelDownload` reads from `core.intelligence.download`
- **loadReadsSummarizeFromStore**: Pre-set value in store, load, verify VM reflects it
- **loadReadsGuessSpeakersFromStore**: Same for guess speakers
- **loadCallsRefreshModelState**: Verify that load triggers intelligence refresh
- **startModelDownloadCallsIntelligence**: Verify `startModelDownload()` initiates the download

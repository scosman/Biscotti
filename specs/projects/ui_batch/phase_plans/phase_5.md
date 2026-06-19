---
status: complete
---

# Phase 5: Transcribing UI Fixes

## Overview

Two independent transcription UI improvements: (5a) suppress the spurious "Downloading... model" subtitle when models are already cached, and (5b) replace the small left-aligned StatusRow with a dedicated large, centered transcribing layout.

## 5a Research Findings: Model Download Check Latency

**Question:** Is the model-readiness/download check itself slow on a cache hit?

**Code-level analysis of `ensureModelsDownloaded` on a cache hit:**

1. `InProcessTranscriptionEngine.ensureModelsDownloaded` calls `checkDiskSpace()` (a synchronous `FileManager.attributesOfFileSystem` call -- negligible), then `downloadWhisperKitIfNeeded` and `downloadSpeakerKitIfNeeded`.

2. `downloadWhisperKitIfNeeded` has a fast `guard whisperKit == nil else { return }` exit -- BUT after `shutdown()` between runs, `whisperKit` is always `nil` (set to nil by `unloadModels`). So on every transcription run (not just the first), it creates a `WhisperKit(config)` with `load: false, download: true`. WhisperKit's init with `download: true` checks the local cache directory and downloads only if missing. On a cache hit, this still involves directory enumeration and model file validation by the SDK.

3. Similarly for SpeakerKit: `speakerKit` is always `nil` after shutdown, so `SpeakerKit(config)` with `download: true, load: false` runs each time.

4. The `TranscriptionService.executeJob` unconditionally emits `.downloadingModel(message: "Preparing...")` BEFORE calling `downloadModels`, and then the engine's `status` callback emits "Downloading speech-to-text model" / "Downloading speaker ID model" unconditionally (regardless of whether a real download occurs).

**Conclusion:** The cache-hit path is NOT instant -- the SDK does disk enumeration and model validation -- but it is fast (sub-second on SSD). The real problem is the unconditional status messages, not slow SDK calls. An optimistic flow (skip `ensureModelsDownloaded` entirely, let `processAudio` handle loading) would be a larger refactor touching the engine lifecycle and error recovery, with unclear benefit since the check is fast. **Not worth doing in this phase.**

**Chosen approach: Delay-gate at the TranscriptionService level.**

The simplest fix: in `TranscriptionService.executeJob`, don't set the initial `.downloadingModel(message: "Preparing...")` immediately. Instead, start a delayed task that sets it after ~2 seconds. In `downloadModels`, similarly gate the status callback emissions. If the download phase finishes before the delay elapses (cache hit), the status is never shown and the job transitions straight to `.transcribing`. On a real download (takes many seconds/minutes), the delay expires and the subtitle appears.

Implementation: use a `DownloadPhaseGate` helper that absorbs download-status messages for a short delay, only forwarding them if the phase is still active after the delay. This keeps the gate self-contained and testable.

## Steps

### 5a: Suppress download subtitle on cache hit

1. **`TranscriptionService.swift` -- delay-gate the download phase:**
   - Remove the immediate `jobs[meetingID] = .downloadingModel(message: "Preparing...")` from `executeJob`.
   - Instead, set `jobs[meetingID] = .transcribing` (generic in-progress, no subtitle) at the start.
   - In `downloadModels`, wrap the status callback with a delay gate: only forward `.downloadingModel(message:)` updates to `jobs[meetingID]` after a ~2-second delay. If `downloadModels` completes before the delay, the messages are never shown.
   - After `downloadModels` completes, ensure `jobs[meetingID]` is `.transcribing` (the `runEngine` method already sets this, but we should be defensive).

2. **`MeetingDetailViewModel.swift` -- no changes needed.** The `displayState` mapping already handles both `.downloadingModel` (with subtitle) and `.transcribing` (no subtitle) correctly.

3. **Update tests:** Add a test verifying that on a fast cache-hit engine, the job status goes directly to `.transcribing` without ever showing `.downloadingModel`. Update existing tests that assert on `.downloadingModel` status to account for the delay.

### 5b: Centered transcribing layout

4. **`MeetingDetailView.swift` -- replace `centeredStatus` with a dedicated centered transcribing view:**
   - Replace the `StatusRow` usage in `centeredStatus(message:subtitle:)` with a `VStack(alignment: .center)` containing:
     - `ProgressView()` with `.controlSize(.large)` (bigger spinner)
     - Primary text (message) with a larger font (e.g. `.system(size: 17, weight: .medium)`), center-aligned
     - Optional subtitle on its own centered line below, using `.font(.subheadline)` and secondary color
   - The whole VStack is centered in Spacer/Spacer as before, but now uses center alignment so subtitle changes only affect vertical layout, not horizontal position.

5. **No changes to `StatusRow.swift`.** The shared component is used elsewhere (completed/checkmark states) and should not be modified.

## Tests

- **`TranscriptionServiceTests`: delay-gate test** -- verify that a fast engine (immediate return from ensureModelsDownloaded) results in job status never being `.downloadingModel`.
- **`TranscriptionServiceTests`: slow download test** -- verify that a slow engine (ensureModelsDownloaded takes >2s) eventually shows `.downloadingModel` status.
- **Existing tests updated** as needed to account for the new initial status behavior.
- **5b is a pure view change** -- no new ViewModel tests needed (displayState mapping is unchanged).

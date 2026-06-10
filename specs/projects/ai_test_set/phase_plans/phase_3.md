---
status: complete
---

# Phase 3: Manual Test App Updates

## Overview

Decouple the Manual Test App's transcription tab from live audio capture and expand the audio-capture test scenarios. The transcription tab is reduced to model-download steps plus a `make test-ai` tracker (quality/crash steps cut -- AI tests cover them). The audio-capture tab gains Google Meet wording, AirPods-transfer route-change, and three new mega-experiment steps.

## Steps

1. **`TranscriptionScript.swift`** -- Reduce to 4 steps: `tx_clear_cache` (action), `tx_model_download` (action), `tx_model_disk` (humanQuestion), `tx_ai_test_passed` (humanQuestion, NEW). Cut: `tx_transcribe`, `tx_speakers`, `tx_no_hallucination`, `tx_crash_setup`, `tx_crash_host_survives`, `tx_crash_retry`, `tx_custom_vocab`.

2. **`AudioCaptureScript.swift`** -- Reword existing steps and add 5 new steps:
   - `ac_timed_capture`: reword to Google Meet instant meeting
   - `ac_route_change`: reword to AirPods transfer (hear mic source change)
   - `ac_crash_safety_setup`: name ManualTestApp as the process to kill, give both methods
   - `ac_monitoring`: reword to Google Meet instant meeting
   - NEW `ac_meet_close_midcapture` (humanQuestion)
   - NEW `ac_meet_open_midcapture` (humanQuestion)
   - NEW `ac_mega_setup` (instruction -- 7-step sequence)
   - NEW `ac_mega_voice` (humanQuestion)
   - NEW `ac_mega_timing` (humanQuestion)

3. **`WiredScripts.swift`** -- Remove `currentCapturePaths`, `latestTranscriptResult`, and all transcribe/crash/autoCheck wiring from `wireTranscription`. Keep only `tx_clear_cache` and `tx_model_download` wiring. Remove `AVFoundation` import (no longer needed). Keep `transcriber` instance.

4. **Verify `.aac` files removed from `ManualTestApp/Resources/`** -- Confirm only `Info.plist` remains.

5. **`manual_test_results.json`** -- Regenerate with all current step IDs set to `not-run`, dropping cut `tx_*` keys. Use `ResultsStore` API.

6. **Update `ScriptShapeTests.swift`** -- Update step count assertions and add explicit step-ID-set tests for both scripts. Update `CIGateTests.swift` expected count from 22 to match new total (17 ac + 4 tx = 21).

## Tests

- `ScriptShapeTests/transcriptionStepCount`: assert exactly 4 steps
- `ScriptShapeTests/transcriptionStepIDs`: assert exact set {tx_clear_cache, tx_model_download, tx_model_disk, tx_ai_test_passed}
- `ScriptShapeTests/audioCaptureStepCount`: assert exactly 17 steps
- `ScriptShapeTests/audioCaptureStepIDs`: assert exact set of all 17 ac_* IDs
- `ScriptShapeTests/cutTranscriptionStepsAbsent`: assert the 7 cut tx_* IDs are NOT present
- `CIGateTests/resultsFileCoversAllStepIDs`: updated to expect 21 total step IDs
- Existing uniqueness/identity tests continue to pass

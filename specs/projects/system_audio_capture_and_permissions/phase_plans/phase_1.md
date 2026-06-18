---
status: complete
---

# Phase 1: Robust record pipeline (remaining items)

## Overview

The engine retry/settle/reconnect work in `AudioRecorder` + `LiveSystemCaptureEngine` is already
implemented and HW-verified. This phase completes the remaining Stage 1 items: removing the
pre-record probe, neutering the denial check, stripping DIAG logging, marking manual tests
not-run, and adding a system-audio device/sample-rate manual test step.

## Steps

1. **Remove pre-record probe in `RecordingController.start()`**
   - File: `Packages/BiscottiKit/Sources/Recording/RecordingController.swift`
   - Delete the `await probeSystemAudioPermission(recorder: newRecorder)` call at ~line 132.
   - Recording still creates its real tap (surfaces TCC prompt on first use).
   - The `probeSystemAudioPermission(recorder:)` private method stays (used by
     `probeSystemAudioAndInferState`), but is no longer called from `start()`.

2. **Neuter `scheduleDenialCheck`**
   - File: `Packages/BiscottiKit/Sources/Recording/RecordingController.swift`
   - `scheduleDenialCheck` must no longer call `permissions.noteSystemAudio(_:)` (no durable
     "Denied" state). The `systemAudioWarning` in-memory flag may remain for potential Stage 3
     reuse, but the `permissions.noteSystemAudio` calls are removed.
   - Add a `// TODO: Stage 3 — the all-zero detection infra here may power the in-recording
     hint` comment to mark the scaffolding.

3. **Strip all `[DIAG]` diagnostic logging from `AudioRecorder.swift`**
   - File: `Packages/AudioCapture/Sources/AudioCapture/AudioRecorder.swift`
   - Remove every `logger.notice(... [DIAG])` line.
   - Keep permanent `.public` failure logging (real errors).

4. **Strip all `[DIAG]` diagnostic logging from `LiveSystemCaptureEngine.swift`**
   - File: `Packages/AudioCapture/Sources/AudioCapture/LiveSystemCaptureEngine.swift`
   - Remove every `logger.notice(... [DIAG])` line and DIAG-only comments.
   - Remove `logOutputDeviceSnapshot` and `logASBD` helper methods (DIAG-only; not called by
     any non-DIAG code path).
   - Keep `queryTapFormat()` (used by `openAudioFile` and `detectAndApplyFormatChange`).
   - Remove the entire `// MARK: - Temporary HW-verify diagnostics` extension section.
   - Keep permanent `.public` failure/warning/info logging.

5. **Mark `ac_*` manual tests as not-run**
   - File: `ManualTestApp/Results/manual_test_results.json`
   - Set `"status": "not-run"` for all recordable `ac_*` steps. Exclude `.instruction` steps:
     `ac_timed_capture`, `ac_mega_setup`, `ac_crash_safety_setup`.
   - The recordable `ac_*` steps are: `ac_request_permissions`, `ac_two_dialogs`,
     `ac_start_recording`, `ac_stop_recording`, `ac_files_exist`, `ac_playback_mic`,
     `ac_playback_system`, `ac_route_change`, `ac_meet_close_midcapture`,
     `ac_meet_open_midcapture`, `ac_mega_voice`, `ac_mega_timing`, `ac_crash_safety_check`.

6. **Add a system-audio device/sample-rate manual test step**
   - File: `Packages/BiscottiKit/Sources/ManualTestKit/Scripts/AudioCaptureScript.swift`
   - Add a new `.humanQuestion` step with `id: "ac_device_sample_rate"` covering
     system-audio device/sample-rate transitions: AirPods/Bluetooth start, 44.1 kHz output
     mid-record, output-device switch mid-record -- confirm audio survives / stop-track on
     -66565. Insert it after the existing `ac_route_change` step.
   - Update `ScriptShapeTests.swift` to reflect the new step count (17) and include the new
     step ID in the canonical set.
   - Add the new step as `"not-run"` in the results JSON file.

7. **Update RecordingController tests**
   - The existing `systemAudioDenialInference` test expects
     `fix.permissions.systemAudio == .denied` -- update it to verify the neutered behavior
     (warning flag may still be set, but `permissions.systemAudio` must NOT be `.denied`).
   - The existing `systemAudioAuthorizedInference` test expects
     `fix.permissions.systemAudio == .authorized` -- update it similarly.
   - The `startCreatesMeetingAndLinksAudioRefs` test checks
     `fix.fakeRecorder.backing.requestPermissionsCalled == true` -- update it to expect `false`
     since the probe is removed from `start()`.

## Tests

- `systemAudioDenialInference`: verifies `systemAudioWarning` is still set, but
  `permissions.systemAudio` stays `.notDetermined` (never `.denied`).
- `systemAudioAuthorizedInference`: verifies `permissions.systemAudio` stays `.notDetermined`
  (the denial check no longer calls `noteSystemAudio`).
- `startCreatesMeetingAndLinksAudioRefs`: verifies the probe is NOT called during start.
- `ScriptShapeTests`: updated step count (17) and canonical ID set includes
  `ac_device_sample_rate`.

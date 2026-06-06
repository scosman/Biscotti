---
status: complete
---

# Phase 2.1: Package + Pure Logic Carry-Over

## Overview

Create `Packages/AudioCapture` as a new SPM package and port all pure, unit-testable logic from `experiments/AudioLab`. This is the foundation for the AudioCapture library — the types, helpers, and settings that do not require live audio hardware. Phase 2.2 will build the capture engine on top of these.

## Steps

1. Create `Packages/AudioCapture/Package.swift` matching BiscottiKit conventions (swift-tools-version 6.1, `swiftLanguageModes: [.v6]`, warnings-as-errors, macOS 15, system frameworks CoreAudio/AudioToolbox/AVFAudio).

2. Create `Sources/AudioCapture/CaptureError.swift` — the `CaptureError` enum from the component doc:
   ```swift
   public enum CaptureError: Error, Sendable, Equatable {
       case tapCreationFailed(OSStatus)
       case aggregateDeviceFailed(OSStatus)
       case micEngineFailed(String)
       case conversionFailed(String)
       case probablePermissionDenied
   }
   ```

3. Create `Sources/AudioCapture/EncoderSettings.swift` — productionized as a public struct (not enum) per the component doc, with `voiceM4A` static preset (24 kHz, mono, 64 kbps AAC-LC), exposing `avSettings: [String: Any]`.

4. Create `Sources/AudioCapture/RMSMonitor.swift` — carry over `RMSMonitor` as a public struct with `mutating func ingest(_:)` per the component doc's value-type API. Keep the `isSuspectedFailure` computed property.

5. Create `Sources/AudioCapture/AudioFrameCount.swift` — carry over the `audioFrameCount(byteSize:channelCount:)` free function.

6. Create `Sources/AudioCapture/AudioProcess.swift` — port `AudioProcess` as a public struct. Add optional `bundleID` (per the component doc's `ProcessAudioActivity` shape).

7. Create `Sources/AudioCapture/RecordingFileManager.swift` — port with the CAF-to-M4A handoff API. Design around caller-provided paths. Add encode-failure handling that retains the CAF and surfaces `CaptureError.conversionFailed`.

8. Create `Sources/AudioCapture/CoreAudioHelpers.swift` — port the pure property-getter helpers (getPropertyData, getStringProperty, getPropertyArray, processIOState). Keep them internal for now; the public API is through higher-level types.

9. Add `Packages/AudioCapture` to `Makefile` PACKAGES list.

10. Write all test files in `Tests/AudioCaptureTests/`.

## Tests

- `EncoderSettingsTests`: voiceM4A yields 24 kHz / mono / 64 kbps AAC avSettings; processingFormat matches.
- `RMSMonitorTests`: all-zero window triggers isSuspectedFailure; real signal does not; reset clears state.
- `AudioFrameCountTests`: mono, stereo, multi-channel, edge cases (zero bytes, zero channels, non-aligned).
- `AudioProcessTests`: known meeting apps recognized; unknown not; display names consistent; running state stored.
- `RecordingFileManagerTests`: CAF-to-M4A encode; on simulated encode failure CAF retained and error surfaced; file-size helper; timestamp format.

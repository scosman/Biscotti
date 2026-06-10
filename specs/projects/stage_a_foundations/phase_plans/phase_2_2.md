---
status: draft
---

# Phase 2.2: Capture Engine + Route-Change + Permission Inference

## Overview

Build the `AudioRecorder` actor that composes two capture backends -- system audio (Core Audio process tap + aggregate device + IOProc) and mic (AVAudioEngine input-node tap) -- behind protocol seams so orchestration, state, route-change, and permission-inference logic are all unit-testable with fakes.

The real Core Audio / AVAudioEngine implementations are thin adapters; all behavior-carrying logic lives in the testable `AudioRecorder` orchestration layer.

## Steps

### 1. Define the capture-engine seam protocols

New file: `Sources/AudioCapture/CaptureEngine.swift`

```swift
/// Seam for a single audio capture stream (mic or system).
/// Real implementations use Core Audio / AVAudioEngine.
/// Tests inject fakes.
public protocol CaptureEngine: Sendable {
    func start(writingTo url: URL) async throws
    func stop() async
}

/// Seam for device-change observation.
/// Real: Core Audio property listeners / NotificationCenter.
/// Tests: inject synthetic events.
public protocol DeviceChangeProvider: Sendable {
    /// Emits `.outputChanged` or `.inputChanged` events.
    func deviceChanges() -> AsyncStream<DeviceChangeEvent>
}

public enum DeviceChangeEvent: Sendable, Equatable {
    case outputChanged
    case inputChanged
}
```

### 2. Define the public value types

New file: `Sources/AudioCapture/CapturePaths.swift`

```swift
public struct CapturePaths: Sendable {
    public let micCAF: URL
    public let systemCAF: URL
    public let micOutput: URL      // .m4a
    public let systemOutput: URL   // .m4a
    public init(micCAF:systemCAF:micOutput:systemOutput:)
}
```

New file: `Sources/AudioCapture/CaptureState.swift`

```swift
public struct CaptureState: Sendable, Equatable {
    public let isRecording: Bool
    public let elapsed: TimeInterval
    public let micLevel: Float       // 0...1 RMS (unwired; always 0)
    public let systemLevel: Float    // 0...1 RMS (unwired; always 0)
    public let startTimestamp: Double // shared CACurrentMediaTime reference
    public static let idle: CaptureState
}
```

### 3. Build `AudioRecorder` actor

New file: `Sources/AudioCapture/AudioRecorder.swift`

The actor:
- Holds references to a system `CaptureEngine`, a mic `CaptureEngine`, a `DeviceChangeProvider`, and encoder settings.
- `start(paths:)`: starts both engines sharing one `CACurrentMediaTime()` timestamp, stores paths, starts listening for device changes, begins state emission.
- `stop()`: stops both engines, encodes both CAFs to M4A via `RecordingFileManager.encodeToM4A`, returns output URLs. On encode failure: keeps CAF, throws `.conversionFailed`.
- `stateStream()`: returns `AsyncStream<CaptureState>` emitting periodic updates (~0.25s).
- `probableSystemAudioDenied()`: checks a `SystemPermissionChecker` seam for all-zero first-2s detection.
- Route-change handling: listens to `DeviceChangeProvider`; on `.outputChanged` stops + restarts the system engine; on `.inputChanged` stops + restarts the mic engine. `isRecording` stays true throughout.

### 4. Define the permission-check seam

```swift
/// Seam for detecting probable system audio permission denial.
public protocol SystemPermissionChecker: Sendable {
    func probableDenied() async -> Bool
}
```

### 5. Build the real (live) capture engine implementations

New file: `Sources/AudioCapture/LiveSystemCaptureEngine.swift` -- thin wrapper around tap + aggregate device + IOProc writing PCM to CAF (adapted from experiment `SystemAudioCapture`). Implements `CaptureEngine`.

New file: `Sources/AudioCapture/LiveMicCaptureEngine.swift` -- thin wrapper around AVAudioEngine input-node tap writing PCM to CAF (adapted from experiment `MicCapture`). Implements `CaptureEngine`.

New file: `Sources/AudioCapture/LiveDeviceChangeProvider.swift` -- listens for Core Audio `kAudioHardwarePropertyDefaultOutputDevice` / `kAudioHardwarePropertyDefaultInputDevice` changes + `AVAudioEngineConfigurationChange`. Implements `DeviceChangeProvider`.

New file: `Sources/AudioCapture/LiveSystemPermissionChecker.swift` -- monitors first ~2s of system audio buffers for all-zeros; implements `SystemPermissionChecker`.

These are intentionally thin and NOT unit-tested (hardware-dependent); tested by Manual Test App later.

### 6. Add convenience factory

Extend `AudioRecorder` with a `static func live(encoder:)` factory that wires the real implementations.

### 7. Port `AudioRingBuffer` (needed by live system capture)

New file: `Sources/AudioCapture/AudioRingBuffer.swift` -- carry over from experiment, used by `LiveSystemCaptureEngine`.

### 8. Write tests

New file: `Tests/AudioCaptureTests/StartAlignmentTests.swift`
- Verify both streams share one start timestamp via fake engines.

New file: `Tests/AudioCaptureTests/RouteChangeTests.swift`
- Inject output-change event -> verify system engine was stopped + restarted, `isRecording` stays true.
- Inject input-change event -> verify mic engine was stopped + restarted, `isRecording` stays true.

New file: `Tests/AudioCaptureTests/PermissionInferenceTests.swift`
- Fake checker returning true -> `probableSystemAudioDenied()` returns true.
- Fake checker returning false -> returns false.

New file: `Tests/AudioCaptureTests/AudioRecorderTests.swift`
- Basic start/stop lifecycle with fakes.
- Stop encodes CAFs to M4A (using real `RecordingFileManager` with synthetic CAFs).
- `stateStream()` emits updates.

## Tests

- `StartAlignmentTests.bothStreamsShareStartTimestamp`: both fake engines started, `CaptureState.startTimestamp` is the shared value, both engines received `start()` calls.
- `RouteChangeTests.outputChangeRebuildsSystemCapture`: injected output event causes system engine stop + restart; mic untouched; `isRecording` true throughout.
- `RouteChangeTests.inputChangeRestartsMicCapture`: injected input event causes mic engine stop + restart; system untouched; `isRecording` true throughout.
- `PermissionInferenceTests.returnsTrueWhenAllZero`: fake checker says true -> `probableSystemAudioDenied()` true.
- `PermissionInferenceTests.returnsFalseWhenNonZero`: fake checker says false -> `probableSystemAudioDenied()` false.
- `AudioRecorderTests.startAndStopLifecycle`: start sets `isRecording` true; stop sets false; returns URLs.
- `AudioRecorderTests.stateStreamEmitsUpdates`: at least one `CaptureState` received with `isRecording == true`.

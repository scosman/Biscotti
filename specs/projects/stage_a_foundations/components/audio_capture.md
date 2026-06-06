---
status: complete
---

# Component: AudioCapture (`Packages/AudioCapture`)

Productionizes `experiments/AudioLab`. Designs the real API inside the boundary the repo [`architecture.md` §1](../../../../architecture.md) draws. Consumes [`research/audio`](../../../../research/audio/README.md) + [`phase9_validation_findings.md`](../../../../research/audio/phase9_validation_findings.md) — do not re-derive.

## Purpose & Scope

**In:** two-stream capture (mic via `AVAudioEngine`, **global** system audio via Core Audio process tap), crash-safe PCM→CAF write then encode-on-stop to ADTS AAC `.m4a`, route-change survival, per-process audio **monitoring** event stream, two-stream start alignment, RMS zero-buffer scaffolding (unwired), probable-permission-denied inference.

**Not:** data store, meeting semantics/watchlist matching, stream **merging** (Transcription), choosing storage locations (caller provides paths), TCC prompts/UI, app-level recording lifecycle.

## Public Interface

### Capture

```swift
public struct CapturePaths: Sendable {
    public let micCAF: URL          // PCM CAF written during capture
    public let systemCAF: URL
    public let micOutput: URL       // .m4a produced on stop
    public let systemOutput: URL
}

public struct CaptureState: Sendable, Equatable {
    public let isRecording: Bool
    public let elapsed: TimeInterval
    public let micLevel: Float       // 0…1 RMS
    public let systemLevel: Float
    public let startTimestamp: Double // shared CACurrentMediaTime reference
}

public actor AudioRecorder {
    public init(encoder: EncoderSettings = .voiceM4A)   // ADTS AAC-LC, mono, 24 kHz, 64 kbps

    /// Starts both streams against caller-provided paths. Throws on tap/engine setup failure.
    public func start(paths: CapturePaths) async throws

    /// Stops capture, encodes both CAFs to .m4a, returns the finished outputs.
    /// On encode failure: keeps the CAF and throws `.conversionFailed` (audio never lost).
    @discardableResult
    public func stop() async throws -> (mic: URL, system: URL)

    public func stateStream() -> AsyncStream<CaptureState>

    /// Probable-permission report: true if first ~2s of system audio were all-zero.
    public func probableSystemAudioDenied() async -> Bool
}
```

### Encoder settings (carry over from `AudioLab/EncoderSettings.swift`)

```swift
public struct EncoderSettings: Sendable, Equatable {
    public let sampleRate: Double      // 24_000
    public let channels: Int           // 1
    public let bitRate: Int            // 64_000
    public static let voiceM4A: EncoderSettings   // the resolved choice
    var avSettings: [String: Any] { get }          // for AVAudioFile / converter
}
```

### Monitoring (detection signal only — separate from capture)

```swift
public struct ProcessAudioActivity: Sendable, Equatable, Identifiable {
    public let id: AudioObjectID
    public let bundleID: String?
    public let pid: pid_t
    public let isRunningInput: Bool
    public let isRunningOutput: Bool
}

public actor AudioActivityMonitor {
    public init()
    /// Emits the current set whenever kAudioHardwarePropertyProcessObjectList changes.
    public func activityStream() -> AsyncStream<[ProcessAudioActivity]>
}
```

### Route-change handling (internal, but observable for tests)

`AudioRecorder` listens for default input/output device + Bluetooth changes and rebuilds the tap+aggregate device (output change) or restarts the engine (input change), sub-second. Surfaced via `CaptureState` continuity (no permanent silence) and a debug event for tests.

### RMS monitor (kept, unwired)

```swift
public struct RMSMonitor: Sendable {           // carry over from AudioLab
    public mutating func ingest(_ buffer: [Float])
    public var isSuspectedFailure: Bool { get } // all-zero for > window
}
```
Not wired into `AudioRecorder` by default (phase9 Test 7); exposed so it can be wired if the all-zero failure ever surfaces.

### Errors

```swift
public enum CaptureError: Error, Sendable, Equatable {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case micEngineFailed(String)
    case conversionFailed(String)   // CAF retained
    case probablePermissionDenied
}
```

## Internal Design

Mirrors the validated E1 architecture (`research/audio` §"Architecture for the Experiment"): `SystemAudioCapture` (tap + aggregate device + IOProc → CAF), `MicCapture` (AVAudioEngine input tap → CAF), both started together with a shared `CACurrentMediaTime()` reference; `RecordingFileManager` owns the CAF→M4A encode on stop. Core Audio C APIs sit behind `CoreAudioHelpers` (carry over) so the buffer-processing, encoder, frame-count, file-manager, RMS, and process-listener logic — which already have tests in `AudioLab/Tests` — stay pure and unit-testable.

## Dependencies

System frameworks only (CoreAudio, AudioToolbox, AVFAudio). No internal Biscotti deps. Consumed by: `ManualTestApp` (now); `Recording` + `MeetingDetection` (later projects).

## Test Plan (all `swift test`, synthetic buffers — no live audio)

Carry over + productionize the existing `AudioLab/Tests`:
- `EncoderSettingsTests` — `voiceM4A` yields 24 kHz / mono / 64 kbps AAC `avSettings`.
- `RMSMonitorTests` — all-zero window → `isSuspectedFailure`; real signal → not.
- `AudioFrameCountTests` / `AudioProcessTests` — frame math; process-object parsing.
- `ProcessPropertyListenerTests` — synthetic process-list change → expected `[ProcessAudioActivity]` diff on the stream.
- `RecordingFileManagerTests` — CAF→M4A handoff; on simulated encode failure the CAF is retained and `.conversionFailed` thrown.
- `StartAlignmentTests` — both streams share one start timestamp.
- (Seam) `RouteChangeTests` — injected device-change event triggers a rebuild without tearing down the public `CaptureState` (no permanent silence).

**Deferred to Manual Test App:** real mic + system capture, real route changes (AirPods mid-recording), audio quality, the real permission dialogs, Teams capture.
</content>

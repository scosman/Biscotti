---
status: complete
---

# Component: AudioCapture (`Packages/AudioCapture`)

Productionizes `experiments/AudioLab`. Designs the real API inside the boundary the repo [`architecture.md` §1](../../../../architecture.md) draws. Consumes [`research/audio`](../../../../research/audio/README.md) + [`phase9_validation_findings.md`](../../../../research/audio/phase9_validation_findings.md) — do not re-derive.

## Purpose & Scope

**In:** two-stream capture (mic via plain `AVAudioEngine`, **global** system audio via Core Audio process tap + aggregate device), **ADTS AAC direct write** (`ExtAudioFile` + `kAudioFileAAC_ADTSType`, AAC-LC mono 24 kHz 64 kbps, `.aac` files — crash-safe with no finalization, no CAF, no PCM scratch, no encode-on-stop), route-change survival (file-preserving: keep the same file open across `AVAudioEngineConfigurationChange` / output-device rebuild), per-process audio **monitoring** event stream (push-based via `kAudioProcessPropertyIsRunning` listeners), two-stream start alignment (t=0 anchor), RMS zero-buffer scaffolding (unwired), mic permission preflight (`AVCaptureDevice.authorizationStatus`), system-audio probable-permission-denied inference (zero-buffer heuristic in first ~2 s, deferred/unwired).

**Not:** data store, meeting semantics/watchlist matching, stream **merging** (Transcription), choosing storage locations (caller provides paths), TCC prompts/UI, app-level recording lifecycle, CAF→M4A encode step (eliminated by ADTS).

## Public Interface

### Capture

```swift
/// Caller-provided file URLs for a two-stream capture session.
///
/// Both files are ADTS AAC (`.aac`), written directly during capture.
/// No intermediate CAF, no encode-on-stop step.
public struct CapturePaths: Sendable {
    public let micAAC: URL          // ADTS AAC written during mic capture
    public let systemAAC: URL       // ADTS AAC written during system capture
}

public struct CaptureState: Sendable, Equatable {
    public let isRecording: Bool
    public let elapsed: TimeInterval
    public let micLevel: Float       // 0…1 RMS (unwired; always 0)
    public let systemLevel: Float    // 0…1 RMS (unwired; always 0)
    public let startTimestamp: Double // shared CACurrentMediaTime reference
}

public actor AudioRecorder {
    public init(encoder: EncoderSettings = .voice)

    /// Starts both streams against caller-provided paths. Throws on
    /// tap/engine setup failure or mic permission denial.
    public func start(paths: CapturePaths) async throws

    /// Stops capture. The `.aac` files are already the final output —
    /// no encode step runs. Files are valid up to the last written ADTS frame.
    public func stop() async

    public func stateStream() -> AsyncStream<CaptureState>

    /// Probable-permission report: true if first ~2 s of system audio
    /// were all-zero (deferred/unwired — scaffolding only).
    public func probableSystemAudioDenied() async -> Bool
}
```

### Encoder settings (ADTS AAC encoder config)

Carries the resolved format decision and the bitrate-commit logic validated
in AudioLab. Not an `AVAudioFile` settings dict — drives `ExtAudioFile`
creation with `kAudioFileAAC_ADTSType` and bitrate set on the internal
`AudioConverter` via `kAudioConverterEncodeBitRate`, committed with a
NULL `CFArrayRef` `kExtAudioFileProperty_ConverterConfig` (the gotcha
that crashed when passed as a `UInt32`).

```swift
public struct EncoderSettings: Sendable, Equatable {
    public let sampleRate: Double      // 24_000
    public let channels: Int           // 1
    public let bitRate: Int            // 64_000
    public let formatID: AudioFormatID // kAudioFormatMPEG4AAC
    public let fileType: AudioFileTypeID // kAudioFileAAC_ADTSType

    public static let voice: EncoderSettings   // the resolved choice

    /// ASBD for the on-disk ADTS AAC output (used by ExtAudioFile).
    public func outputASBD() -> AudioStreamBasicDescription

    /// After setting the client format on an ExtAudioFile, configures
    /// the AAC encoder's bitrate via its underlying AudioConverter.
    /// Uses NULL CFArrayRef ConverterConfig commit (validated fix for
    /// EXC_BAD_ACCESS when passing wrong-typed UInt32).
    @discardableResult
    public static func applyBitRate(to extFile: ExtAudioFileRef) -> OSStatus

    /// PCM format the mic tap pre-converts to before writing (and the
    /// ExtAudioFile client format). Mono float at the configured sample
    /// rate. Must be set as the client format so the internal converter
    /// handles resampling + channel downmix from the raw input (e.g.
    /// 3-channel 48 kHz beamforming array).
    public var processingFormat: AVAudioFormat { get }
}
```

### Monitoring (detection signal only — separate from capture)

Push-based via per-process `kAudioProcessPropertyIsRunning` listeners
(NOT `IsRunningInput`/`IsRunningOutput`, which do NOT post notifications
on macOS — validated, Apple Forums 825780). On each fire, re-read both
input and output state. Register/unregister per-process listeners as
the system process list changes; remove all on teardown.

```swift
public struct AudioProcess: Sendable, Equatable, Identifiable {
    public let id: AudioObjectID
    public let bundleID: String?
    public let pid: pid_t
    public let isRunningInput: Bool
    public let isRunningOutput: Bool
}

/// Seam for audio process activity observation.
/// Real: Core Audio property listeners. Tests: inject synthetic lists.
public protocol ProcessActivitySource: Sendable {
    func currentProcesses() -> [AudioProcess]
    func processChanges() -> AsyncStream<Void>
}

public actor AudioActivityMonitor {
    public init(source: some ProcessActivitySource)

    /// Convenience factory wiring the live Core Audio source.
    public static func live() -> AudioActivityMonitor

    /// Emits the current set whenever process list or per-process
    /// running state changes (push-based, no polling).
    public func activityStream() -> AsyncStream<[AudioProcess]>
}
```

### Route-change handling (internal, but observable for tests)

**Mic (input change):** `AVAudioEngineConfigurationChange` notification.
On each change: re-query the input format fresh (sample rate AND channel
count can both change — the M4 built-in mic is a 3-channel array), remove
and reinstall the tap with a new `AVAudioConverter` if format differs,
restart the engine. **Keep the same ExtAudioFile open** — no `eraseFile`,
no client-format reset (the client format stays as the processing format
for the life of the file; the tap converter adapts to the new input).
Debounce via a generation counter on a serial queue.

**System (output change):** full teardown of IOProc + aggregate device +
process tap, then recreate (the IOProc, aggregate device with the new
default output device UID as sub-device, and process tap). Keep the same
ExtAudioFile open throughout.

Both preserve `isRecording == true` (no permanent silence) and are tested
via injected `DeviceChangeEvent` through a `DeviceChangeProvider` seam.

### RMS monitor (kept, unwired)

```swift
public struct RMSMonitor: Sendable {
    public mutating func ingest(_ buffer: [Float], bufferDuration: Double)
    public var isSuspectedFailure: Bool { get } // all-zero for > window
}
```
Not wired into `AudioRecorder` by default (phase 9 Test 7 — failure did
not reproduce on macOS 15); exposed so it can be wired if the all-zero
failure ever surfaces.

### Errors

```swift
public enum CaptureError: Error, Sendable {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case micEngineFailed(String)
    case micPermissionDenied        // AVCaptureDevice preflight denied/restricted
    case probablePermissionDenied   // system-audio zero-buffer heuristic
}
```

Note: no `conversionFailed` or `partialEncodeFailed` — there is no
encode-on-stop step with ADTS. The files are final as written.

## Internal Design

### File writing — ADTS AAC via ExtAudioFile (both tracks)

Both mic and system tracks use `ExtAudioFile` with `kAudioFileAAC_ADTSType`:

1. **Create:** `ExtAudioFileCreateWithURL(url, kAudioFileAAC_ADTSType, &outputASBD, ...)`
   - `outputASBD`: AAC-LC (`kAudioFormatMPEG4AAC`), 24 kHz, mono.
2. **Set client format:** `kExtAudioFileProperty_ClientDataFormat` = the PCM
   format of the data being fed (processing format for mic, tap format for system).
3. **Set bitrate:** get the internal `AudioConverter` via
   `kExtAudioFileProperty_AudioConverter`, set `kAudioConverterEncodeBitRate`
   to 64000, then commit with `kExtAudioFileProperty_ConverterConfig` = NULL
   `CFArrayRef` (at pointer size — NOT a `UInt32`, which causes `EXC_BAD_ACCESS`
   in `CFArrayGetCount`).
4. **Write:** `ExtAudioFileWrite` with PCM buffers — the internal converter
   handles resampling + channel-mixing + AAC encoding.
5. **Close:** `ExtAudioFileDispose` on stop (or on crash, the partial ADTS
   file decodes up to the last complete frame).

### Mic capture — plain AVAudioEngine (NOT VPIO)

Uses `AVAudioEngine` with `inputNode` tap. VPIO (`setVoiceProcessingEnabled`)
was tried on M4 hardware and **rejected** — it faults (`Cannot retrieve
theDeviceBoardID`, DSP state fault, bogus 9-channel input format, empty mic
file). Plain AVAudioEngine correctly handles the 3-channel beamforming array
via its standard format negotiation.

When the input format differs from the processing format (e.g. 3ch 48 kHz
from the M4 built-in mic vs. mono 24 kHz target), an `AVAudioConverter`
pre-converts before handing to `ExtAudioFile`. The ExtAudioFile client
format is set to the processing format (what the tap delivers after
conversion), NOT the raw input format.

Frame count for multichannel input: `byteSize / (sizeof(Float) * channelCount)`
— not just `byteSize / sizeof(Float)`, which crashes on 3-channel arrays.

### System capture — global process tap

`CATapDescription(stereoGlobalTapButExcludeProcesses: [])` (the purpose-built
initializer, not bare `init()` + manual flags). Aggregate device config
requires:
- `kAudioAggregateDeviceSubDeviceListKey` with the default output device UID
- `kAudioAggregateDeviceMainSubDeviceKey` = output device UID
- A **distinct** aggregate device UID (do NOT reuse the tap UUID)
- `kAudioAggregateDeviceIsPrivateKey: true`
- `tapDesc.isPrivate = true`

IOProc delivers PCM buffers through a lock-free ring buffer to a dedicated
high-priority writer thread. The writer thread feeds `ExtAudioFileWrite`
(and, during the permission-check window, the zero-buffer detector).

### Permission handling

**Mic:** definitive `AVCaptureDevice.authorizationStatus(for: .audio)` preflight.
`.authorized` = proceed; `.notDetermined` = `requestAccess` then proceed only
if granted; `.denied`/`.restricted` = refuse to start + surface error. This is
the only reliable signal (there is no usable OSStatus for denial).

**System tap:** no public API for system-audio permission status. The zero-buffer
heuristic (all-zero first ~2 s while `kAudioProcessPropertyIsRunningOutput`
is true) is the documented backstop. **Currently deferred/unwired** — the
all-zero tap failure did not reproduce on macOS 15. Scaffolding
(`LiveSystemPermissionChecker`) exists and monitors; nothing reads its result.

## Dependencies

System frameworks only (CoreAudio, AudioToolbox, AVFAudio). No internal Biscotti deps. Consumed by: `ManualTestApp` (now); `Recording` + `MeetingDetection` (later projects).

## Test Plan (all `swift test`, synthetic buffers — no live audio)

Carry over + productionize the existing `AudioLab/Tests`:
- `EncoderSettingsTests` — `.voice` yields 24 kHz / mono / 64 kbps / `kAudioFileAAC_ADTSType` / `kAudioFormatMPEG4AAC`. Tests `outputASBD()` and `processingFormat`.
- `RMSMonitorTests` — all-zero window -> `isSuspectedFailure`; real signal -> not.
- `AudioFrameCountTests` — frame math with multichannel (3-ch beamforming array).
- `AudioProcessTests` — process-object parsing; seed watchlist (including `com.apple.avconferenced`, `com.apple.WebKit.GPU`, `com.tinyspeck.slackmacgap.helper`).
- `AudioActivityMonitorTests` — synthetic process-list + `kAudioProcessPropertyIsRunning` change -> expected `[AudioProcess]` diff on the stream (push, no polling).
- `StartAlignmentTests` — both streams share one start timestamp.
- (Seam) `RouteChangeTests` — injected device-change event triggers reconnect (file-preserving, no stop/start) without tearing down `CaptureState` (no permanent silence).
- `PermissionInferenceTests` — system-audio zero-buffer backstop returns correct verdicts.
- `AudioRecorderTests` — start/stop lifecycle; no encode step on stop (files are final `.aac`); mic permission denial prevents start.

**No `RecordingFileManagerTests` for CAF->M4A** — the encode-on-stop step does not exist with ADTS.

**Deferred to Manual Test App:** real mic + system capture, real route changes (AirPods mid-recording), audio quality, the real permission dialogs, Teams capture, crash-safety (`kill -9` -> partial `.aac` files play up to the kill point).

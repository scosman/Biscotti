---
status: complete
---

# Component: Test-Signal Kit and Metrics (`AudioProcessingTestSupport`)

## Purpose and scope

A library target in `Packages/AudioProcessing`, exported as a product, that generates realistic, deterministic test material with known ground truth, and provides the metrics used by:
- `AudioProcessingTests`;
- `AudioCaptureTests` (they may depend on it through a test-only package dependency; see "Consumers" below);
- `audioproc-cli bakeoff`.

It also writes synthetic meeting folders on disk (real AAC files and timelines), so integration tests exercise the real file contract.

**Out of scope:** device capture, and anything shipped in the app. The app, the XPC service and the lab don't link this target. The lab uses only `AudioProcessing`'s real-data metrics.

## Speech material

Real speech is required, not tones. The research shows tone-based fixtures misled another team's LocalVQE evaluation ([post-processing research](../../../research/builtin-mic-voice-processing/post-processing/summary.md)).

- **Source:** the repo's existing `Packages/Transcription/Tests/TranscriptionTests/Fixtures/mic_fixture.wav` and `system_fixture.wav` (44.1 kHz mono 16-bit, a 3-speaker clip). Copy them into `Sources/AudioProcessingTestSupport/Resources/Speech/` as `near.wav` and `far.wav`. Note their provenance in a `Resources/Speech/README.md`, pointing to the `ai_test_set` project.
- **`SpeechFixtures`:**
  - `near(seconds:)` / `far(seconds:)` → 16 kHz `[Float]`, resampled once and cached in memory;
  - clips longer than the source loop with a 200 ms crossfade;
  - `talker(_:)` variants offset the start point, so two "different" near segments don't correlate.

## Generators

All generators are pure functions of their parameters plus a `seed: UInt64`, using SplitMix64 (no system RNG), so they're bit-reproducible.

```swift
public struct EchoPathParams: Sendable { delayMs: Double; rt60: Double; enrDB: Double /*echo-to-near ratio*/;
                                         nonlinearityDrive: Double? /*tanh; nil = linear*/; driftPPM: Double;
                                         codecRoundTripReference: Bool }
public enum EchoSimulator {
    /// echo = drift(resample)(nonlinear(conv(farEnd delayed, RIR))) scaled to ENR vs near speech RMS
    public static func echo(of farEnd: [Float], params: EchoPathParams, seed: UInt64) -> [Float]
    public static func rir(rt60: Double, sampleRate: Double, seed: UInt64) -> [Float]   // exp-decay noise, direct-path tap at 0
}
public struct ArrayParams: Sendable { channelGainsDB: [Double]; channelLagsSamples48k: [Int]; invert: [Bool];
                                      selfNoiseDBFS: Double; levelDBFS: Double /* e.g. -48 for raw array */ }
public enum ArraySimulator {
    /// Produces N capsule signals (48 kHz) from one acoustic signal + independent self-noise per capsule.
    public static func capsules(from acoustic: [Float], params: ArrayParams, seed: UInt64) -> [[Float]]
}
public enum InterfaceSimulator {
    /// Channels: .dead (exact zeros), .preampNoise(dBFS), .speech(signal), for "mic on input 2" etc.
    public static func channels(_ spec: [ChannelSpec], length: Int, seed: UInt64) -> [[Float]]
}
public enum Codec {
    /// AAC-LC ADTS round trip via ExtAudioFile at 24 kHz / 64 kbps (the real capture encoder settings), returns 16 kHz.
    public static func aacRoundTrip(_ x: [Float], sampleRate: Double) throws -> [Float]
}
```

Signal conventions:
- generators work at 48 kHz where capture realism matters (array lags, the 48→24 kHz path), and at 16 kHz otherwise;
- all levels are specified in dBFS RMS over speech-active frames;
- noise is white noise through a pink-ish 1st-order low-pass, at −70 dBFS by default.

## Scenarios

```swift
public struct Scenario: Sendable {
    public let id: String
    public let sampleRate: Double                 // 16 kHz for processing-level scenarios
    public let mic: [Float]                       // near + echo + noise (or combined array → see meetingFolder)
    public let reference: [Float]                 // far-end as the system track would contain it
    public let nearTruth: [Float]                 // near-end speech only (scaled as in mic)
    public let echoTruth: [Float]                 // echo component only
    public let regions: [Region]                  // labeled: .farOnly, .nearOnly, .doubleTalk, .silence
}
public enum ScenarioLibrary {
    public static func bakeoff(durationSeconds: Double = 60) -> [Scenario]   // S1…S7 (echo_cancellation.md)
    public static func unit(_ id: UnitScenarioID) -> Scenario               // short variants used by unit tests
}
```

Each region schedule is fixed per scenario: for example, S1 has far-only for 0–30 s, near-only for 30–60 s. S3 alternates 5 s blocks of far-only, near-only and double-talk.

## Synthetic meeting folders (file-contract integration)

```swift
public struct MeetingFolderSpec: Sendable {
    public var micSegments: [MicSegmentSpec]      // each: duration, device kind (.mono, .builtInArray(ArrayParams), .interface([ChannelSpec])), echo params
    public var systemGapAt: [Double]              // seconds; inserts silence + timeline gap event
    public var writeTimelines: Bool = true
    public var writeChannelFiles: Bool = true
    public var writePCMReference: Bool = false
}
public enum MeetingFolderWriter {
    /// Writes mic.aac (mean-of-live mono, 24 kHz AAC), mic.segK.chN.aac, system.aac, timelines (via CaptureFiles writer),
    /// optional system.ref.caf — mirroring capture's real output format exactly. Returns paths + ground truth.
    public static func write(_ spec: MeetingFolderSpec, to directory: URL, seed: UInt64) throws -> MeetingFolderTruth
}
```

`MeetingFolderWriter` encodes AAC with the same `EncoderSettings.voice` parameters and the same 48→24 kHz conversion through `AVAudioConverter`. It does **not** call `MicCaptureSession`, because it must not depend on capture internals. The parity between this writer and capture is checked by one test in `AudioCaptureTests`, `captureOutput_matchesTestKitConventions`: the same synthetic input through `MicCaptureSession` and through `MeetingFolderWriter` gives identical file names, timeline events and AAC durations.

## Metrics

Ground truth comes from the test kit; real-data estimates come from `AudioProcessing.EchoMetrics`.

```swift
public enum Metrics {
    public static func erleDB(input: [Float], output: [Float], over regions: [Range<Int>]) -> Double          // 10log10(Σin²/Σout²)
    public static func siSDR(estimate: [Float], target: [Float], over regions: [Range<Int>]) -> Double       // scale-invariant SDR
    public static func speechLoudnessDBFS(_ x: [Float], vadFrom truth: [Float]) -> Double                   // RMS over truth-active frames
    public static func peakDBFS(_ x: [Float]) -> Double
    public static func clippedSampleCount(_ x: [Float], ceilingDBFS: Double) -> Int
    public static func correlation(_ a: [Float], _ b: [Float]) -> Double
    public static func realTimeFactor(seconds: Double, audioSeconds: Double) -> Double
}
```

## Consumers and dependency wiring

- `AudioProcessing` package: product `AudioProcessingTestSupport`, a library depending on `AudioProcessing`, `CaptureFiles` and AVFoundation. It's used by `AudioProcessingTests` and `audioproc-cli`.
- `AudioCapture` package: its test target may **not** depend on `AudioProcessing`, because that would create a package dependency cycle (`AudioProcessing` depends on `AudioCapture`). So `captureOutput_matchesTestKitConventions` lives in `AudioProcessingTests` instead. That works because `AudioProcessing` can see `AudioCapture`'s public API. To make that possible, `AudioCapture` exposes a testing seam:
  - an `@_spi(Testing) public` factory that creates a `MicCaptureSession` in a test mode;
  - with a synchronous `flushWriter()`;
  - that accepts synthetic `AVAudioPCMBuffer`s through the tap handler.

  This is the only cross-package test, and it keeps the two writers honest. `AudioProcessing`'s test target adds the `AudioCapture` product as a dependency.

## Test plan (self-tests in `AudioProcessingTests/TestKit`)

| Test | Verifies |
|---|---|
| `generators_deterministicForSeed` | Same seed → identical arrays; different seed → different arrays |
| `echoSimulator_delayAndENR` | The measured delay (xcorr) equals the param ±1 sample; the ENR is within ±0.5 dB |
| `echoSimulator_driftResamplesLength` | Length changes by drift × duration |
| `arraySimulator_lagsGainsPolarity` | Per-capsule measurements match the params |
| `codec_aacRoundTrip_preservesSpeech` | Correlation ≥ 0.95 after alignment |
| `metrics_siSDR_knownValues` | Analytic cases (target + scaled noise) match closed-form values |
| `meetingFolderWriter_producesReadableContract` | `CaptureTimelineReader` parses it; all files decode; ground truth is aligned |
| `captureOutput_matchesTestKitConventions` | Capture parity (above) |

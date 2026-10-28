---
status: complete
---

# Component: Echo Cancellation Engines, Packaging and Bake-off

## Purpose and scope

Provide reference-based acoustic echo cancellation (AEC) for `AudioProcessing` through one protocol. Package two candidate engines as source-vendored SPM targets. Run a reproducible bake-off that picks the default.

The driver that feeds engines (segments, aligned reference, latency compensation, failure restore) is in [audio_processing.md](./audio_processing.md#stage-3--echo-cancellation-driver).

Background on the engines, with sources: [research: AEC options](../../../research/builtin-mic-voice-processing/post-processing/aec-options.md) and [failure modes](../../../research/builtin-mic-voice-processing/post-processing/aec-failure-modes.md).

## Protocol and factory

```swift
public enum EchoCancellerKind: String, Sendable, Codable, CaseIterable { case webRTCAEC3, localVQE, speex }

/// Not Sendable: one instance per processing run, used on one queue.
public protocol EchoCanceller: AnyObject {
    var kind: EchoCancellerKind { get }
    /// Samples per call at 16 kHz (AEC3: 160, LocalVQE: 256, Speex: 160).
    var frameSize: Int { get }
    /// Algorithmic delay of `output` relative to `mic`, in samples (driver compensates).
    var latency: Int { get }
    /// Processes exactly `frameSize` samples. `reference` is the pre-aligned far-end
    /// (echo lags it by ~20 ms). Writes `frameSize` samples to `output`.
    func process(mic: UnsafeBufferPointer<Float>,
                 reference: UnsafeBufferPointer<Float>,
                 output: UnsafeMutableBufferPointer<Float>) throws
}

public enum EchoCancellerError: Error, Equatable {
    case unavailable(EchoCancellerKind)       // not compiled in / failed packaging gate
    case initializationFailed(String)
    case processingFailed(String)
}

public enum EchoCancellerFactory {
    /// Engines compiled into this build (bake-off losers are removed in Phase 6).
    public static var available: [EchoCancellerKind] { get }
    /// The shipping default; set by the bake-off (Phase 3), confirmed at Checkpoint 1.
    public static let defaultKind: ProcessingOptions.Echo
    public static func make(_ kind: EchoCancellerKind) throws -> any EchoCanceller
}
```

Samples are Float32 in [−1, 1]. Each wrapper converts to whatever its engine needs (int16 for Speex, float for the others) inside preallocated buffers. No wrapper allocates per frame.

## Vendoring rules (all engines)

- Sources go under `Packages/AudioProcessing/Vendor/<name>-<version>/`, unmodified where possible. Each directory gets:
  - the upstream `LICENSE` (plus `PATENTS` for WebRTC);
  - a `VENDORED.md` covering: upstream URL, tag or commit, tarball SHA-256, the file subset kept and why, every local modification as a patch summary, and how to update.
- SPM targets reference these sources through `path:` plus `sources:` and `exclude:` lists, or through symlinked `Sources/C<Name>/` directories if SPM path rules require it. Put a thin C shim (`include/<name>_shim.h` and `shim.cc`) in front of each, so Swift sees a small C API.
- Compiler settings:
  - `cxxLanguageStandard: .cxx17` (package level);
  - `cSettings`/`cxxSettings` of `.unsafeFlags(["-O2", "-w"])`, plus the required `define`s;
  - no Objective-C;
  - CPU only, with no Metal, OpenMP, BLAS or runtime-loaded backends.
- No network access or downloads at build or run time. Model weights are SPM resources (`.copy`).
- Lint and format exclude `Vendor/**`. The licences are added to `THIRD_PARTY_NOTICES.md`.

## Engine A: WebRTC AEC3 (`CWebRTCAEC3`)

**Sources, in order of preference.** The coding agent evaluates them in this order and records the choice in `VENDORED.md`:
1. [Enaium/webrtc-aec3](https://github.com/Enaium/webrtc-aec3): a standalone extraction of AEC3 that builds a dylib. Use it if its license headers are intact (BSD-3), it builds as plain C++17 without GN, and it doesn't pull in the full WebRTC base.
2. [freedesktop webrtc-audio-processing 2.1](https://www.freedesktop.org/software/pulseaudio/webrtc-audio-processing/): only the `modules/audio_processing/aec3`, `api/audio`, `common_audio`, `rtc_base` and `system_wrappers` subsets needed for `EchoCanceller3`, plus the abseil-cpp subset those headers require (vendored separately, Apache-2.0).

**Shim API** (`webrtc_aec3_shim.h`):

```c
typedef struct aec3_handle aec3_handle;
aec3_handle* aec3_create(int sample_rate_hz /*16000*/);   // mono render + mono capture
void aec3_destroy(aec3_handle*);
int aec3_analyze_render(aec3_handle*, const float* ref, int frames /*160*/);   // returns 0 on success
int aec3_process_capture(aec3_handle*, float* mic_in_out, int frames /*160*/);
```

- **Implementation:** use `EchoCanceller3` directly with `EchoCanceller3Config()` defaults, at 16 kHz, mono.
  - Per frame: `AnalyzeRender(ref)` then `ProcessCapture(mic, level_change=false)`.
  - Do **not** use the full APM, which would bring in NS, AGC and the high-pass filter we don't want.
  - Leave `use_external_delay_estimator` as `false`, so the internal estimator refines the residual delay after our coarse alignment.
  - The input scaling AEC3 expects (int16-range float vs. [−1, 1]) is handled in the shim. Upstream `AudioBuffer` uses the int16 range for float processing, so multiply by 32768 on the way in and divide on the way out.
- **Swift wrapper:** `WebRTCAEC3EchoCanceller` with `frameSize = 160` and `latency = 0`. A non-zero return code throws `.processingFailed`.

## Engine B: LocalVQE v1.4-AEC (`CLocalVQE`)

- **Sources:**
  - [localai-org/LocalVQE](https://github.com/localai-org/LocalVQE) at the tag that ships v1.4-AEC;
  - the ggml revision LocalVQE pins (MIT), CPU backend only. Build a single ARM64 CPU variant: `GGML_NATIVE=OFF`, `GGML_BACKEND_DL=OFF`, no OpenMP and no Metal. The `ggml-cpu` NEON paths compile for arm64 Apple silicon.
- **Model:** `localvqe-v1.4-aec.gguf` (203K parameters), bundled as a resource in the `AudioProcessing` target and loaded through `Bundle.module`. If LocalVQE keeps a built-in SHA-256 allowlist, the bundled file must match it; the test `localVQE_modelHashMatchesAllowlist` asserts this.
- **Shim API:** a direct pass-through of LocalVQE's C API: `localvqe_new(path)`, `localvqe_process_frame_f32(ctx, mic, ref, 256, out)`, `localvqe_free(ctx)`. Threads are fixed at 1, for determinism and to avoid contention with WhisperKit.
- **Swift wrapper:** `LocalVQEEchoCanceller` with `frameSize = 256` and `latency` taken from the LocalVQE API if it exposes one. Otherwise it's measured once in a test (impulse in, peak position out) and hard-coded with a comment.

## Fallback: SpeexDSP (`CSpeexDSP`)

This is added only if both A and B fail the packaging gate within Phase 3. Use [xiph/speexdsp](https://github.com/xiph/speexdsp) (BSD):
- `speex_echo_state_init(160, 4096)`, with a 256 ms tail at 16 kHz;
- `speex_preprocess_state_init` with `SPEEX_PREPROCESS_SET_ECHO_STATE` for residual suppression;
- denoise and AGC disabled.

`frameSize = 160`, `latency = 0`. Int16 conversion happens in the wrapper.

## Packaging gate (Phase 3)

A candidate passes the gate when **all** of these hold, on the CI runner (macos-15, Xcode 26.3) and locally:
1. `swift build` and `swift test` for `Packages/AudioProcessing` succeed in debug and release.
2. `make build-app` succeeds with the engine linked through Transcription into `BiscottiTranscriber.xpc` (the LocalVQE resource included).
3. The engine smoke tests pass: S1 ERLE ≥ 15 dB, and S7 passthrough SI-SDR ≥ 25 dB.
4. There's no network access at build or run time, no runtime-loaded backends, and the licences are recorded.

**Time-box:** if a candidate isn't passing the gate after a reasonable, bounded effort in Phase 3, say two focused coding rounds after the first build attempt, drop it. Record the reason in the bake-off report and continue with the other candidate. If both fail, add SpeexDSP and continue. This rule exists so the project never stalls on packaging.

## Bake-off {#bake-off}

`audioproc-cli bakeoff` (`make bakeoff`) runs, for each available engine and each scenario in `ScenarioLibrary.bakeoff` (from the [test-signal kit](./test_signal_kit.md)):

| ID | Scenario (real-speech near/far from fixtures; 60 s each) | Primary metric |
|---|---|---|
| S1 | Linear echo: 60 ms delay, RIR RT60 0.25 s, ENR +6 dB, far-end only for 0–30 s, then near-end only | Far-end-only ERLE |
| S2 | S1 + soft-clip speaker nonlinearity (tanh drive 2.0) | ERLE |
| S3 | Double-talk: near and far overlapping for 50% of the time, ENR 0 dB | Near-end SI-SDR in double-talk and in near-only regions |
| S4 | S1 + 100 ppm clock drift | ERLE |
| S5 | S1 with the reference passed through AAC 24 kHz/64 kbps encode + decode | ERLE |
| S6 | S1 with an 800 ms delay | ERLE (tests pre-alignment) |
| S7 | No acoustic echo (headphones): mic = near + noise | Passthrough SI-SDR; `echoDetected == false` |

Every scenario runs through the **real pipeline** (`MeetingAudioProcessor` with `echoCancellation = kind` and levelling **off**), so alignment and the driver are part of what's measured. Metrics come from `AudioProcessingTestSupport.Metrics` against ground truth.

**Report:** written to `specs/projects/passive_mic_pipeline/bakeoff_report.md` (committed), plus optional JSON. It contains:
- the environment (machine, OS, Xcode, engine versions);
- a table of scenario × engine, with every metric and the real-time factor (wall-clock processing time ÷ audio duration, single run, release build);
- gate pass/fail per F3.3;
- scores per F3.4;
- the selected default, with the rule that selected it;
- any packaging-gate drops.

**Selection** follows [functional_spec.md](../functional_spec.md) F3.4 exactly. The result is written into `EchoCancellerFactory.defaultKind` in the same Phase 3 commit.

## Test plan (`AudioProcessingTests`)

| Test | Verifies |
|---|---|
| `factory_available_matchesCompiledEngines` | `available` lists the compiled-in engines; `make` throws `.unavailable` otherwise |
| `<engine>_frameContract` | Wrong-size buffers are rejected (precondition in debug, throw in release) and outputs are finite |
| `<engine>_smoke_S1_erle15dB` | Each available engine reaches ERLE ≥ 15 dB on a 20 s S1 |
| `<engine>_smoke_S7_passthrough` | SI-SDR ≥ 25 dB with no echo present (pipeline skip **and** direct engine call with a silent reference) |
| `<engine>_latency_measured` | Impulse response peak at `latency` ±1 |
| `<engine>_deterministic` | Two runs give identical output |
| `localVQE_modelResourceLoads_andHashMatchesAllowlist` | Bundle lookup and the hash check |
| `bakeoff_runsAllScenarios_smallConfig` | The CLI's bake-off with 5 s scenarios produces a well-formed report (keeps the CLI from rotting in CI) |

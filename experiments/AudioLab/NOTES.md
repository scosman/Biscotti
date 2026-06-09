# AudioLab — experiment notes & learnings

Working notes for the AudioLab capture experiment. (Hardware-validated test
scripts live in [`VALIDATION.md`](VALIDATION.md); the deep mic-level writeup lives
in [`research/audio/mic_capture_level_findings.md`](../../research/audio/mic_capture_level_findings.md).)

---

## Building / running this experiment

AudioLab is a **standalone XcodeGen macOS app** (`AudioLab.xcodeproj`, scheme
`AudioLab`, generated from `project.yml`) — it is **not** part of the SPM
workspace, so:

- `make` / `hooks-mcp` (`build`, `test`, `build-app`) only touch the SPM
  `Packages/` + the main `App/` — **never** `experiments/`.
- `.swiftlint.yml` `included:` is only `Packages` + `App`, so AudioLab is **not
  linted** and not part of `make ci`.
- Build/run it directly: `xcodebuild -project AudioLab.xcodeproj -scheme AudioLab`
  (or open in Xcode). It runs on Apple-silicon hardware.

**Agents can't build it from the sandbox** (`xcodebuild` and `xcodegen` both fail
under the agent seatbelt; XcodeBuildMCP here is simulator-only). Verify changes by
review; a human builds on hardware. Adding a **new** source file requires
`xcodegen generate` (the project uses explicit file refs, not synchronized
folders) — if you can't run it, fold new code into a file already in the project.

---

## Mic capture: built-in mic records near-silent during meetings

**Symptom:** capturing the built-in mic via `AVCaptureSession` while a meeting app
is active yields a valid but near-silent file (~0.004 peak, ≈ −48 dBFS).

**Root cause (main):** the built-in mic's multichannel stream is the **raw
beamformer element taps**, which have tiny intrinsic gain. The loud, normalized,
echo-cancelled mono only exists *after* Apple's **VoiceProcessingIO (VPIO)**
pipeline. The raw array is meant for Apple's stream processing, not general taps —
us getting switched onto it is a gnarly side effect. (All 3 channels carry similar
*low* signal, so it's not a single-channel/downmix problem.)

**Root cause (minor):** voice-processing apps also AGC-duck the shared input
volume — `kAudioDevicePropertyVolumeScalar` (input) = **0.27 in a Meet call vs
0.67 idle**. But forcing it back to 1.0 did **not** meaningfully help (tested &
reverted); the raw-array gain dominates.

**Plan — try in this order** (full detail + sources in the research doc):
1. **VPIO path** — `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)`; the
   only route to the processed loud mono. Spike first (VPIO faulted on this
   hardware before). See VPIO gotcha below.
2. **Software makeup gain** on the current AVCaptureSession path — interim, noisy.
3. **Audio-Hijack-style** — process taps + makeup-gain blocks (most robust, most
   work).

### VPIO 9-channel gotcha (Scripta precedent)
When VPIO is enabled the mic format **silently becomes 9 channels**. Extract
**channel 0 manually** — do **not** use `AVAudioConverter` for the channel
reduction (it crashed on the real-time audio thread). Disable other-audio ducking:
`inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)`.
Source: "Scripta" whisper.cpp meeting recorder — https://dev.to/thehwang/building-a-100-local-meeting-transcription-app-for-macos-with-whispercpp-and-screencapturekit-33m7

---

## Already-fixed bugs on the AVCaptureSession mic path
- 3-channel buffers dropped (empty file): `AVAudioFormat(streamDescription:)`
  returns nil for >2 channels without a layout. Fixed by attaching the
  `CMFormatDescription`'s channel layout.
- Discrete 3ch→mono via `AVAudioConverter` produced silence (no error). Fixed by
  a manual averaging downmix, then mono→mono resample.
- Added verbose diagnostics: per-subsystem `os.Logger`, a 2 s heartbeat with
  buffer/frame counters, per-channel input peaks + output peak, stall/no-data
  watchdogs, and device + input-volume introspection.

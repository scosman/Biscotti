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
   hardware before). See VPIO gotcha below. **← implemented, awaiting hardware run
   (see "VPIO path — implemented" below).**
2. **Software makeup gain** on the current AVCaptureSession path — interim, noisy.
3. **Audio-Hijack-style** — process taps + makeup-gain blocks (most robust, most
   work).

### VPIO path — implemented (A/B switchable), pending hardware validation
`Sources/VPIOMicCapture.swift` (new) is a second `MicCapturing` implementation
alongside `MicCapture` (the AVCaptureSession path). Both are selected by one
flag — `RecordingCoordinator.useVoiceProcessingMic` (default **`true`**) — so we
can A/B on hardware without deleting the AVCaptureSession path. Both write the
same `_mic.aac` (mono 24 kHz ADTS-AAC) via the shared `MicCaptureFileHelper`, and
both honour the same `onStarted(hostClockSeconds)` / `onUnrecoverableError` /
`start()` / `stop()` contract, so the mic-first ordering and timestamp-aligned
system track are unchanged. `onStarted`'s anchor comes from the first tap
buffer's `when.hostTime` via `AudioConvertHostTimeToNanos` — the **same clock
base** `SystemAudioCapture` aligns against.

What `VPIOMicCapture` does (per the gotchas below): enables VP, disables
other-audio ducking, queries the post-VP input format, **extracts channel 0
manually** (the processed mono; `MicCaptureFileHelper.extractChannel0` — never
`AVAudioConverter` for the channel reduction), resamples mono→mono to 24 kHz,
drives a **muted silent output node** so the VPIO *duplex* unit keeps cycling its
IO, and rebuilds the engine on `.AVAudioEngineConfigurationChange` (route change /
meeting start). It mirrors `MicCapture`'s diagnostics (2 s heartbeat, per-source-
channel peaks, output peak, no-buffer / stall / no-write watchdogs) — this is
also the **spike**: the engine-build log says plainly whether VP enables, what
input format it presents, and whether buffers flow. **The no-buffer watchdog
firing ≈ the old board-ID / downlink-DSP fault → fall back (flip the flag to
`false`).**

> **Build step:** `VPIOMicCapture.swift` is a **new** file and the project uses
> explicit file refs, so run **`xcodegen generate`** in `experiments/AudioLab/`
> once before building (otherwise the build fails with "Cannot find
> VPIOMicCapture / MicCapturing in scope"). **Success criterion:** output peak
> rises to a normal speaking level (> ~0.05) **and stays loud while a meeting app
> (Meet/FaceTime) holds the mic** — the case the AVCaptureSession path fails.

#### Hardware run 1 (2026-06-08): VPIO **initializes now**; `-10875` from a duplex rate mismatch
Big update vs the phase-9 "VPIO faults / can't init" finding: **VP enabled
successfully** on the M-series Mac, macOS 15 (`setVoiceProcessingEnabled(true)`
returned; input tap format = **48 kHz, 9 ch** — the expected 9-channel surprise).
The `Cannot retrieve theDeviceBoardID` + `vpStrategyManager … GetProperty` lines
still appear but are **non-fatal noise** this time, not a hard fault.

The blocker was **`-10875` (`kAudioUnitErr_FormatNotSupported`,
`AUVPAggregate.cpp: client-side input and output formats do not match`)** at
`engine.start()` → `Initialize`. Root cause: VPIO is **one duplex audio unit**
sharing a single IO clock, and the **silent-output driver** (added for the
duplex gotcha) pulled the **default output device at 44.1 kHz** into the unit
alongside the **48 kHz mic input** — it can't span the two rates. So driving the
output *caused* the failure rather than preventing starvation.

**Action:** `driveSilentOutput` defaulted to **`false`** → run VPIO **input-only**
(the beamformed/normalised mono we want is produced on the *input* path; we only
forgo echo-cancellation, which needs an output reference we don't have and which
phase 9 already accepted forgoing). Next hardware run tests whether input-only
(a) avoids `-10875` and (b) delivers buffers with a loud ch0. If input-only
**starves** (no-buffer watchdog), the fallback is to match the output device's
nominal sample rate to the input's (48 kHz) *and* re-enable the output driver —
not the mixer-at-44.1 kHz path that just failed.

#### Hardware run 2 (2026-06-08): input-only is loud but **choppy** — downlink needs a driven output
Input-only **started cleanly** (no `-10875`) and the **level was fixed**:
`VPIO source channel peaks: ch0=0.5363 …` (vs ~0.004 on the AVCaptureSession
path) — VPIO's *uplink* processing (gain/beamform) works. **But** the log flooded
with `failed to run downlink DSP (I/O fault)` + `audio time stamp does not have
valid sample time`: with nothing rendering to the output, the duplex unit's
**downlink** half had no valid timestamps and faulted every IO cycle, stuttering
the shared clock → the mic arrived in irregular ~100 ms bursts (`frames=4800`) →
**choppy audio with gaps** (and occasional clipping). So input-only doesn't
"starve" to zero — it destabilises.

**Fix (current):** drive the muted silent output **and** first raise the default
**output** device's nominal rate to the input's (48 kHz) via
`ensureOutputRateMatchesInput` so the two duplex scopes share one IO clock —
addressing both the `-10875` (run 1) and the downlink fault (run 2) at once.
`driveSilentOutput` back to **`true`**. The output device rate is **restored on
stop** (`restoreOutputRate`).

> **Side effect:** while recording, the system **output** device is forced to
> 48 kHz (one brief audio glitch at start + one at stop as the HAL re-clocks);
> restored on stop. Acceptable for validation; revisit for production.

#### Hardware run 3 (2026-06-08): the device rate-match worked, but the *connection* format didn't
The output device **did** move to 48 kHz (`raising output device 110 … → 48000Hz …
output device confirmed at 48000Hz`), yet the silent driver still attached at
**44.1 kHz** (`attached … driver (44100Hz 2ch …)`) → `-10875` again. Cause: the
format was read from **`engine.mainMixerNode.outputFormat(forBus:0)`, which is a
software-default 44.1 kHz that ignores the hardware device rate**; routing silence
through the mixer pinned the VPIO output scope to 44.1 kHz while the input was
48 kHz. **Fix:** bypass the mixer — connect the silence node **straight to
`outputNode`** with its **rate forced to the VPIO input rate** (`tapFormat`
sample rate), channels from the output HW. Run 4 to confirm init + smooth audio.

**Still open (separate, pre-existing — *not* the mic):** the **system** track logs
`Input data proc returned inconsistent … 8 bytes per packet` because the global
tap delivered **6 ch** (`FIRST system audio buffer (512 frames, 6ch)`) while
`SystemAudioCapture`'s ExtAudioFile client format is 2 ch. That's a
`SystemAudioCapture` channel-count bug, independent of the VPIO mic work — address
next.

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

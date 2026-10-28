# What earlier experiments already tried and found

Sources:
- `specs/research/audio/README.md`, `phase9_validation_findings.md`, `mic_capture_level_findings.md`, `hardware_debugging_workflow.md`, `display_audio_startup_failure.md`
- `experiments/AudioLab/NOTES.md` and `VALIDATION.md`
- `experiments/AudioLab/Sources/MicCapture.swift`, `VPIOMicCapture.swift`, `RecordingCoordinator.swift`, `CoreAudioHelpers.swift`

All hardware runs below were on an Apple M4 (or "M-series") MacBook Pro with macOS 15, unless stated otherwise.

## Timeline of decisions

| When | Path | Result | Where recorded |
|---|---|---|---|
| R1 research | Plan: `AVAudioEngine` input tap for the mic | VPIO not considered necessary. Two separate tracks kept so AEC could be done later "using the system-audio stream as a reference" | `specs/research/audio/README.md` §2 |
| Phase 9 (V1 validation) | **Plain `AVAudioEngine`** input tap | Worked. Built-in mic = **3 ch @ 48 kHz Float32**. Two writer bugs from the 3-channel format (frame-count crash; client-format mismatch giving a silent file), both fixed | `phase9_validation_findings.md` #1, #5 |
| Phase 9 | **VPIO** (`setVoiceProcessingEnabled(true)`) | **Rejected:** `Cannot retrieve theDeviceBoardID`, `vpStrategyManager … GetProperty`, `failed to run downlink DSP (state fault)`, a "bogus **9-channel / 44.1 kHz**" format, converter mismatches, empty mic file | `phase9_validation_findings.md` #1; repeated in the stale `stage_a_foundations` spec |
| Phase 9 | Tradeoff accepted | "we forgo Apple's acoustic echo cancellation… on speakers, the remote audio… bleeds faintly into the mic track; on headphones there is no bleed… recommend headphones, or subtract echo in post" | `phase9_validation_findings.md` #2 |
| Later (date not recorded) | AudioLab's "original" mic path became **`AVCaptureSession` + `AVCaptureAudioDataOutput`** (`MicCapture.swift`) | — | `RecordingCoordinator.swift:12-21` calls `MicCapture` "the original `AVCaptureSession` path (records the raw beamformer array; near-silent during meetings)" |
| 2026-06-08 | AVCaptureSession, built-in mic, with a meeting app active | **Near-silent:** peak ~0.003–0.005 (≈ −48 dBFS). 3 ch, 44.1 kHz, all channels similarly low | `mic_capture_level_findings.md` |
| 2026-06-08 | VPIO runs 1–4 (`VPIOMicCapture.swift`) | Run 4 **works:** loud, smooth, processed mono. Requires output reclock + silent output wired direct to `outputNode` | `NOTES.md`, `mic_capture_level_findings.md` §1 |
| 2026-06-09 | VPIO × macOS Mic Mode | Standard, Voice Isolation and Wide Spectrum are audibly different. Voice Isolation removes system-audio bleed | `mic_capture_level_findings.md` |
| Production (`Packages/AudioCapture`) | VPIO port of `VPIOMicCapture` | Shipped. See [production-behaviour.md](./production-behaviour.md) | code |
| 2026-09-29 → 10-08 | VPIO startup on Bose NC 700 + Dell displays, and on a Samson C01U USB mic + µDAC | VP's aggregate reconfigures about 300 ms after start, and AVAudioEngine stops before the first buffer, giving 0-byte `mic.aac`. Fixed by restarting the same engine in place. **Rebuilding VPIO repeatedly reproduced the failure.** | `display_audio_startup_failure.md`, PR #94/#101 |

## The 3-channel built-in array finding (phase 9 and mic-level doc)

- `phase9_validation_findings.md` #1: "The **default input device** on a current MacBook Pro reports **3 channels @ 48 kHz, Float32** (raw capsule feeds from the studio-quality 3-mic array)".
- The same finding warned: "**Do NOT hand-roll a downmix of the 3 raw capsules** (e.g. average them). That discards Apple's beamforming/noise-suppression and produces a *worse* signal than any normal app gets — and you don't need to: plain `AVAudioEngine` already presents the built-in array in a usable format, and `AVAudioConverter`/`AVAudioFile` handle the channel + rate conversion."
  - *Caveat:* AudioLab later found that `AVAudioConverter` maps a **discrete** multichannel layout to **silence** with no error (below). So "AVAudioConverter handles it" was not reliable for every layout. Phase 9's plain-engine success may depend on the layout the engine reported at the time.
- `mic_capture_level_findings.md` (AVCaptureSession path, meeting app active):
  - "The device delivers a **3-channel, 44.1 kHz, non-interleaved float32** stream (a beamforming mic array). All three channels carry **similar, low** signal (`ch0≈ch1≈ch2≈0.004`) — so it is **not** a 'only one channel has the audio' problem, and averaging is not what kills the level."
  - Logs: `src=[44100Hz 3ch …]`, `heartbeat src channel peaks: ch0=0.0033 ch1=0.0034 ch2=0.0045`, `outPeak=0.0036`.
  - **Root-cause hypothesis**, stated in the doc as a finding: "the built-in mic's multichannel stream is the raw beamformer element taps, which have tiny intrinsic gain… The raw array appears to be **designed for Apple's own stream processing, not general-purpose taps**. When another app engages voice processing the device stays in this 3-channel array mode, and a plain (non-VP) capture client like ours is handed the raw, quiet taps."
  - **Secondary:** the input volume scalar dropped: "`kAudioDevicePropertyVolumeScalar` (input scope): **vol=0.27 with Google Meet in a call vs. vol=0.67 idle** (cf. WebKit Bug 218012)… forcing the HAL input volume back to 1.0 did **not** meaningfully restore the level (tested in AudioLab and reverted)."
- **Gap:** the near-silent measurement was made on the **AVCaptureSession** path. I found no repo record of the **plain AVAudioEngine** (non-VP) tap's level during a meeting. Phase 9 only showed that it was non-empty. The closest data point is from outside the repo docs: javimoya on [#118](https://github.com/scosman/Biscotti/pull/118#issuecomment-6446547910) measured a plain AVAudioEngine tap on a built-in mic during a Teams call at "−30 to −40 dBFS" vs. "−19 to −25" with VPIO. The metric is not stated (likely a typical level, not a peak). That is quieter but not near-silent. These measurements are **not directly comparable** with AudioLab's −48 dBFS peak.

## Channel counts seen for the built-in mic

The owner's latest comment speaks of "a fancy 7 channel array mix" ([#66](https://github.com/scosman/Biscotti/issues/66#issuecomment-6470640519)). The repo evidence shows different counts depending on path and state. **I found no 7-channel observation recorded anywhere in the repo or the threads.**

| Path / state | Channels | Rate | Source |
|---|---|---|---|
| Plain AVAudioEngine input tap (phase 9, M4 MBP) | 3 | 48 kHz | `phase9_validation_findings.md` #1 |
| AVCaptureSession, while a VP meeting app holds the mic | 3 | 44.1 kHz | `mic_capture_level_findings.md` |
| VPIO enabled (phase 9, faulting) | 9 | 44.1 kHz | `phase9_validation_findings.md` #1 |
| VPIO enabled (AudioLab run 1, working) | 9 | 48 kHz | `NOTES.md` run 1 |
| Plain (non-VP) AVAudioEngine tap per PR #115, "when the default input and output devices run at the same rate" | 9 | ? | [#115 body](https://github.com/scosman/Biscotti/pull/115) |
| Plain AVAudioEngine tap per PR #118 author's live log | 1 ("48 kHz mono tap") | 48 kHz | [#118 body](https://github.com/scosman/Biscotti/pull/118). Device not stated. |
| VPIO on Audient iD24 (not built-in) | 28 = "mic channel count: 12, ref channel count: 16" | 48 kHz | alserevs, [#66](https://github.com/scosman/Biscotti/issues/66#issuecomment-5583791101) |

*Inference, unverified:* the iD24 log shows the VP aggregate exposing **mic + reference (output) channels** (12 + 16 = 28). By analogy, the built-in 9-channel VP format could be 3 mic capsules + 6 output-reference channels. 14/16-inch MacBook Pros are marketed with a six-speaker system; I did not verify that in this session, and the speaker count was not logged. alserevs's log also shows VPIO "enabled tap stream on" every output device. That could explain why PR #115 saw a 9-channel **non-VP** tap: another VP client may already have enabled reference tap streams on the device. This is a hypothesis for the "built-in mic array" and "VPIO behaviour" subtopics to check. It is not established. Two related facts are established: AudioLab's run-2 log shows **ch0** of the VP tap carrying the processed voice (`VPIO source channel peaks: ch0=0.5363 …`), and the Scripta precedent says the same ("Extract **channel 0**").

## VPIO runs 1–4 (how the current production design was reached)

From `experiments/AudioLab/NOTES.md` and `mic_capture_level_findings.md` §1:

1. **Run 1:** `setVoiceProcessingEnabled(true)` **succeeded**. The tap format was 48 kHz, 9 ch. The board-ID and `vpStrategyManager` lines still printed but were not fatal. `engine.start()` failed with **`-10875` (`kAudioUnitErr_FormatNotSupported`, `AUVPAggregate.cpp: client-side input and output formats do not match`)**: "VPIO is **one duplex audio unit** sharing a single IO clock, and the **silent-output driver**… pulled the **default output device at 44.1 kHz** into the unit alongside the **48 kHz mic input**."
2. **Run 2 (input-only, no output driven):** it started cleanly and "the **level was fixed**: `VPIO source channel peaks: ch0=0.5363 …` (vs ~0.004 on the AVCaptureSession path)". **But** "`failed to run downlink DSP (I/O fault)` + `audio time stamp does not have valid sample time`… the mic arrived in irregular ~100 ms bursts (`frames=4800`) → **choppy audio with gaps** (and occasional clipping)."
3. **Run 3:** the output device was raised to 48 kHz, but the silent node read its format from `mainMixerNode.outputFormat`, "a **software-default 44.1 kHz that ignores the HW rate**", so `-10875` came back.
4. **Run 4 (working):** "drive a silent source **straight to `outputNode`** with its rate **forced to the VPIO input rate** (bypassing the mixer), plus raise the output device's nominal rate to the input's (48 kHz)… smooth + loud processed mono. Output rate restored on stop (brief glitch at start/stop)." `NOTES.md` flagged this as "**Side effect:** while recording, the system **output** device is forced to 48 kHz… Acceptable for validation; **revisit for production**." This was not revisited before production.

**Why this matters now:** `ensureOutputRateMatchesInput()` and the silent output node both exist **only to keep a VPIO duplex unit running**. Neither is needed for a non-VP tap. The reclock was identified as a production risk in June and shipped anyway.

## Mic Mode and Voice Isolation (2026-06-09 hardware observation)

From `mic_capture_level_findings.md`:
- "toggling the macOS **Mic Mode** (Control Center → Mic Mode) between **Standard**, **Voice Isolation**, and **Wide Spectrum** produces an **audibly different** VPIO mic recording… **Voice Isolation noticeably isolates the voice from background / system-audio bleed**."
- "The raw AVCaptureSession + software-makeup-gain path (approach #2) gets **none** of this."
- The doc separates two mechanisms:
  - Reference-based AEC, "impractical for a *passive* recorder, for causality reasons: we obtain the system audio from the tap **after** it has already echoed into the mic".
  - Voice Isolation, "a *different*, reference-free mechanism — on-device ML voice/background separation".
  - *Note:* the causality argument is about **real-time** AEC. For offline AEC after capture, both tracks exist in full and causality is no concern. That belongs to the post-processing subtopic.
- Follow-ups that were proposed but **not implemented**: read `AVCaptureDevice.activeMicrophoneMode` / `.preferredMicrophoneMode`, surface `AVCaptureDevice.showSystemUserInterface(.microphoneModes)`, recommend Voice Isolation, and log the active mode in validation runs.
- Mic Mode is now relevant to the bug too. alserevs's workaround on #66 was a **different** Mic Mode per app, and their log has `Disabling HAL Voice Isolation support due to app's use of existing chat flavors`. See [user-reports.md](./user-reports.md).

## Other gotchas already learned (do not re-learn)

- **`AVAudioConverter` + a discrete multichannel layout produces silence with no error** when reducing to mono. Fixed on the AVCaptureSession path with a manual average (`MicCapture.swift` `downmixToMono`). Repeated in the `VPIOMicCapture` and production comments, and re-hit by PR #115 ("Feeding discrete multichannel input to `AVAudioConverter` silently produces silence").
- **`AVAudioFormat(streamDescription:)` returns nil for more than 2 channels without a channel layout**, so every buffer is dropped. Fixed by attaching the `CMFormatDescription` layout (`MicCapture.swift` `audioFormat(from:asbd:)`).
- **`AVAudioConverter` crashed on the real-time thread when used for VPIO's 9→1 channel reduction.** This is the Scripta precedent ([dev.to/thehwang](https://dev.to/thehwang/building-a-100-local-meeting-transcription-app-for-macos-with-whispercpp-and-screencapturekit-33m7)), cited in `mic_capture_level_findings.md`. It is why channel 0 is copied by hand.
- **Give `AVAudioConverter` a fresh input buffer per call.** Reusing one garbled the 48→24 kHz mic audio (`hardware_debugging_workflow.md` §5–6).
- **Route changes destroy the device.** "starting/accepting a FaceTime call mid-recording killed the mic" on plain AVAudioEngine (`phase9_validation_findings.md` #2). This is handled with `.AVAudioEngineConfigurationChange`. Any non-VP replacement must keep this handling.
- **Benign VPIO log noise** (`hardware_debugging_workflow.md` §1):
  - `Cannot retrieve theDeviceBoardID string`
  - `failed to run downlink DSP` / `ProcessDownlinkAudio 'stat'` (once per VPIO start)
  - `Error getting channel layout from agg device on bus 1` (VPIO aggregate setup)
- **Mic permission denial is silent.** Preflight `AVCaptureDevice.authorizationStatus(for: .audio)` (`phase9_validation_findings.md`, permission section). This is already in production.

## The ranked fallback plan that was never executed

From `mic_capture_level_findings.md` "Remaining approaches — try in this order":
1. VPIO. This is what shipped.
2. "**Software makeup gain** on the current AVCaptureSession path… e.g. ~+20–30 dB, clamped to [−1, 1]… **amplifies quiet, noisy, non-AEC raw audio** and is still subject to the AGC duck under contention." Also unverified: "`AVCaptureAudioChannel.volume` supports >1.0 on macOS but may only apply to file/preview outputs".
3. "**Audio-Hijack-style**: process taps + makeup-gain blocks… Krisp goes further with a virtual HAL device (`AudioServerPlugin`) that owns the hardware as sole client". Marked as most work. Belongs to the prior-art subtopic.

Approaches 2 and 3 were never tried. Nothing in the repo measures whether the built-in mic tap's level problem is constant gain, which makeup gain would fix, or input-volume ducking by the other app's AGC, which would vary over time. The owner calls it "wildly inconsistent levels".

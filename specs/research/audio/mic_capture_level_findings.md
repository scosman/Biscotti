# Mic capture level findings — quiet built-in mic during meetings

**Status:** active investigation (AudioLab experiment). **Hardware:** Apple-silicon
MacBook, macOS 15+. **Date:** 2026-06-08.

This documents why the built-in microphone, captured via `AVCaptureSession`,
records **extremely quiet** audio while a meeting app is running — and the ranked
plan for fixing it. It is a follow-on to the Phase 9 validation
([`phase9_validation_findings.md`](phase9_validation_findings.md)).

---

## Symptom

Recording the built-in mic ("MacBook Pro Microphone") via `AVCaptureSession` +
`AVCaptureAudioDataOutput` while a meeting app (FaceTime; or a browser meeting
whose audio process is `com.apple.WebKit.GPU`; Siri/`com.apple.CoreSpeech` also
present) is active produces a **valid but near-silent** file: peak |sample|
~0.003–0.005 (≈ **−48 dBFS**) during normal speech. Without a meeting app, levels
were fine.

Instrumented logs (AudioLab `MicCapture`) established the chain precisely:
- The device delivers a **3-channel, 44.1 kHz, non-interleaved float32** stream
  (a beamforming mic array). All three channels carry **similar, low** signal
  (`ch0≈ch1≈ch2≈0.004`) — so it is **not** a "only one channel has the audio"
  problem, and averaging is not what kills the level.
- Two earlier *crash/empty-file* bugs on this path were already fixed (see
  "Prior fixes" below); the remaining issue is purely **level**.

---

## Root cause

**Primary: the built-in mic's multichannel stream is the raw beamformer element
taps, which have tiny intrinsic gain.** The loud, normalized, noise-suppressed,
echo-cancelled signal a user expects only exists *after* Apple's voice-processing
pipeline (**VoiceProcessingIO / VPIO**) collapses the array to a single processed
channel. The raw array appears to be **designed for Apple's own stream
processing, not general-purpose taps**. When another app engages voice processing
the device stays in this 3-channel array mode, and a plain (non-VP) capture client
like ours is handed the raw, quiet taps. Us being switched onto that device format
is a gnarly side effect, not the intended use.

**Secondary (minor): voice-processing apps also AGC-duck the shared input gain.**
Measured via `kAudioDevicePropertyVolumeScalar` (input scope): **vol=0.27 with
Google Meet in a call vs. vol=0.67 idle** (cf. WebKit Bug 218012). This compounds
the quietness but is **not the main cause** — forcing the HAL input volume back to
1.0 did **not** meaningfully restore the level (tested in AudioLab and reverted).
The dominant factor is the raw-array gain itself.

### Evidence
- Logs: `src=[44100Hz 3ch …]`, `heartbeat src channel peaks: ch0=0.0033 ch1=0.0034 ch2=0.0045`, `outPeak=0.0036`.
- `default-input … vol=0.27` (Meet) vs `vol=0.67` (idle).
- Forcing `kAudioDevicePropertyVolumeScalar` input → 1.0 each heartbeat: little effect.
- See memory: `macos-mic-agc-ducking-measured`.

---

## Remaining approaches — try in this order

### 1. VPIO path (preferred — gives the *processed* mono we actually want)
**Status: WORKING on hardware (AudioLab `Sources/VPIOMicCapture.swift`) — smooth, loud,
processed mono.** This updates phase 9 finding #1 (which had VPIO as a hard fault).
Progression:
- **Run 1:** `setVoiceProcessingEnabled(true)` **succeeded** on M-series / macOS 15
  (input format 48 kHz **9 ch** — the expected surprise; the `theDeviceBoardID` /
  `vpStrategyManager` messages still print but are **non-fatal**). Blocked by **`-10875`
  (FormatNotSupported)** at `engine.start()`: VPIO is one **duplex** unit on a single IO
  clock, and the silent-output driver pulled the 44.1 kHz default **output** into the
  unit alongside the 48 kHz mic **input** — can't span both rates.
- **Run 2 (input-only):** started cleanly and the **level is fixed** (ch0≈0.54 vs
  ~0.004), but the **downlink** half faulted every cycle (`failed to run downlink DSP` /
  `audio time stamp does not have valid sample time`) because nothing rendered to the
  output → stuttered IO → **choppy mic with gaps**.
- **Run 3:** the device rate-match applied (output → 48 kHz) but the silent driver still
  attached at 44.1 kHz → `-10875` again. Cause: the format was read from
  `mainMixerNode.outputFormat`, a **software-default 44.1 kHz that ignores the HW rate**.
- **Resolved (run 4, WORKING):** drive a silent source **straight to `outputNode`** with
  its rate **forced to the VPIO input rate** (bypassing the mixer), plus raise the output
  device's nominal rate to the input's (48 kHz) so both duplex scopes share one clock.
  Result: VPIO initializes, no `-10875`, downlink faults gone, **smooth + loud processed
  mono**. Output rate restored on stop (brief glitch at start/stop).

A/B-switchable against the AVCaptureSession path via
`RecordingCoordinator.useVoiceProcessingMic` (default `true`); the
AVCaptureSession path is **not** removed. The implementation follows every
gotcha below — enable VP, disable other-audio ducking, query the post-VP input
format, **extract channel 0 manually** (`MicCaptureFileHelper.extractChannel0`,
never `AVAudioConverter` for the reduction), resample mono→mono to 24 kHz, write
the same ADTS-AAC `_mic.aac`. It additionally drives a **muted silent output
node** (VPIO is a duplex unit whose input may not service unless the output side
cycles) and rebuilds the engine on `.AVAudioEngineConfigurationChange`. The
`onStarted` t=0 anchor is the first tap buffer's `when.hostTime` via
`AudioConvertHostTimeToNanos` — the same clock base `SystemAudioCapture` aligns
against, so two-track alignment is preserved. Diagnostics mirror `MicCapture`
(heartbeat + per-channel/output peaks + watchdogs); this run **is** the spike
(finding below) — the no-buffer watchdog firing ≈ the board-ID/DSP fault, in
which case we fall back to approach #2. **Pass = output peak > ~0.05 and stays
loud while a meeting app holds the mic.**

#### VPIO inherits the system **Mic Mode** — incl. real system-audio isolation (hardware-observed, 2026-06-09)
**Observed:** toggling the macOS **Mic Mode** (Control Center → Mic Mode) between
**Standard**, **Voice Isolation**, and **Wide Spectrum** produces an **audibly
different** VPIO mic recording — the three modes are clearly distinguishable in the
captured file, and **Voice Isolation noticeably isolates the voice from background /
system-audio bleed**. So the VPIO path delivers the system's voice-processing-**mode**-
processed mono, and we get that isolation **for free**. The raw AVCaptureSession +
software-makeup-gain path (approach #2) gets **none** of this — a concrete reason to
prefer VPIO.

**This corrects the earlier "no isolation / no AEC" read, which conflated two different
mechanisms:**
- **Reference-based AEC** (subtract a known *downlink reference* from the mic) **is**
  impractical for a *passive* recorder, for causality reasons: we obtain the system
  audio from the tap **after** it has already echoed into the mic, so it can't serve as
  a real-time reference (a real-time AEC needs the reference *before* the echo; only an
  app that **owns playback**, e.g. a VoIP client or a Krisp-style virtual device, has
  that). This part of the earlier analysis stands.
- **Voice Isolation is a *different*, reference-free mechanism** — on-device ML
  voice/background separation that suppresses non-voice (incl. speaker bleed) **without**
  any reference signal — so the causality argument does **not** apply to it. This is why
  the user hears isolation despite reference-AEC being impractical. **Net: VPIO + Voice
  Isolation does buy us meaningful system-audio isolation on the mic track.**

**Implications / follow-ups:**
- **Mic Mode is a system-wide, user-chosen setting** (Control Center), not per-app by
  default. Apps can *read* the active mode (`AVCaptureDevice.activeMicrophoneMode` /
  `.preferredMicrophoneMode`) and surface the picker
  (`AVCaptureDevice.showSystemUserInterface(.microphoneModes)`), but the user picks it.
  Because it **materially changes our output**, we likely want to detect the active mode
  and/or recommend **Voice Isolation** in-app, and **record the active Mic Mode** in
  validation runs.
- Voice Isolation is not perfect cancellation, but combined with our **separate mic /
  system tracks** it materially reduces bleed; deeper cancellation, if ever needed,
  remains a **post-processing** step (cross-correlate the two tracks to find the delay,
  then subtract) — not a real-time VPIO reference.

Capture the mic as a **first-class VoiceProcessingIO client** via
`AVAudioEngine`'s `inputNode.setVoiceProcessingEnabled(true)`. This is the only
route to the loud, beamformed, echo-cancelled **mono** signal (the "after"
processed audio), and it inherently handles the meeting-app-contention case
because we become a proper VP client.

Known gotchas (from the **Scripta** precedent, a whisper.cpp macOS meeting
recorder — [dev.to/thehwang](https://dev.to/thehwang/building-a-100-local-meeting-transcription-app-for-macos-with-whispercpp-and-screencapturekit-33m7)):
- **VPIO silently changes the mic format to 9 channels.** Extract **channel 0**
  manually — do **not** rely on `AVAudioConverter` for the channel reduction (it
  crashed on the real-time audio thread). See memory `scripta-vpio-9-channel-format`.
- Disable ducking of other audio:
  `inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)`.

**Risk:** VPIO previously *faulted* on this hardware (board-ID / DSP
`state fault`; see `phase9_validation_findings.md` finding #1). That failure is
unrelated to the 3-channel/format issues and may recur — so **timebox a spike** to
confirm VPIO initializes on the current OS before committing. If it faults, fall
back to #2.

### 2. Software makeup gain on the current AVCaptureSession path (pragmatic fallback)
Apply a fixed digital gain in the sample pipeline (after the manual mono downmix,
before write), e.g. ~+20–30 dB, clamped to [−1, 1]. Fast and self-contained, but
**amplifies quiet, noisy, non-AEC raw audio** and is still subject to the AGC duck
under contention. Acceptable as an interim to get usable levels; not the processed
signal. (`AVCaptureAudioChannel.volume` supports >1.0 on macOS but may only apply
to file/preview outputs, not the data-output delegate path — verify before
relying on it; otherwise multiply samples directly.)

### 3. Audio-Hijack-style: process taps + makeup-gain blocks (most robust, most work)
Mirror how Rogue Amoeba's Audio Hijack handles capture: Core Audio **process taps**
into a private aggregate device read via an IOProc, with explicit **gain/"Magic
Boost" blocks** in the signal chain for level correction
([Rogue Amoeba KB](https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Audio-Capture-Details&product=Audio+Hijack)).
Krisp goes further with a virtual HAL device (`AudioServerPlugin`) that owns the
hardware as sole client
([Krisp KB](https://help.krisp.ai/hc/en-us/articles/4402174576402-How-Krisp-Microphone-and-Krisp-Speaker-work)).
Highest implementation cost (and a virtual device requires user plugin approval),
but fully sidesteps contention/ducking.

---

## Prior fixes on this path (already landed)
- 3-channel format dropped every buffer: `AVAudioFormat(streamDescription:)`
  returns nil for >2 channels without a channel layout → empty file. Fixed by
  attaching the `CMFormatDescription`'s channel layout.
- Discrete 3ch→mono via `AVAudioConverter` produced **silence** (no error). Fixed
  by manual averaging downmix at the source rate, then mono→mono resample.
- Extensive diagnostics added (per-subsystem `os.Logger`, heartbeat with
  buffer/frame counters + per-channel input peaks + output peak, stall/no-data
  watchdogs, device + input-volume introspection).

## Sources
- Scripta (VPIO meeting recorder): https://dev.to/thehwang/building-a-100-local-meeting-transcription-app-for-macos-with-whispercpp-and-screencapturekit-33m7
- Raw mic array / beamforming is userspace-applied: https://github.com/chadmed/triforce
- WebKit Bug 218012 (mic volume drop on mic permission): https://bugs.webkit.org/show_bug.cgi?id=218012
- VPIO lowers volume (Apple Developer Forums): https://developer.apple.com/forums/thread/93995
- WWDC23 "What's new in voice processing": https://developer.apple.com/videos/play/wwdc2023/10235/
- AVCaptureAudioChannel.volume (macOS, >1.0 boost): https://developer.apple.com/documentation/avfoundation/avcaptureaudiochannel
- Audio Hijack / ARK capture details: https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Audio-Capture-Details&product=Audio+Hijack
- Krisp virtual device: https://help.krisp.ai/hc/en-us/articles/4402174576402-How-Krisp-Microphone-and-Krisp-Speaker-work

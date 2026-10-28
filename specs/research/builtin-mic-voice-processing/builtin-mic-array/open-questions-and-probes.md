# Open questions and on-hardware probes

Research date: 2026-10-28. The web cannot settle these questions. Each probe below is
small and fits the repo's hardware loop:

1. Read the unified log.
2. Measure the files with `Tools/aac_track_report.py`.
3. Give the human one specific scenario.

See [hardware_debugging_workflow.md](../../audio/hardware_debugging_workflow.md) for that
loop. Ordered by how much each answer would change the plan.

## P1. Is "HAL Voice Isolation" a usable non-VP path for the built-in mic? (highest value)

**Question.** With Biscotti as a *plain* client (no VPIO) and its per-app Mic Mode set to
Voice Isolation, do we receive the following on the built-in mic during a call?

- beamformed, levelled mono;
- isolated voice;
- capsule 1 only;
- or nothing different?

Does it disturb the meeting app?
([processed-audio-without-vpio.md](./processed-audio-without-vpio.md) §2)

**Probe.**

1. Plain-tap build. Start a FaceTime call, so the built-in mic is in raw 3-channel mode.
   Start a Biscotti recording.
2. Click the menu-bar mic indicator, find Biscotti's Mic Mode, and record whether the
   menu is offered at all.
3. Switch Standard → Voice Isolation → Wide Spectrum, 20 s each, speaking with a fixed
   script while system audio plays.
4. Log the following at each step:
   - `AVCaptureDevice.preferredMicrophoneMode` and `.activeMicrophoneMode` (KVO);
   - tap channel count and rate;
   - per-channel peak and RMS;
   - the `HALSystem.cpp … HAL Voice Isolation` and `AVAUVoiceIOChatFlavor` log lines.
5. Ask the far-end participant whether Biscotti's mode changes are audible.

**Decides.** Whether "recommend Voice Isolation for Biscotti" via
`showSystemUserInterface(.microphoneModes)` is a real strategy.

## P2. Built-in mic mode census, and the 7/9-channel hypothesis

**Question.**

- When exactly does `BuiltInMicrophoneDevice` expose 1 vs N channels?
- What rate does it use in each mode?
- Is VPIO's channel count = mic capsules + speaker reference channels (9 = 3 + 6 on MBP;
  7 = 3 + 4 on MBA 13")?
  ([channel-modes-by-model.md](./channel-modes-by-model.md) §2–3)

**Probe.** On each Mac available (M-series MBP, MBA 13", and a MacBook Neo / Studio
Display if possible), log the following:

- `kAudioDevicePropertyStreamConfiguration` channel count;
- `kAudioDevicePropertyNominalSampleRate`;
- per-stream `kAudioStreamPropertyAvailablePhysicalFormats`;
- `kAudioDevicePropertyDeviceIsRunningSomewhere`.

Log them in each of these states:

- (a) idle;
- (b) FaceTime call;
- (c) Teams desktop;
- (d) Chrome/Meet;
- (e) Biscotti's own VPIO.

In (e), grep the unified log for `AUVPAggregate` `mic channel count: … ref channel count:`.

**Decides.** Whether the "channel count > 1 on a built-in device ⇒ raw mode" rule holds,
and whether any app other than VP clients triggers raw mode.

## P3. Raw-array phase, lag and level (settles the OpenOats claim)

**Question.** In raw mode, are the capsules in phase and level-matched, or are some
channels "anti-phase beams" as [OpenOats PR #561](https://github.com/yazinsai/OpenOats/pull/561)
claims?

**Probe.** Write all raw channels to a multichannel CAF/WAV for 10–20 s of speech, from
the front and from the side. Offline, compute:

- per-channel RMS;
- pairwise normalised cross-correlation peak value, sign, and lag (±4 samples).

Repeat on MBP and MBA.

**Decides.** The defaults of the down-mix
([downmixing-raw-array.md](./downmixing-raw-array.md) §3), and whether the polarity check
is needed in practice or is only defensive.

## P4. AVCaptureSession `multichannelAudioMode` on a Mac (macOS 15/26/27)

**Question.** Does a MacBook support `.stereo` or `.firstOrderAmbisonics`? If so, is that
an Apple-processed built-in-mic stream available to a non-VP client, and does it survive
a meeting app's VP?

**Probe.** Build an `AVCaptureDeviceInput` for the built-in mic and log:

- `isMultichannelAudioModeSupported(.stereo/.firstOrderAmbisonics)`;
- `isWindNoiseRemovalSupported`.

Run sessions with `.none` and with `.stereo` (if supported). Log the delivered
`CMFormatDescription` channel count and levels, idle and during a FaceTime call. Compare
with the repo's earlier "3 ch @ 44.1 kHz" AVCaptureSession result.

## P5. Can (and should) a plain client pin the 1-channel physical format?

**Question.** Does the built-in mic list more than one physical format (1 ch and 3 ch)?
If it does, setting the 1-ch format would almost certainly break the VP client that needs
the raw array.

**Probe.** Read-only: enumerate `kAudioStreamPropertyAvailablePhysicalFormats` in P2. Only
on a dev machine, try setting it during a FaceTime call and observe FaceTime. **Expect to
reject this as a strategy.** It is listed only for completeness.

## P6. Live-channel auto-detection on real interfaces

**Probe.** Use the issue-#66 setup (Audient iD24, mic on input 2, everything else silent)
or a Scarlett Solo 4th Gen (mic on input 2). Check that the detector
([multichannel-devices-and-builtin-detection.md](./multichannel-devices-and-builtin-detection.md) §4)
does the following:

- picks input 2 within a few seconds of speech;
- stays sticky through silence;
- raises the "selected channel dead" warning if the cable is pulled.

Also try Voice Isolation on the interface, to confirm the "input 1 only" behaviour and
the warning.

## P7. Level after down-mix and AGC

**Probe.** Run a real raw-mode recording through the proposed chain:

- polarity and lag align;
- weighted sum;
- high-pass;
- AGC;
- limiter;
- the existing 48 → 24 kHz AAC path.

Then check with `aac_track_report.py`:

- speech RMS near target;
- no clipping;
- no pumping across the 1 ch ↔ 3 ch transition at call start and end.

## Questions I could not answer from the web

- What processing the *plain* 1-ch built-in path applies on Apple silicon: beamforming,
  noise reduction, AGC? Apple doesn't say. Chromium's 2017 note mentions "hardware noise
  suppression" on the built-in mic in the Intel era.
- Whether the "7 channel" figure in issue #66 is the VPIO format on a MacBook Air (3 + 4)
  or something else. No source.
- Whether MacBook Neo (two mics) exposes 2 raw channels, and whether the Studio Display
  mic behaves like the built-in mic. No reports found.
- Whether HAL Voice Isolation exists on macOS 15 and 26 exactly as described for 14, and
  whether macOS 27 changed it. The vendor KBs say "Sonoma and above" / "Sonoma/Sequoia/Tahoe".
- Whether `kAudioDevicePropertySuggestedReferenceDevice` (macOS 27, undocumented) gives an
  echo-reference pairing usable for AEC. Its name suggests so, but there are no docs.
  This belongs to the post-processing subtopic.

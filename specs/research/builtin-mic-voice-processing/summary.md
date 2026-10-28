# Research: Built-in Mic Quality vs. Voice Processing (VPIO) Side Effects

Research date: 2026-10-28. Scope and owner questions: [research_plan.md](./research_plan.md). Bug: [issue #66](https://github.com/scosman/Biscotti/issues/66).

## Bottom Line

On the built-in mic, the #66 breakage comes from one documented side effect that no setting avoids. Any VPIO client switches the shared built-in mic into its raw-capsule mode. Every non-VPIO app (Chrome, Electron/Slack, very likely Teams, probably Zoom) then gets quiet, unbeamformed audio, about 25–30 dB down, until the VPIO unit is disposed. Bypass, AGC, mute, the ducking level and mic modes all leave the switch in place. VPIO also ducks every app's playback, by about −4 dB even at `.min`. The switch works in reverse too: when the meeting app is itself a VPIO client (FaceTime, Safari, Firefox, WhatsApp), Biscotti's plain tap gets the raw array at about −48 dBFS. So on the built-in mic the real choice is which app gets the bad audio. No public non-VPIO API returns Apple's beamformed, echo-cancelled mono.

Four other recorders shipped VPIO by default, hit this same bug, and removed it (MacParakeet, Transcripted, OpenOats, Vext). The approach the open-source field settled on is also what this research points Biscotti toward:
- plain mic capture, with no VPIO, no output reclock and no silent output node;
- channel handling that adapts to the device's current mode, plus software levelling;
- software echo removal that uses Biscotti's own system track as the reference (WebRTC AEC3 or LocalVQE v1.4-AEC). Aligning the two tracks is what decides whether this works.

VPIO survives at most as a gated option, for example only when a VPIO meeting app already holds the built-in array. For today's merged-stream transcription, the most urgent single fix is per-track loudness normalisation that accounts for echo.

## Answers to the owner's questions

1. **Are all reports on the built-in mic? Is there a clean rule?** Almost all are.
   - Of 20 reports, 6 name a built-in mic as the failing input: MacBook, plus one iMac. One names a 12-in USB interface (Audient iD24, on Chrome). 13 don't say which mic. 3 say a headset, USB mic or AirPods worked ([internal](./internal-evidence/summary.md)).
   - The documented mechanism applies only to the built-in mic, because external, USB and Bluetooth mics have no raw-array mode ([vpio](./vpio-side-effects/summary.md)).
   - The iD24 case has no explanation. VPIO also recorded silence on it, because channel 0 was the empty input 1.

   A workable rule therefore has three branches, not two:
   - **Built-in mic:** no VPIO by default.
   - **Multichannel interface:** no VPIO, and pick the live channel.
   - **Other external or Bluetooth mic:** VPIO doesn't break the other app's mic. It still ducks playback, still needs the output reclock, and sits on the path behind Biscotti's route-change and startup failures (#123, #124, 0-byte mic files) ([internal](./internal-evidence/summary.md)).

   Detect the built-in mic by UID `BuiltInMicrophoneDevice` **and** transport `bltn`. The headphone-jack mic is also `bltn`. Never match on the device name ([array](./builtin-mic-array/summary.md)).
2. **Why Teams, Slack and Chrome? Or every app?**
   - **Plain HAL clients get hurt.** These apps capture through a plain HAL stream and run their own WebRTC processing. That is confirmed from source for Chrome/Edge (whose VPIO path is disabled by default) and for Electron, which includes Slack huddles. It is very likely for native Teams (SlimCore) and probable for Zoom; neither documents its capture path.
   - **VPIO clients are unaffected.** FaceTime, Safari, Firefox and WhatsApp keep their own processed mic. They are the apps that cause Biscotti's quiet-mic problem when Biscotti doesn't use VPIO.
   - **Playback is ducked for every app.**

   Reports cover Teams desktop and web, Zoom desktop, Slack Huddle, Chrome and an Electron app, on macOS 15 through 27.0.1. No macOS release has changed this behaviour ([vpio](./vpio-side-effects/summary.md), [internal](./internal-evidence/summary.md)).
3. **Can Apple's built-in processing be had without disrupting other apps?** Not through any documented API ([array](./builtin-mic-array/summary.md), [vpio](./vpio-side-effects/summary.md)).
   - **Plain client.** It gets Apple's processed 1-channel stream at a normal level, but only while no VPIO client is active, and that stream has no echo cancellation.
   - **Most promising untested lead.** The per-app Mic Mode reaches non-VPIO apps since macOS 14 ("HAL Voice Isolation"). Apps can read the mode and open the system picker, but cannot set it. Its effect on the raw array is unknown (probe P1). AVCaptureSession `multichannelAudioMode` (macOS 15+) is also untested.
   - **VPIO knobs.** No VPIO setting avoids the mic-side switch; only disposing the unit ends it. Playback ducking can be fully undone only through the private `AudioDeviceDuck`, which is unverified on macOS 26/27.
   - **Conditional VPIO.** If a VPIO meeting app already has the built-in mic in raw mode, Biscotti's VPIO adds little mic-side harm and is the only way to get clean audio. That state shows up as more than one input channel before Biscotti starts, and TypeWhisper ships this rule. Caveats:
     - Running two VPIO clients at once still has open bugs.
     - The meeting app can start after Biscotti.
     - Ducking still applies.
4. **How do other apps solve it?** ([prior-art](./prior-art/summary.md))
   - **The OSS pattern.** OSS apps use a plain mic tap and a separate system track. They remove echo in software using the system track as the reference, at one of three points:
     - live: anarlog/Hyprnote, Muesli, Prismical;
     - after the recording stops: MacParakeet, Humla;
     - at the transcript level only: OpenOats.
   - **Details.** They skip AEC when the output is headphones and fix the level with software gain. The only remaining VPIO uses are gated:
     - Transcripted asks for consent per meeting, and never turns VPIO on while Zoom, Teams, Webex or FaceTime is running.
     - TypeWhisper turns it on only for the built-in mic in its 3-channel state.
   - **Commercial vendors.** The ones that disclose their approach use WebRTC AEC3 or Chromium's processing, not VPIO: Recall.ai, RecordKit, and Granola per a third-party teardown. Every vendor documents "use headphones".
   - **No VPIO setting is known to work.** No project or vendor documents a VPIO configuration that leaves a concurrent call unaffected.
5. **Is there a post-processing voice-isolation or echo-cancellation option?** Yes, for echo ([post-processing](./post-processing/summary.md)).
   - **Apple has nothing to offer here.** It has no offline echo canceller and none that accepts an app-supplied reference.
   - **Engines.** Two open engines fit:
     - WebRTC AEC3: BSD-3, about 0.1% of a core.
     - LocalVQE v1.4-AEC: Apache-2.0, neural, with time alignment built in.
   - **Where they would run.** Either engine can run offline in the Transcription XPC, or near-real-time before AAC encoding.
   - **Alignment decides whether it works.** A 2.5 ms misalignment can wipe out a linear canceller. MacBook speaker echo is likely nonlinear, double-talk is hard for every approach, and an AAC-coded reference probably caps how much can be cancelled.
   - **Noise tools don't help here.** Reference-free tools (Apple `AUSoundIsolation`, DeepFilterNet, RNNoise, Krisp and similar) remove noise, not the remote speech that bleeds into the mic. Denoising before Whisper usually raises the word error rate.
   - **The bigger fix for today's merged pipeline is levelling.** Bleed there doesn't duplicate words; the level imbalance is the problem. Whisper is not scale-invariant, and `AudioMerger` sums the tracks with no per-track gain. Echo cancellation becomes necessary for clean mic playback, for per-track or "me" attribution, and for long-delay outputs such as AirPlay.
6. **Multi-channel input devices?** ([array](./builtin-mic-array/summary.md), [prior-art](./prior-art/summary.md))
   - **Counting and selecting.**
     - Count channels with `kAudioDevicePropertyStreamConfiguration`, not with the AUHAL element count.
     - Select the device on the input node's audio unit (`kAudioOutputUnitProperty_CurrentDevice`). Never change the system default device to do it.
     - Pick channels in software, and never with `AVAudioConverter`, which silently zeroes discrete multichannel input.
   - **Choosing the channel.**
     - Auto-detect the live channel by per-channel speech-band SNR. Make the choice sticky and warn when the chosen channel goes dead.
     - Offer a user override, like Zoom's and Audio Hijack's channel pickers. The device picker is requested in #116.
   - **The built-in array in raw mode.** Use a weighted sum that checks polarity and lag first, and falls back to the best single channel chosen once per session. Then apply a high-pass filter, AGC and a limiter.
   - **A VPIO format.** Take only channel 0, and only on the built-in mic. On an interface, VPIO's channel 0 is just input 1.

## Implications

- **The built-in mic is not one fixed format.** Plain capture must survive the format flipping between 1 and 3 channels, and between 48 and 44.1 kHz, when a VPIO meeting app starts or ends a call. The level jumps 20–30 dB at the same moments, so down-mixing and AGC must adapt to the current mode rather than apply one fixed gain ([array](./builtin-mic-array/summary.md)).
- **Dropping VPIO also drops its scaffolding.** `ensureOutputRateMatchesInput()` and the silent output node exist only to keep VPIO running. The reclock is linked to `system.aac` ending early (#123). PR #115 keeps the silent output node; PR #118 removes everything ([internal](./internal-evidence/summary.md)).
- **#118 on its own reproduces the measured cost.** It gives a voice 11–15 dB quieter, speaker echo louder than the voice, and a merged meeting scaled down about ×0.2. Any change that removes VPIO needs per-track levelling that runs after echo handling, and a replacement for `AudioMerger`'s global-peak normalisation. AEC can follow ([internal](./internal-evidence/summary.md), [post-processing](./post-processing/summary.md)).
- **Where AEC runs is a real trade-off.** Offline in the Transcription XPC is simpler. But it works from an AAC reference, and gap fills mean the delay has to be re-estimated per segment. Capture-time AEC gets a PCM reference and exact host times, but it touches the recorder and triggers the `ac_*` manual-test staleness rule ([post-processing](./post-processing/summary.md)).
- **Channel selection is needed whatever happens to VPIO.** The iD24 silent recording happens with or without VPIO ([array](./builtin-mic-array/summary.md)).
- **Probe before committing to gated-VPIO or Mic-Mode strategies.** Those branches depend on probes P1 and P2 and on a `log stream` check of whether Teams and Zoom use VPIO.

## Conflicts and Uncertainty

1. **What the raw array's channels contain.** The evidence leans toward Biscotti's own data.
   - **Biscotti's measurement:** three near-equal, in-phase channels during a meeting. Peaks were 0.0033, 0.0034 and 0.0045, and their average was 0.0036. This fits Asahi's description of raw, omnidirectional capsules.
   - **OpenOats' claim:** channel 0 is a "primary beam" and the others are "anti-phase" (−70 dB averaged vs −7 dB on channel 0). The explanation was AI-written and never measured, and averaging cannot produce a 63 dB jump.
   - **Likely explanation (array subtopic):** OpenOats had its VPIO path on, so channel 0 was VPIO's processed output, where "take channel 0" is correct.
   - **Capsules can still differ.** One T2 MacBook Pro measured a capsule about 12 dB down.
   - **What to do anyway:** don't assume either way. Use the polarity/lag-checked sum, not TypeWhisper and Transcripted's per-buffer strongest-channel pick, which risks discontinuities. Probe P3 settles it ([array](./builtin-mic-array/summary.md), [prior-art](./prior-art/summary.md)).
2. **Does VPIO cancel other apps' playback?** Unresolved; neither subtopic settled it.
   - **Evidence against:** Screenpipe measured about 0 dB of echo removal with VPIO input-only, and the echo was also untouched with the output element on. They concluded that VPIO cancels only what the app renders through its own output.
   - **Evidence for:**
     - Apple's Feedback reply calls the tap streams that VPIO enables on output devices "the reference tap stream for echo cancellation".
     - A Biscotti tester (#127) saw VPIO remove "the Mac's own playback" in Biscotti's duplex setup.
   - **Weak evidence:** AudioLab's "VPIO + Voice Isolation removed bleed" is not evidence of echo cancellation, because Voice Isolation is reference-free ML separation.
   - **Lean:** VPIO probably works in Biscotti's configuration, on one anecdote, unmeasured.
   - **Decision impact is low.** It matters only for a gated-VPIO branch and for whether to run post-capture AEC on VPIO tracks ([prior-art](./prior-art/summary.md), [internal](./internal-evidence/summary.md), [post-processing](./post-processing/summary.md)).
3. **What breaks the other app's mic.** The evidence leans strongly toward the raw-array switch.
   - **Raw-array switch:** Apple's Feedback reply confirms it. Mozilla's rig measured a 25–30 dB loss with VPIO in *bypass*, which recovered only when the unit was disposed. It affects only the built-in mic.
   - **MacParakeet's "VPIO AGC writes the shared input gain":** there is no evidence for it, and their AGC-off fix was never tested on a call. The input-volume drop Biscotti measured (0.67 → 0.27 during Meet) is better explained by Chrome's own WebRTC input-volume adjustment, which is on by default and may make things worse.
   - **Ducking:** it acts on playback, so it explains "remote side quieter", not a dead mic.
   - **Output reclock:** ruled out as the root cause by a full mute with both devices at 48 kHz.
   - **Vext's "other apps get AGC/NS applied":** this contradicts the measurements, which show other apps get raw, unprocessed capsules.
   - **Full mute vs. degraded audio:** one inference is that a 25–30 dB drop pushes some apps' VAD or noise gate to silence ([vpio](./vpio-side-effects/summary.md), [prior-art](./prior-art/summary.md)).
4. **The "7 channel" figure.** No 7-channel format was observed anywhere; the counts seen are 1, 3, 9 and 28.
   - **Hypothesis:** VPIO's format is mic capsules plus speaker reference channels. The iD24 log shows 12 + 16 = 28. A MacBook Pro gives 3 + 6 = 9, which was observed, and a 13" MacBook Air would give 3 + 4 = 7. One other app saw "3–7 ch" with VPIO on.
   - **Status:** unverified (probe P2). No decision rides on it if code handles any channel count.
5. **Whether LocalVQE v1.2 keeps the local speaker's voice.**
   - **MacParakeet's synthetic harness** says the joint v1.2 model zeroes the near-end voice. That harness used formant tones, not speech, and its authors say it cannot certify double-talk.
   - **LocalVQE's real-recording evaluation** says v1.2 preserves the near-end voice.
   - **Lean:** the harness result is an artifact. The question is moot either way, because both sources agree the echo-only v1.4-AEC preserves the near-end voice, and that is the model to evaluate ([post-processing](./post-processing/summary.md)).

Other open points:
- Teams' and Zoom's capture paths are undocumented.
- It is unclear whether WebKit's "only one VPIO unit can run at a time" applies per process, per device or system-wide.
- The iD24 disruption mechanism is unknown.

## Gaps

- **Biscotti's plain-tap level on the built-in mic.** It has not been measured with one metric across idle, a VPIO meeting app and a plain-HAL meeting app. AudioLab's −48 dBFS peak (AVCaptureSession) and the −30 to −40 dBFS from the #118 tester (Teams) are not comparable. To close: probe P2's mode census, with per-channel levels.
- **HAL Voice Isolation for a plain client** on the raw array: is the output beamformed, isolated or single-capsule, and does it disturb the meeting app? To close: probe P1. The per-app mic-mode workaround reported in #66 is also unverified.
- **Whether Teams and Zoom use VPIO.** To close: a one-minute `log stream` of Core Audio / AUVP messages while each app joins a call.
- **How much echo VPIO removes in Biscotti's configuration.** To close: a speaker-mode recording, then measure the mic/system correlation.
- **No AEC head-to-head on Mac hardware.** Nobody has compared AEC3 and LocalVQE on MacBook-speaker echo with a process-tap reference. Also missing:
  - LocalVQE timings on Apple silicon;
  - how much the AAC-coded reference limits cancellation;
  - whether process taps capture audio before or after the speaker DSP and system volume.

  To close: an A/B on one recorded meeting, with a PCM reference and an AAC reference.
- **Whisper/WhisperKit accuracy vs. input level** on a merged two-talker stream is unmeasured. To close: transcribe the same meeting with VPIO, with the raw mic, and with the raw mic plus normalisation, and compare.
- **Untested hardware.** There are no reports for the MacBook Neo (2 mics), the Studio Display mic, or the iMac's channel modes. There are also no #66 reports with FaceTime or Safari as the other app.
- **`AudioDeviceDuck` undo** is unverified on macOS 26/27.
- **MacParakeet saw VPIO silence a process tap in the same process.** Nobody has checked this against Biscotti's system track.
- **Only 3 of the owner's "about 5 PRs" were found** (#115, #118, #129). The others may be the merged startup fixes (#94/#101).

## Subtopics

- [Internal evidence](./internal-evidence/summary.md): production behaviour, the 20 user reports, PRs #115/#118/#129 and earlier experiments. VPIO is unconditional in production. Every report that names its failing mic is on a built-in mic except the iD24. Dropping VPIO without echo or level handling measurably hurts the transcript.
- [VPIO behaviour and side effects](./vpio-side-effects/summary.md): how VPIO reaches other processes, every knob, and which meeting apps are victims or causes. The raw-array switch breaks plain-HAL apps' mics and no knob prevents it; ducking and reconfiguration are separate costs.
- [Built-in mic array and multi-channel input](./builtin-mic-array/summary.md): hardware, channel modes, non-VPIO routes to processed audio, down-mixing, device and channel selection, built-in detection. There is no public non-VPIO processed path. The answer is mode-aware down-mix plus AGC, with HAL Voice Isolation as the untested lead.
- [Prior art](./prior-art/summary.md): about 19 OSS and about 14 commercial apps. Four recorders removed VPIO after hitting #66. The field uses a plain tap plus software AEC against the system track, with VPIO only behind gates.
- [Post-processing](./post-processing/summary.md): reference-based AEC engines, their failure modes, noise suppression, levelling, and transcript-level alternatives. WebRTC AEC3 or LocalVQE v1.4-AEC can work if the tracks are aligned. Echo-aware per-track levelling is the most important fix for the current merged pipeline.

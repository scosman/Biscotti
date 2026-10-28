# PRs that touch the mic / VPIO path: what each changes and what it trades away

Read 2026-10-28: PR descriptions, conversation comments, review threads and diffs, via the GitHub API.

The owner says there are "about 5 PRs" ([#66 comment](https://github.com/scosman/Biscotti/issues/66#issuecomment-6470640519)). A search of every PR in the repo found **three open PRs that change the VPIO mic path**: #115, #118 and #129. Four more matter for context:
- **#94 / #101** (merged): established the VPIO startup recovery.
- **#123 / #109** (open): fix fallout on the system track, including from Biscotti's own output reclock.
- **#127** (open): contains hardware data points.

A search for "voice processing", "VPIO" and "microphone" returned nothing else. If the owner counts other PRs, they are either in forks without a PR or they are these PRs counted differently.

## Comparison

| | #115 "Microphone noise suppression" setting | #118 Passive mic capture | #129 Restart mic in place after route change |
|---|---|---|---|
| Author / date | thomasvvugt, 2026-10-21 | alxleo, 2026-10-23 | brainstencil, 2026-10-27 |
| State | open, not reviewed by owner beyond comments | open | open |
| VPIO | **Optional** (setting, default **on**) | **Removed** | **Kept** |
| `ensureOutputRateMatchesInput` | Skipped when VPIO off | Removed (and `setNominalSampleRate` deleted) | Kept; returns early if the rate request fails |
| Silent output node | **Still attached** in plain mode | Removed (input-only engine) | Kept |
| Ducking config | Only set when VPIO on | Removed | Kept (`.min`) |
| Channel reduction | VPIO: ch0. Plain: **average of all channels** | **ch0 only** of native format | ch0 (unchanged) |
| Fixes other-app mic? | Yes, when the user turns VPIO off (thomasvvugt: Slack Huddle, built-in mic) | Yes (javimoya: Teams test call, built-in mic) | **No.** Not its goal. |
| What it costs | Users must find the setting. Plain-mode quality: "clearly less crisp, more room noise" | Echo, low level, double-counted remote speech (measured) | Complexity. Still ducks −4 dB for the whole recording. |

---

## PR #115: Add "Microphone noise suppression" setting

[PR #115](https://github.com/scosman/Biscotti/pull/115), branch `thomasvvugt:no-vpio-setting`, 1 commit, +695/−368 in 14 files. Most of the size is the manual-test JSON and settings plumbing.

**What it changes** (from the diff):
- New `AppSettings.useVoiceProcessing: Bool = true`, persisted. It is exposed in Settings → General as a toggle labeled **"Microphone noise suppression"**, with the help text "When off, Biscotti skips noise suppression so other apps can use the microphone at the same time (e.g. during a Slack or Teams call)."
- The value reaches the recorder through an `OSAllocatedUnfairLock<Bool>` that the recorder factory reads when recording starts. A change takes effect at the next recording, not mid-recording.
- `AudioRecorder.live(encoder:useVoiceProcessing:)` passes the value to `LiveMicCaptureEngine(encoder:useVoiceProcessing:)`.
- With `useVoiceProcessing == false`:
  - `ensureOutputRateMatchesInput()` is skipped.
  - `setVoiceProcessingEnabled(true)` and the ducking config are skipped.
  - Teardown skips `setVoiceProcessingEnabled(false)`.
  - **`attachSilentOutput(to:inputRate:)` still runs.** It is unconditional in `installCaptureGraphAndStart`, which the diff does not touch. So plain mode still connects a silent source to `outputNode` at the input's rate. *Inference:* the plain engine still opens an output IO unit on the default output device. Nobody reported a problem with this, but it is unnecessary for an input-only tap, and #118 removes it.
- `MicCaptureSession(…, downmixChannels: !useVoiceProcessing)`. When it is true and the tap has more than 1 channel, the real-time callback **averages all channels** (`sum * 1/channelCount`) instead of copying channel 0.
- The "Mic setup" log line gains `voiceProcessing=on|off`.
- New manual steps: `ac_plain_setup`, `ac_start_recording_no_vpio`, `ac_stop_recording_no_vpio`, `ac_other_app_hears_mic`, `ac_plain_playback`. The script grows from 17 to 22 steps.
- New unit test `downmixAveragesChannels` (2 channels, ch0 silent, ch1 tone).

**Claims and evidence from the PR:**
- "Slack Huddle and Microsoft Teams mics stop passing audio to other participants once a Biscotti recording starts, while the system input level still looks normal."
- "the tap on the built-in mic can arrive as a **9-channel stream when the default input and output devices run at the same rate**, so the plain path averages the channels down to mono". *Note:* this is a **non-VP** tap showing 9 channels. In AudioLab, the 9-channel format appeared only with VP enabled, and the plain path saw 3 channels. Nobody explains why a non-VP tap would show 9 channels. See [prior-experiments.md](./prior-experiments.md#channel-counts-seen-for-the-built-in-mic) for the competing observations.
- Hardware: "macOS 26.7.1, built-in mic, in/out both 48 kHz". With the toggle off, the Slack Huddle kept the mic. With it on, "the Huddle goes quiet as before".

**Review discussion:**
- Owner ([comment](https://github.com/scosman/Biscotti/pull/115#issuecomment-6343172790)): "Slack huddle + MacBook internal Mic hits it, Slack huddle with usb Mic does not… in my cases it's messing with levels, but never completely capturing the mic… VPIO was pretty essential to get clean audio for STT. So turning it off will fix this, but cause downstream issues in transcription and summary."
- Author ([reply](https://github.com/scosman/Biscotti/pull/115#issuecomment-6359122965)): "MacBook Pro built-in mic and internal speakers, both at 48 kHz… full-mute variant… With VPIO off the internal mic picks up again. I have no issues with Bluetooth headset… with it off the recording is clearly less crisp, more room noise but is still good enough for transcribing and diarization."
- CodeRabbit raised two minor test-tightening points: fail on an empty decode, and bound the peak near 0.1.

**Tradeoffs:**
- Default on means the default behaviour is unchanged. Users still hit the bug until they find the toggle.
- Plain mode has no AEC, no AGC and no beamforming. The channel average sums the raw built-in array capsules, which `phase9_validation_findings.md` #1 warned against ("discards Apple's beamforming/noise-suppression"). The 1/N scaling also lowers the level of an already-quiet signal. Averaging capsules with different phase can comb-filter. That is an inference, not measured here.
- Averaging is a reasonable answer for the iD24 case, where only one of 12 channels is live: it records the mic at about −21.6 dB relative (1/12), rather than silence. It does not pick the live channel.

---

## PR #118: Use passive microphone capture

[PR #118](https://github.com/scosman/Biscotti/pull/118), branch `alxleo:fix/teams-passive-microphone`, 1 commit, +96/−345 in 8 files.

**What it changes** (from the diff):
- `LiveMicCaptureEngine` becomes "Passive microphone capture through an input-only `AVAudioEngine` tap".
- It removes `setVoiceProcessingEnabled`, the ducking config, `attachSilentOutput`/`silenceNode`, `ensureOutputRateMatchesInput`/`restoreOutputRate`/`outputRateOverride`, and `CoreAudioHelpers.setNominalSampleRate`.
- Teardown is now `removeTap` → `stop()`, with no VP toggle. This also removes the #124 crash and deadlock path.
- The tap uses the input's native format. `MicCaptureSession` still copies **channel 0 only**. There is no averaging.
- Renames: `VPIOFileHelper` → `MicFileHelper`, `VPIOBufferHelper` → `MicBufferHelper`. Removes `extractChannel0` and its tests.
- The fidelity test now covers 1, 2, 3 and 4 channels × 4800, 1024 and 441-frame buffers. The tone is always on ch0, with noise on the other channels, so the test checks ch0 passthrough.
- The log line gains `passive=true voiceProcessing=\(input.isVoiceProcessingEnabled)`.
- AudioRecorder comments are reworded so they no longer mention "VPIO reclock". The 3 s first-buffer timeout and system-start retries stay.
- All `ac_*` manual results are set to `not-run`.

**Claims:**
- "The meeting application continues to own its call processing. Biscotti now records the native microphone signal, so its recordings no longer receive the additional VPIO echo cancellation/noise suppression. No setting or data migration is added."
- "Live logs confirm passive=true, voiceProcessing=false, and a 48 kHz mono tap." Note the **mono** tap. The author's input device and model are not stated.
- "Physical Teams voice/camera acceptance is in progress. Camera causality is not established by this change."

**Independent hardware test** ([javimoya](https://github.com/scosman/Biscotti/pull/118#issuecomment-6446547910), MacBook Pro M2 Pro, macOS 26.4, built-in mic, new Teams desktop, "Make a test call"):
- On main with VPIO: "the Echo bot gets nothing: no playback, nothing in Teams' transcript. Stopping the recording mid-call brings the mic back."
- With #118: "Teams transcribes me and plays my message back; Biscotti's own transcript of the meeting reads correctly."
- **Cost, measured on the decoded tracks:**
  - "my voice in `mic.aac` sits around −30 to −40 dBFS (VPIO gave −19 to −25)". That is about 11–15 dB quieter.
  - "with no echo cancellation the Echo bot playing through the MacBook speakers enters `mic.aac` louder than my voice, peaking at +14 dBFS". *Note:* a float track can exceed 0 dBFS before clipping. The exact figure is as reported.
  - "Since `AudioMerger` sums both tracks and normalizes by the merged peak, that bleed scales the whole meeting down (~×0.2) and remote speech reaches the transcriber twice." Confirmed from the code: `AudioMerger.swift:101-108` scales the whole array by `1/peak` when the peak is above 1.
- Edge cases javimoya found in review: "only channel 0 of the native input is recorded (a mic on input 2 of an interface would be silent, as in #66), and the ring slots are sized for ≤96 kHz × 200 ms."

**Owner** ([comment](https://github.com/scosman/Biscotti/pull/118#issuecomment-6470524700)): "Yup, this is basically the trouble. Simple tap and we get wildly inconsistent levels, weird channels, and tons of echo. With VPIO we get clean audio, and it starts to mess with other apps… Solution might be our own in-process voice isolation."

**Tradeoffs:**
- It fixes the other-app mic for everyone, with no setting.
- It gives up AEC, noise suppression, AGC and beamformed mono for **all** devices, not only the built-in mic. That costs quality on USB mics and headsets, which did not have the bug according to the reports.
- Measured result: quieter voice, loud speaker echo, and remote speech in both tracks. Through `AudioMerger`, this hurts the whole transcript, not just the mic side.
- The multichannel channel-0 problem from #66 (iD24) remains.

---

## PR #129: Restart the mic engine in place after an audio route change

[PR #129](https://github.com/scosman/Biscotti/pull/129), branch `brainstencil:claude/mic-route-change`, 5 commits, +672/−68 in 10 files. It **keeps VPIO** and fixes reliability on route changes. It does not try to fix the other-app mic. It is in scope here because it changes the VPIO path and contains the best measurements of VPIO side effects.

**What it changes:**
- **Restart in place.** On `.AVAudioEngineConfigurationChange` *after* audio delivery, the existing engine and VP unit are restarted: a new tap and silent output at the re-queried format, then `start()`. This takes 0.06–0.4 s. It falls back to a full rebuild if the restart throws or delivers no buffer within 2 s. The reasoning is that VP follows default-device changes by itself: "`AUVPAggregate: System default device has changed and the client has not selected Device IDs. Will track the default device`".
- **Wait for VP.** `reconnect()` (input change) waits up to 3 s (`voiceProcessingSettleTimeout`) for the config-change path before it rebuilds. This avoids calling `setVoiceProcessingEnabled(false)` while VP is reconfiguring. That timing is the cause of the #124 crash and deadlock.
- **Skip stale reconnects** with a new `MicReconnectPolicy`/`MicRoute`. Its doc comment says: "Voice processing uses both: the input for capture, the output as the echo reference (and `ensureOutputRateMatchesInput` sets its rate)."
- **Output rate:** `guard status == noErr else { return }` after `setNominalSampleRate`. "AirPods output refuses 24 kHz with 'nope'."
- It adds two bullets to `specs/research/audio/README.md` with VP timings and ducking levels.

**Hardware results** (M1 Max, macOS 26.6.2, built-in mic and speakers + AirPods):
- Mic gap per AirPods connect drops from 6.20–7.45 s to 2.17–2.49 s. Per disconnect, from 3.06–5.73 s to 0.30–1.20 s.
- No hang or crash in 30 route changes.
- **Ducking measurements:**
  - "Other audio was ducked to −15 dB once, for 1.0 s at record start. After that the duck stayed at −4 dB and moved to each new device."
  - "Each new voice-processing unit also ducks other audio to −15 dB (`AudioDeviceDuck … 0.177828` in the log) until its ducking property applies at engine start, 0.6–1.3 s later; a restart keeps the `.min` level (−4 dB, 0.630957)."
  - Under "Not covered": "Voice processing still ducks other audio by 4 dB (`.min`, its lowest level) for the whole recording… #118 removes voice processing… If voice processing stays, this PR applies."

**Tradeoffs:**
- It makes the VPIO path more robust and fixes a crash and hang.
- It adds complexity: a policy type, waits and timeouts.
- It does nothing for the other-app mic or the −4 dB duck.
- If #118 merges, most of #129 is moot. The PR says this itself.

---

## Context PRs

- **[#94](https://github.com/scosman/Biscotti/pull/94)** (KentonParton, merged via #101) and **[#101](https://github.com/scosman/Biscotti/pull/101)** (owner, merged 2026-10-08):
  - "About 300 ms after start, VPIO can reconfigure its aggregate device, and AVAudioEngine then **stops itself** before the first mic buffer."
  - Fix: restart the stopped engine in place with VPIO still enabled. "Recreating the voice-processing engine on every startup notification repeatedly reproduced the failure on the affected setup."
  - Confirmed on Bose NC 700 + 2× Dell displays (macOS 15.7.9) and on a Samson C01U USB mic + NuForce µDAC (`specs/research/audio/display_audio_startup_failure.md`). This is a VPIO cost too: VP's aggregate reconfiguration produced 0-byte mic files on non-built-in setups.
- **[#123](https://github.com/scosman/Biscotti/pull/123)** (open). It lists "Biscotti's own mic setup changes the output rate to match the input (`ensureOutputRateMatchesInput`)" as one of three causes of a system-tap format change mid-recording. Such a change made `ExtAudioFile` reject the new client format (`-66565`) and ended `system.aac` early. *Implication:* the VPIO reclock also hurts Biscotti's own system track.
- **[#109](https://github.com/scosman/Biscotti/pull/109)** (open). Adds output nominal-rate and stream-format listeners and a buffer-flow watchdog for the system tap. With the reclock still in place, those listeners will also fire on Biscotti's own reclocks. That is an inference; the PR does not discuss it.
- **[#127](https://github.com/scosman/Biscotti/pull/127)** (open, live transcript), hardware notes on main:
  - "the mic's echo cancellation removes the Mac's own playback". VPIO AEC demonstrably works on built-in speakers.
  - "each switch leaves 3–8 s of silence in the mic track while the voice-processing engine rebuilds".
  - "one AirPods recording came out in slow motion… Only that run hit a failed request to change the AirPods output rate".
- **[#130](https://github.com/scosman/Biscotti/pull/130)** (open). A stop() hang in the system reconnect. It mentions #124 (the mic VPIO hang) only as a separate cause.

## The tradeoff all the PRs run into

All three either keep VPIO, and so keep the side effects on other apps, or drop it, and so get a quiet, echo-heavy, unbeamformed built-in mic track. None of them:
- makes the choice per device (for example, built-in vs. other);
- picks a live channel on multichannel interfaces;
- adds echo removal or levelling after capture.

The owner's assessment fits the evidence: "they all seem to trade 2 for 1, which is a tradeoff, not a clean win" ([#66](https://github.com/scosman/Biscotti/issues/66#issuecomment-6470640519)).

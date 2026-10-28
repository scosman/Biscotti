# How the Mac built-in mic is exposed: hardware, channel counts, modes

Research date: 2026-10-28. Current OS at time of writing: macOS 27.0.x ("Golden Gate"), so
macOS 15, 26 and 27 are all in the field.

This doc answers: what does a non-voice-processing client actually receive from
"MacBook Pro Microphone" / "MacBook Air Microphone", in which situations, and why it
sometimes has 1, 3, 7 or 9 channels. Read it before writing any channel-handling code.

Labels used below: **[source]** = stated by a cited source; **[repo]** = measured
earlier in this repo; **[inference]** = my reasoning from the cited facts, not
stated anywhere.

---

## 1. The hardware: raw PDM capsules, no preamp, DSP done in software

The best primary description of the hardware is from the Asahi Linux team, who had to
reverse-engineer it to get the mics working on Linux:

> "MacBooks have three Pulse Density Modulation (PDM) mics wired up to an ADC and
> decimator in the AOP. All three mics are plumbed directly to userspace on separate
> channels, with no preamplification. They are very sensitive and omnidirectional, so to
> be able to use them, some kind of beamforming needs to be applied."
> ([Asahi docs, Userspace Audio Stack](https://asahilinux.org/docs/sw/audio-userspace/))

From the [Asahi 6.14 progress report (Mar 2025)](https://asahilinux.org/2025/03/progress-report-6-14/):

> "In all laptops released so far, Apple use three Pulse Density Modulation (PDM) mics …
> with no preamplification."
> "I initially tried a very basic delay-and-sum beamformer … However since the mics are
> only about 2cm apart and only sample at 48 kHz, we cannot achieve the temporal
> resolution required to make this approach work."
> "On certain machines, the Secure Enclave is in the path of the physical mic data lines."

The Triforce README ([github.com/chadmed/triforce](https://github.com/chadmed/triforce))
adds that the arrays are "arranged either in a triangle or in a straight line" depending on
model, and warns "Do not expect it to outperform Apple's implementation at this time."

The same is true of the 2019 Intel/T2 16-inch MacBook Pro. A Linux user on a
MacBookPro16,1 measured the T2's raw 3-channel, 24-bit/48 kHz array with no capture-gain
control: raw channel peaks of **−39.6, −49.3 and −37.0 dBFS** while speaking. After a
Triforce + gain + high-pass DSP graph, the peak was −23.8 dBFS, about 15 dB louder
([omarchy discussion #8526, Aug 2026](https://github.com/omacom/omarchy/discussions/8526)).

**What this means for macOS [inference]:** at the hardware level the mics are raw,
quiet, omnidirectional capsules. The loud, directional ("beamformed"), noise-reduced
signal that Apple advertises is produced by Apple software beneath the app, not by the
capsules. Which client format you get decides whether you receive that processed signal
or the raw capsules.

### What Apple says each model has (spec pages)

| Model | Mics | Speakers | Source |
|---|---|---|---|
| MacBook Pro 14" (M4 / M4 Pro / M4 Max, 2024), and 16" | "Studio-quality three-mic array with high signal-to-noise ratio and directional beamforming" | "High-fidelity six-speaker sound system with force-cancelling woofers" | [support.apple.com/121552](https://support.apple.com/en-us/121552), [121553](https://support.apple.com/en-us/121553), [121554](https://support.apple.com/en-us/121554) |
| MacBook Air 13" (M4, 2025) | "Three-mic array with directional beamforming"; "Voice Isolation and Wide Spectrum microphone modes" | "Four-speaker sound system" | [support.apple.com/122209](https://support.apple.com/en-us/122209) |
| MacBook Neo (A18 Pro) | "Dual-mic array with directional beamforming" | "Dual-speaker sound system" | [apple.com/macbook-neo/specs](https://www.apple.com/macbook-neo/specs/) |
| Studio Display (external, USB audio) | "Studio-quality three-mic array with high signal-to-noise ratio and directional beamforming" | "High-fidelity six-speaker system with force-cancelling woofers" | [support.apple.com/111890](https://support.apple.com/en-us/111890) |

Not every Apple laptop has three mics: the MacBook Neo has **two**. Code must never
assume 3. (I could not confirm the 15" MacBook Air or iMac mic and speaker counts from an
Apple page in this session.)

---

## 2. The modes a client sees

| Situation | Channels the client sees | Rate seen | Level | Evidence |
|---|---|---|---|---|
| **Normal**: no voice-processing (VP) client is using the built-in mic | **1** | device rate (48 kHz typical) | Normal ("levels were fine") | Apple forum: "MacBook Pro Microphone … Number of Channels (Stream Format): 1" ([thread 763325, Sep 2024](https://developer.apple.com/forums/thread/763325)); MBA M1 on macOS 13.5 "shows only 1 channel" ([Apple Community 255090182, Aug 2023](https://discussions.apple.com/thread/255090182)); 2019 MBP 16" shows 1 input channel in Audio MIDI Setup ([Apple Community 251401935](https://discussions.apple.com/thread/251401935)); **[repo]** "Without a meeting app, levels were fine" ([mic_capture_level_findings.md](../../audio/mic_capture_level_findings.md)) |
| **Raw array**: a VP client (FaceTime, a meeting app, or our own VPIO) is using the built-in mic | **3** (2 on MacBook Neo, by inference) | 44.1 kHz seen via AVCaptureSession **[repo]**; 48 kHz via AVAudioEngine **[repo]** | **Very low**: speech peaks ≈ 0.003–0.005 (≈ −48 dBFS) **[repo]** | Same MBA M1 user: "when i start a call the microphone becomes 3 channels" ([Apple Community 255090182](https://discussions.apple.com/thread/255090182)); TypeWhisper: "the built-in 3-channel default input route that FaceTime exposes on macOS … speech was effectively lost by the normal mono path" ([TypeWhisper PR #755, merged 2026-06-19](https://github.com/TypeWhisper/typewhisper-mac/pull/755)); **[repo]** `src=[44100Hz 3ch …]`, `ch0=0.0033 ch1=0.0034 ch2=0.0045` |
| **Our own VPIO client format** (`setVoiceProcessingEnabled(true)` on M-series MBP, macOS 15) | **9** (channel 0 = processed mono) | 48 kHz | Channel 0 loud (≈0.54) | **[repo]** run 1–4 in mic_capture_level_findings; Quill RCA: "The input node reports 9 channels at 48 kHz" ([digimata/quill rca-001](https://github.com/digimata/quill/blob/8ab6ebb6/.issues/rca-001-voice-processing-silent-mic.md)); Scripta ([dev.to](https://dev.to/thehwang/building-a-100-local-meeting-transcription-app-for-macos-with-whispercpp-and-screencapturekit-33m7)) |
| **Per-app Mic Mode = Voice Isolation** for a *non*-VP app (macOS 14+) | Multi-input interfaces: "all inputs receiving signal from input 1"; aggregates: only the first sub-device's channels | — | — | [Focusrite KB (updated Apr 2026)](https://support.focusrite.com/hc/en-gb/articles/15437020104082); [Apple forum 787240 (Jun 2025)](https://developer.apple.com/forums/thread/787240). Details in [processed-audio-without-vpio.md](./processed-audio-without-vpio.md) |

### Why the format flips [inference, strongly supported]

Voice processing needs the individual capsule signals for its own beamforming and echo
cancellation. When any VP client opens the built-in mic, the device switches to a
multichannel raw format. Core Audio devices are shared, so every other client of that
device (including a plain AVAudioEngine tap or AVCaptureSession) is moved onto the same
raw format. The repo's earlier root-cause note says the same thing: "When another app
engages voice processing the device stays in this 3-channel array mode, and a plain
(non-VP) capture client like ours is handed the raw, quiet taps."

The consequences for a plain-tap recorder:
- **The format changes mid-recording.** It goes 1 ch → 3 ch when the call starts and
  back when it ends, and the sample rate may change too. That is an
  `AVAudioEngineConfigurationChange`, which phase 9 already requires us to survive
  ([phase9_validation_findings.md](../../audio/phase9_validation_findings.md) finding 2).
- **The level drops by roughly 20–30 dB at the same moment.** The processed 1-ch path
  has Apple's gain; the raw capsules have "no preamplification". A recorder must
  therefore re-level depending on the mode, and not apply one fixed gain.
- **Any code that assumes mono breaks.** In the cpal case it went silent
  ([cpal #1143](https://github.com/RustAudio/cpal/issues/1143)). In this repo it caused a
  crash, rejected writes and an empty file (phase 9 finding 1). `AVAudioConverter` also
  turned 3 → 1 ch into silence (mic_capture_level_findings, "Prior fixes").

### The conditions for 3 ch are not fully pinned down

The two reports above tie 3 ch to an active call. Two other reports say only "on MacBook
Pro, that array has 3 channels" (macOS 26, [cpal #1143](https://github.com/RustAudio/cpal/issues/1143))
and "any modern MacBook (M2/M3 Air, M3 Pro etc., where the built-in mic reports 3
channels)" ([OpenOats PR #561](https://github.com/yazinsai/OpenOats/pull/561)). Neither
says whether a meeting app was running. OpenOats has its own optional
`setVoiceProcessingEnabled(true)` path (code search:
`OpenOats/Sources/OpenOats/Audio/MicCapture.swift`), so its 3-ch observation may come from
a VP context. Phase 9 in this repo also logged 3 ch @ 48 kHz without recording whether a
VP client was active. **Treat "1 ch unless a VP client is active" as the documented
normal case. Do not depend on it, and handle any channel count on any built-in device.**

---

## 3. Where the 9 (and probably 7) channel counts come from

The "VP client format" row above has 9 channels on an M-series MacBook Pro. The owner's
issue-#66 comment mentions "a fancy 7 channel array mix". No source I found documents
either number. The pieces I did find:

- In issue #66, a user with an Audient iD24 (12 in / 16 out) captured the AUVP setup log:
  `AUHAL reported mic channel count: 12, ref channel count: 16` followed by
  `VP <= [28 ch, 48000 Hz, Float32, deinterleaved] <= AUHAL <= [28 ch, ...] <= HAL`
  ([Biscotti issue #66 comment, 2026-09-08](https://github.com/scosman/Biscotti/issues/66#issuecomment-5583791101)).
  **28 = 12 mic + 16 reference (output) channels.**
- A third-party Swift/macOS skills note says the same: VPIO "reports combined input+output
  channels (e.g., 9 = mic + speaker)"
  ([tenequm/skills screen-capture-audio.md](https://github.com/tenequm/skills/blob/main/skills/swift-macos/references/screen-capture-audio.md)).
- A Stack Overflow answer on the 1 → 3 channel jump when VP is enabled calls the extra
  channels "metadata channels (ex. for echo calculations) that can be ignored. You need to
  use the first channel and ignore the rest"
  ([SO 72953588](https://stackoverflow.com/questions/72953588/why-enabling-voice-processing-on-avaudioinputnode-changes-channels-count-on-its)).

**Hypothesis [inference]: VPIO channel count = mic capsules + speaker reference channels.**
- MacBook Pro 14"/16": 3 mics + 6 speakers = **9**. This matches what the repo measured.
- MacBook Air 13": 3 mics + 4 speakers = **7**, which would explain the "7 channel" figure.
- MacBook Neo: 2 + 2 = 4 (predicted).

This is unverified. Check it by logging the `AUVPAggregate` "mic channel count / ref
channel count" lines on a MacBook Air (see [open-questions-and-probes.md](./open-questions-and-probes.md)).
Either way, the only channel a recorder wants from a VPIO client format is **channel 0**
(the processed output). The rest is not "an array mix" a recorder should down-mix.

Note also: on non-built-in devices VPIO does **not** produce a processed channel 0. On
the Audient it passed the 12 device channels through and channel 0 was the empty input 1,
so `extractChannel0` recorded silence (same issue #66 comment).

---

## 4. What's on the raw channels

- **Roughly equal level and phase on an M-series MBP [repo]:** peaks were ch0 0.0033,
  ch1 0.0034, ch2 0.0045, and the averaged output peaked at 0.0036. If one channel were
  phase-inverted, the average would have been well below the per-channel peaks.
  **[inference]** On this machine the three channels are in phase, near-equal capsules.
- **Large level differences between capsules on a T2 MBP 16" [source]:** −39.6 / −49.3 /
  −37.0 dBFS ([omarchy #8526](https://github.com/omacom/omarchy/discussions/8526)).
  One capsule is about 12 dB down, probably because of port placement or occlusion.
- **A contrary claim (unverified):** OpenOats PR #561 says the 3 channels are
  "front-facing primary beam (channel 0) plus side and cancellation beams" that are
  "anti-phase or uncorrelated", so averaging attenuated voice by "~25 dB". It reports a
  peak of −70 dB before the fix and −7 dB after taking channel 0, which is a 63 dB jump
  that averaging alone cannot explain. The PR was merged on 2026-05-01 with a maintainer
  approval saying the "root cause analysis is correct", but there was no independent
  measurement ([OpenOats PR #561](https://github.com/yazinsai/OpenOats/pull/561)). It
  contradicts both the Asahi hardware description (raw capsules) and this repo's
  measurement. Possible explanations: their capture had VP on, so channel 0 was the
  processed output, or a different model behaves differently. **The down-mix code should
  detect polarity and correlation rather than assume them**
  ([downmixing-raw-array.md](./downmixing-raw-array.md)).
- **No channel labels.** On the built-in mic, `kAudioObjectPropertyElementName` and the
  channel-category properties report `AudioObjectHasProperty() == true` but
  `AudioObjectGetPropertyData()` fails with `'WHAT'`
  ([Apple forum 748749](https://developer.apple.com/forums/thread/748749), macOS 14.4,
  Intel MBP). Nothing tells you which capsule is where.

---

## 5. API surfaces all see the same device format

- **AUHAL / AVAudioEngine:** the input element's device-side format is the HAL device
  format. The AUHAL can convert to a client format and remap channels
  ([TN2091](https://developer.apple.com/library/archive/technotes/tn2091/_index.html)).
  An Apple engineer notes that the AUHAL "element count" (e.g. 2) is not the channel
  count. Element 0 is the device's master element, so use the stream format's
  `mChannelsPerFrame` ([forum 763325](https://developer.apple.com/forums/thread/763325)).
- **AVCaptureSession:** on the same device and in the same situation, it delivered
  3 ch @ 44.1 kHz **[repo]**. macOS 15 added a built-in-mic-only `multichannelAudioMode`
  whose default `.none` is documented as "single channel audio recording". Whether that
  holds on Macs, and whether `.stereo` is supported, is untested
  ([processed-audio-without-vpio.md](./processed-audio-without-vpio.md) §3).
- **Chromium's own channel counting** (useful as a reference implementation) sums
  `mNumberChannels` over `kAudioDevicePropertyStreamConfiguration`. For input it reads the
  AUHAL input-element stream format. If the result is > 2 channels it logs "Failed to get
  the device channels, use stereo as default"
  ([chromium media/audio/mac/audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc)).
  **[inference]** So Chrome's own capture of a > 2-channel input is a 2-channel client
  format. With the AUHAL default channel map, that is the first two device channels.

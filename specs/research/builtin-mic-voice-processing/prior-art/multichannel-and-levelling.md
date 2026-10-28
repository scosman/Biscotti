# Prior art: multichannel inputs, the built-in mic array, and software levelling

**Researched:** 2026-10-28. How other apps reduce a multichannel input (the MacBook built-in array, audio interfaces) to the mono mic they record, and how they fix level without Apple voice processing. The DSP itself is the post-processing subtopic's job, and how the array is exposed is the array subtopic's job. This file records what others *did* and the measurements they *published*.

## 1. The built-in array changes shape when a call starts, and naive downmixes lose the voice

Several independent reports describe the same thing Biscotti saw (3 channels at 44.1 kHz, all very quiet, when a meeting app holds the mic):

| Source | Observation | Measurement / fix |
|---|---|---|
| Apple Community, MacBook Air M1, macOS 13.5 ([thread 255090182](https://discussions.apple.com/thread/255090182), 2023-08-27) | "when i start a call the microphone becomes 3 channels" (otherwise 1 channel) | user workaround: flip the output device after the call starts |
| OpenOats [PR #561](https://github.com/yazinsai/OpenOats/pull/561) (merged 2026-05-01), M-series MacBook Air, during a WhatsApp self-call | Averaging the 3 channels "silently attenuates the recorded voice by ~25 dB"; the author claims channel 0 is "the front-facing primary beam" and channels 1+ are "directional/cancellation" beams | peak −70 dB (average) → **−7 dB (channel 0)**. *The beam-role explanation is the PR author's and unsourced; the PR footer says it was generated with an AI assistant* |
| TypeWhisper [PR #755](https://github.com/TypeWhisper/typewhisper-mac/pull/755) (merged 2026-06-19), FaceTime running | "the built-in MacBook microphone reported a 3-channel input route where speech was effectively lost by the normal mono path" | pick the **highest-energy channel**, and enable VPIO only for "3-channel built-in default input"; logged `peakLevel=0.0459` afterwards |
| Meetily `audio_to_mono` comment | "Many microphone arrays have auxiliary channels for beam-forming/noise cancellation that can contain anti-phase signals. Averaging all channels can cause destructive interference resulting in near-zero output." | average only the first 2 channels. *No measurement given* |
| Transcripted #959 (in [#500](https://github.com/r3dbars/transcripted/issues/500) closing note) | "stereo mics with a silent second channel had speech halved before transcription" | strongest-channel downmix (`MicrophoneDownmix.swift`: "Microphone channels can be silent duplicates or opposite-polarity pairs. Keep the strongest channel instead of cancelling speech by averaging them.") |
| MacWhisper release notes | "Fixed: Starting or ending a FaceTime or other call during a recording could break the recording's microphone track" | the format change mid-recording broke their file writer |
| Asahi Linux / [triforce](https://github.com/chadmed/triforce) | Apple "implement an adaptive beamformer in userspace … Without beamforming, the array is far too sensitive and omnidirectional to be at all useful" | an MVDR beamformer on Linux. [asahi-audio PR #85](https://github.com/AsahiLinux/asahi-audio/pull/85): with one of 3 inputs unlinked, the beamformer output was "near-silence" (0.42 %FS → 2.89 %FS once fixed) |

**Conflicting evidence.** Biscotti's own instrumented capture measured `ch0≈ch1≈ch2≈0.004`, so all three channels were quiet and averaging was *not* the cause (`specs/research/audio/mic_capture_level_findings.md`). OpenOats measured channel 0 at about −7 dBFS peak. Possible explanations: different machines or macOS versions, a different meeting app (WhatsApp versus Meet/FaceTime), or the AVAudioEngine tap seeing different data from the AVCaptureSession path. The array subtopic should resolve this. Until then, "take channel 0" is not proven safe on every model; "take the strongest channel" is the more defensive choice. *That ranking is my inference.*

## 2. Downmix strategies in use

| Strategy | Who | Notes |
|---|---|---|
| Average all channels | anarlog (`rt_ring.rs`), Corti, OpenOats (before #561), Transcripted (before #959) | the common default; reported to lose voice on built-in arrays |
| Average first 2 channels | Meetily | heuristic aimed at arrays |
| Channel 0 | OpenOats (after #561); MacParakeet and Biscotti for VPIO's 9-channel output | VPIO's processed mono is on channel 0 (the Scripta precedent, already in Biscotti's research) |
| Strongest channel (per buffer, by energy) | Transcripted, TypeWhisper | robust to silent and anti-phase channels; per-buffer switching could cause discontinuities (*my inference; neither project reports it*) |
| Ask the engine/AUHAL for a mono client format | Prismical (AUHAL, 1 ch), quill, TypeWhisper (non-3-ch case) | TypeWhisper: "AVAudioConverter silently produces zero-filled output when asked to downmix non-standard multi-channel layouts (e.g. 6-channel USB interfaces like Focusrite Scarlett) to mono. By requesting a mono tap format, AVAudioEngine performs the channel downmix internally". *Biscotti hit the same silent-zeros failure with a 3ch→mono `AVAudioConverter`* |
| **User-selected channel map** | OBS (`kAudioOutputUnitProperty_ChannelMap`, per output channel; default downmix), VoiceInk (automatic = device's preferred stereo channels, else first 2; manual = one channel), Audio Hijack (Channels block) | the pro-audio answer for 12+ input interfaces. Before OBS had it, users needed Loopback or Audio Hijack ([issue #2556](https://github.com/obsproject/obs-studio/issues/2556)) |
| Follow the meeting app's mic | Recall.ai SDK ("attempts to identify the microphone used by the meeting application"), Screenpipe "piggyback" | avoids recording a different mic from the one the call uses |

**Bluetooth headsets.** anarlog (1.4.18), Superwhisper, Granola and MacParakeet all steer recording to the built-in or wired mic when the default input is a Bluetooth headset, to avoid HFP's low quality ("muffled, gated call-mode mic", anarlog). Screenpipe found the opposite hazard: re-opening a Bluetooth mic it was following "starved the meeting app of its own microphone … an SCO renegotiation storm (#3750) that killed the app's capture" (`audio_manager/meeting_piggyback.rs` header). MacParakeet found that explicitly pinning the built-in device sometimes fails (`-10868`) where the implicit default route works ([`docs/research/2026-07-14-microphone-routing-first-principles.md`](https://github.com/moona3k/macparakeet/blob/main/docs/research/2026-07-14-microphone-routing-first-principles.md)).

## 3. Software levelling without VPIO

| App | Method | Parameters | Stated limits |
|---|---|---|---|
| **Transcripted** `RealtimeAGC` (default since 1.1.25) | peak-tracking AGC in the tap callback; fast attack, slow release; allocation-free | `targetPeak = 0.45`, `maxGain = 25.0` (was 12), `minPeak = 0.0008`, `noiseGatePeak = 0.002` | fixes "Volume scalar drops … linear and recoverable with gain"; does **not** fix "voice-mode capture … No amount of gain can bring back speech the OS already gated out" |
| **Meetily** `LoudnessNormalizer` | stateful EBU R128 integrated loudness to **−23 LUFS** with a 10 ms true-peak limiter (−1 dBTP), after an 80 Hz high-pass | `ebur128` crate | gain computed from cumulative loudness, so slow to react |
| **anarlog** `norm.rs` | same EBU R128 −23 LUFS design | | defined but used only in a test |
| **Granola** (dormant native addon) | `applyAutoGain:` triggered by `inputVolumeDidChange` | flag `automatic_gain_compensation` | *purpose inferred by the teardown: compensating OS input-volume changes made by other apps* |
| **Screenpipe** Sonora | WebRTC AGC2 adaptive digital (in the opt-in AEC mode) | NS VeryHigh | — |
| **Superwhisper** | "dynamic normalization", "Enhanced gain recovery for whisper-level recordings" ([changelog 2.14.0](https://superwhisper.com/changelog)) | not disclosed | — |
| **Audio Hijack** | user-placed gain blocks ("Magic Boost", per existing Biscotti research) | — | — |

**On the shared input-volume scalar.** The Hushboard README says: "On Apple Silicon Macs, `kAudioDevicePropertyVolumeScalar` at the input scope is the *input monitoring* level; it's already 0.0 by default and does **not** silence what apps record" ([huseyinium/hushboard](https://github.com/huseyinium/hushboard)). This agrees with Biscotti's finding that forcing the scalar back to 1.0 "did **not** meaningfully restore the level", even though the scalar does move (0.27 under Meet, 0.67 idle). It weakens the theory that the shared hardware gain written by call apps' AGC is the main cause of the quiet *recording*. MacParakeet held the AGC-writes-shared-gain theory as the cause of the *outgoing* voice degradation. *Both are inferences; neither project measured the receiving end with AGC on versus off.*

## 4. What this means for a "built-in → strategy X" rule (inference)

- Other apps detect the problematic state as **built-in transport AND channel count == 3** (TypeWhisper), or as **sustained deep attenuation while AGC is pinned at max** (Transcripted's `QuietMicAttenuationDetector`). Both are cheap signals Biscotti could reuse.
- In that state the shipped responses were: (a) strongest-channel plus gain (Transcripted default), (b) VPIO (TypeWhisper unconditionally in that state; Transcripted only with consent and never when a desktop call app is running), (c) nothing at capture time, relying on post-processing (anarlog, MacParakeet).
- For audio interfaces, the field standard is an explicit **channel picker** (OBS, VoiceInk, Audio Hijack), with "device preferred stereo channels" (`kAudioDevicePropertyPreferredChannelsForStereo`) as the automatic default (VoiceInk).

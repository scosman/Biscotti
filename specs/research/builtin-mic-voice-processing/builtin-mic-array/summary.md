# Built-in mic array and multi-channel input

Research date: 2026-10-28 (macOS 15, 26 and 27 in the field). Part of the "built-in mic quality vs. voice processing (VPIO) side effects" research ([research_plan.md](../research_plan.md)).

## Bottom Line

The MacBook built-in mic is three raw, preamp-less PDM capsules (two on the MacBook Neo); all beamforming and levelling is Apple software. A plain (non-VPIO) client normally gets **one processed channel at normal level**. But as soon as any app uses Apple voice processing (FaceTime, most meeting apps, or our own VPIO), the shared device switches to the **raw multichannel array**: 3 channels, speech around −48 dBFS, sometimes at 44.1 kHz. During a meeting, a plain tap therefore records raw capsules, and the format and level both jump at call start and end.

No public non-VPIO API returns Apple's beamformed, echo-cancelled mono. The one promising lead is macOS 14+ per-app **Mic Mode → "HAL Voice Isolation"**, which already applies to non-VP apps. Apps can read the mode and open the picker but not set it, and its effect on the raw built-in array is untested. Short of that, the robust path for the built-in mic is mode-aware processing:

- 1 channel → pass through;
- raw array → polarity- and lag-checked sum, then make-up gain, AGC and a limiter;
- VPIO format → channel 0.

Echo is left to AEC or isolation in post. For every device: count channels properly, let the user pick a device by UID and a channel, auto-detect the live channel, and identify the built-in mic by **UID `BuiltInMicrophoneDevice` plus transport `bltn`**. Transport alone is not enough, because the headphone-jack mic is also `bltn`.

## Key Findings

- **Hardware is raw.** "Three Pulse Density Modulation (PDM) mics … plumbed directly to userspace on separate channels, with no preamplification … very sensitive and omnidirectional", about 2 cm apart; a naive delay-and-sum "cannot achieve the temporal resolution required" ([Asahi docs](https://asahilinux.org/docs/sw/audio-userspace/), [Asahi 6.14 report](https://asahilinux.org/2025/03/progress-report-6-14/)). Mic and speaker counts by model: MacBook Pro, 3 mics and 6 speakers; MacBook Air 13", 3 and 4; **MacBook Neo, "Dual-mic array"** and 2 speakers ([Apple specs](https://www.apple.com/macbook-neo/specs/), [MBA 13" M4](https://support.apple.com/en-us/122209), [MBP 14" M4](https://support.apple.com/en-us/121552)).
- **1 channel normally, 3 during calls.** One MacBook Air user: "the internal microphone shows only 1 channel … when i start a call the microphone becomes 3 channels" ([Apple Community, macOS 13.5](https://discussions.apple.com/thread/255090182)). TypeWhisper found the same "built-in 3-channel default input route that FaceTime exposes", where "speech was effectively lost by the normal mono path" ([PR #755](https://github.com/TypeWhisper/typewhisper-mac/pull/755)). This repo measured raw 3 ch at ≈ −48 dBFS during a meeting ([mic_capture_level_findings.md](../../audio/mic_capture_level_findings.md)). Some macOS 26 reports describe 3 ch without saying a call was active, so handle any count. [Details](./channel-modes-by-model.md)
- **The 9 (and likely 7) channel counts are VPIO's mic + speaker-reference channels, not an array mix (hypothesis).** The AUVP log on a 12-in/16-out interface shows "mic channel count: 12, ref channel count: 16" → 28 ch ([issue #66](https://github.com/scosman/Biscotti/issues/66#issuecomment-5583791101)). By the same arithmetic, MBP 3 + 6 = 9 (matches what the repo measured) and MBA 13" 3 + 4 = 7. Unverified; probe P2. Take only channel 0 from a VPIO format.
- **Mic Mode now reaches non-VP apps.** In 2021 Apple said "your app must adopt … AUVoiceIO" for Mic Modes and "your app can't set the Mic Mode directly" ([WWDC21 10047](https://developer.apple.com/videos/play/wwdc2021/10047/)). Since **macOS 14**, Voice Isolation affects DAWs that don't use VPIO, for example "all inputs receiving signal from input 1" ([Focusrite KB, 2026](https://support.focusrite.com/hc/en-gb/articles/15437020104082); [UA KB](https://help.uaudio.com/hc/en-us/articles/26704705384980)). Logs show `HALSystem.cpp … Enabling HAL Voice Isolation support` in a plain HAL client ([MacRumors log](https://forums.macrumors.com/threads/audiorouternow-free-open-source-audio-router-for-macos-no-kext-menu-bar.2484444/)), and "Disabling HAL Voice Isolation support due to app's use of existing chat flavors" in Biscotti's VPIO process (issue #66). Public API is read and prompt only: `preferredMicrophoneMode`, `activeMicrophoneMode`, `showSystemUserInterface(.microphoneModes)`. [Details](./processed-audio-without-vpio.md)
- **Other non-VP routes are dead ends or unverified.**
  - AVAudioSession data sources and polar patterns: not on macOS.
  - `'nzca'` ambient noise reduction: Intel-era.
  - Aggregates: concatenate raw streams, and are truncated under Voice Isolation ([forum 787240](https://developer.apple.com/forums/thread/787240)).
  - ScreenCaptureKit mic: "does NOT echo cancel" ([SO](https://stackoverflow.com/questions/78235302/synchronizing-screencapturekit-with-microphone-audio)).
  - macOS 26/27: no new mic-processing API found.
  - Untested but plausible: AVCaptureSession `multichannelAudioMode` (macOS 15+, "only takes effect … through the built-in microphone", default "single channel") ([docs](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/multichannelaudiomode)).
- **Down-mixing: level is the real problem, not directivity.**
  - Summing gives at most +4.8 dB of self-noise SNR for 3 capsules ("3 dB improvement of SNR" per doubling, [AN-1140](https://admin-uat.invensense.com/sites/default/files/2026-01/Microphone-Array-Beamforming_0.pdf)).
  - Unaligned summing combs from ~4 kHz, with a null near 8.6 kHz for an endfire talker. Integer-lag alignment at 48 kHz fixes that.
  - Capsules can differ by ~10 dB (T2 measurement: [omarchy #8526](https://github.com/omacom/omarchy/discussions/8526)).
  - [OpenOats PR #561](https://github.com/yazinsai/OpenOats/pull/561)'s claim that channels are "anti-phase" beams is unverified and conflicts with the repo's data.
  - Recommended: polarity- and lag-checked weighted sum with fallback to the best single channel, then high-pass, stateful AGC ([TypeWhisper PR #1114](https://github.com/TypeWhisper/typewhisper-mac/pull/1114) lesson) and a limiter.
  - Skip MVDR ("Do not expect it to outperform Apple's implementation", [Triforce](https://github.com/chadmed/triforce)).

  [Details](./downmixing-raw-array.md)
- **Multi-channel interfaces.**
  - Count channels via `kAudioDevicePropertyStreamConfiguration`, as Chromium does ([audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc)), not via the AUHAL element count ([forum 763325](https://developer.apple.com/forums/thread/763325)).
  - Select the device on `inputNode.audioUnit` with `kAudioOutputUnitProperty_CurrentDevice`, never by changing the system default ([ghost-pepper #60](https://github.com/matthartman/ghost-pepper/issues/60)).
  - Pick channels in software. The `channelMap` path on the input node has conflicting reports ([TN2091](https://developer.apple.com/library/archive/technotes/tn2091/_index.html), [SO 79429470](https://stackoverflow.com/questions/79429470/regarding-the-auaudiounit-channelmap-issue-on-macos-with-avaudioengine)).
  - Auto-detect the live channel by per-channel speech-band SNR, with stickiness and a dead-channel warning. The issue-#66 iD24 had its mic on input 2, with −120 dB on the other inputs.
  - Prior-art UIs: Zoom's "Use specific audio input channels" ([KB](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0057961)) and Audio Hijack's per-block channel selectors ([KB](https://rogueamoeba.com/support/knowledgebase/?product=Audio+Hijack&showArticle=Misc-Audio-Channel-Handling)).

  [Details](./multichannel-devices-and-builtin-detection.md)
- **Built-in detection rule:** `transport == kAudioDeviceTransportTypeBuiltIn && UID == "BuiltInMicrophoneDevice"`. The jack mic is `bltn` with UID `BuiltInHeadphoneInputDevice` and data source `'emic'`, versus `'imic'` for the built-in ([TypeWhisper #1163](https://github.com/TypeWhisper/typewhisper-mac/issues/1163)). Never match on the localised name. The mic is physically disconnected when the lid is closed ([Apple Platform Security](https://support.apple.com/guide/security/secbbd20b00b/web)). The Studio Display array mic is USB, VID 05AC ([SO 24944614](https://stackoverflow.com/questions/24944614/finding-the-usb-vid-pid-associated-with-a-coreaudio-device-on-osx)). Its behaviour is unverified. Read the *current channel count* of the built-in device to know which mode you are in.

## Details

- [channel-modes-by-model.md](./channel-modes-by-model.md): hardware, per-model mic and speaker counts, the 1 / 3 / 9 (7?) channel modes with evidence, channel contents, and how AUHAL, AVAudioEngine, AVCaptureSession and Chrome count channels. Read before writing channel-handling code.
- [processed-audio-without-vpio.md](./processed-audio-without-vpio.md): every non-VPIO route to Apple-processed mic audio, covering the plain 1-ch path, HAL Voice Isolation via Mic Mode, AVCaptureSession `multichannelAudioMode`, ScreenCaptureKit, dead ends, and macOS 26/27 APIs. Read when choosing the capture strategy.
- [downmixing-raw-array.md](./downmixing-raw-array.md): physics (spacing, comb frequencies, SNR), an options table (pick, strongest, average, aligned sum, DAS, MVDR, differential), a concrete algorithm, and test fixtures. Read when implementing the raw-array path.
- [multichannel-devices-and-builtin-detection.md](./multichannel-devices-and-builtin-detection.md): channel counting, device and channel selection APIs and gotchas, prior-art UIs, a live-channel auto-detect design, the built-in detection rule, and a look-alike device table. Read when implementing device and channel selection.
- [open-questions-and-probes.md](./open-questions-and-probes.md): seven concrete on-hardware probes, ranked (P1 HAL Voice Isolation for a plain client; P2 mode census and 7/9 hypothesis; P3 raw phase/lag; P4 AVCaptureSession multichannel mode; …), plus unanswered questions.

## Open Questions / Gaps

- **HAL Voice Isolation on the built-in array for a plain client.** Does it beamform and level, or does it isolate capsule 1 only? Does it disturb the meeting app? Not documented anywhere; needs probe P1.
- **What the plain 1-ch path processes on Apple silicon.** Beamforming, noise reduction and AGC are all undocumented. The only statement found is Chromium's Intel-era note about macOS "hardware noise suppression".
- **The "7 channel" figure** in issue #66 is unexplained by any source. The mic + speaker reference hypothesis (3 + 4 on MBA 13") is unverified.
- **AVCaptureSession `multichannelAudioMode` support on Macs.** No Mac usage or report found.
- **MacBook Neo raw channel count; Studio Display mic modes.** No reports found.
- **Exact conditions for 3 ch.** Two reports from macOS 26 describe 3 ch without saying whether a VP client was active.
- **Access gaps.** `asahilinux.org`, `discussions.apple.com`, `arxiv.org`, `mathworks.com` and `miniswift.run` were not reachable with the direct fetch tool in this session; I read them through the Tavily/Exa extractors instead. The backant-io/shepetal research pages (Mic Mode WER notes) returned 404, so their claim is used only as an unverified aside. GitHub API access to `chadmed/triforce` was blocked; I read raw files instead.

## Sources

- [Asahi Linux: Userspace Audio Stack](https://asahilinux.org/docs/sw/audio-userspace/): primary description of MacBook mic hardware (PDM, AOP, no preamp); current docs.
- [Asahi Linux: Progress Report Linux 6.14](https://asahilinux.org/2025/03/progress-report-6-14/): 2 cm spacing, why delay-and-sum failed, Triforce rationale; Mar 2025.
- [chadmed/triforce README](https://github.com/chadmed/triforce) and [src/lib.rs](https://raw.githubusercontent.com/chadmed/triforce/main/src/lib.rs): MVDR implementation details and caveats; 2025.
- [omarchy discussion #8526](https://github.com/omacom/omarchy/discussions/8526): measured raw T2 MBP 16" capsule levels and DSP gain; Aug 2026.
- [Apple tech specs: MBP 14" M4](https://support.apple.com/en-us/121552), [MBA 13" M4](https://support.apple.com/en-us/122209), [MacBook Neo](https://www.apple.com/macbook-neo/specs/), [Studio Display](https://support.apple.com/en-us/111890): mic and speaker counts; 2024–2026.
- [Apple Developer Forums 763325](https://developer.apple.com/forums/thread/763325): built-in mic stream format 1 ch; AUHAL element count ≠ channels (Apple staff); Sep 2024.
- [Apple Community 255090182](https://discussions.apple.com/thread/255090182): MBA M1 is 1 ch normally and 3 ch during a call; macOS 13.5, Aug 2023.
- [Apple Community 251401935](https://discussions.apple.com/thread/251401935): 2019 MBP 16" shows 1 input channel; 2020.
- [TypeWhisper PR #755](https://github.com/TypeWhisper/typewhisper-mac/pull/755), [PR #1114](https://github.com/TypeWhisper/typewhisper-mac/pull/1114), [issue #1163](https://github.com/TypeWhisper/typewhisper-mac/issues/1163), [AudioDeviceService.swift](https://raw.githubusercontent.com/TypeWhisper/typewhisper-mac/main/TypeWhisper/Services/AudioDeviceService.swift): 3-ch FaceTime route, strongest-channel and AGC lessons, UID-based built-in detection; Jun–Sep 2026.
- [OpenOats PR #561](https://github.com/yazinsai/OpenOats/pull/561): "channel 0 = primary beam / anti-phase" claim (unverified); May 2026.
- [cpal #1143](https://github.com/RustAudio/cpal/issues/1143): 3-ch MBP array on macOS 26; Apr 2026.
- [Biscotti issue #66 comments](https://github.com/scosman/Biscotti/issues/66): AUVP mic/ref channel log, iD24 mic-on-input-2 failure, HAL Voice Isolation log line, owner's "7 channel" remark; Sep–Oct 2026.
- [WWDC21 10047 "What's new in camera capture"](https://developer.apple.com/videos/play/wwdc2021/10047/): Mic Modes originally required AUVoiceIO; user-only control; 2021.
- [WWDC23 10235 "What's new in voice processing"](https://developer.apple.com/videos/play/wwdc2023/10235/): user mic-mode control under VP; HAL voice-activity detection; 2023.
- [WWDC25 251 "Enhance your app's audio recording capabilities"](https://developer.apple.com/videos/play/wwdc2025/251/): iOS 26 input picker, AirPods HQ, FOA capture, AUAudioMix (macOS 26); 2025.
- Apple docs: [preferredMicrophoneMode](https://developer.apple.com/documentation/avfoundation/avcapturedevice/preferredmicrophonemode), [activeMicrophoneMode](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemicrophonemode), [MicrophoneMode](https://developer.apple.com/documentation/avfoundation/avcapturedevice/microphonemode), [multichannelAudioMode](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/multichannelaudiomode), [AVCaptureMultichannelAudioMode](https://developer.apple.com/documentation/avfoundation/avcapturemultichannelaudiomode), [spatialAudioChannelLayoutTag](https://developer.apple.com/documentation/avfoundation/avcaptureaudiodataoutput/spatialaudiochannellayouttag), [AVCaptureAudioChannel](https://developer.apple.com/documentation/avfoundation/avcaptureaudiochannel), [AVAudioSessionDataSourceDescription](https://developer.apple.com/documentation/avfaudio/avaudiosessiondatasourcedescription), [AVInputPickerInteraction](https://developer.apple.com/documentation/avkit/avinputpickerinteraction), [DeviceType.builtInMicrophone](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtinmicrophone): platform availability and semantics; read 2026-10-28.
- [TN2091: Device input using the HAL Output Audio Unit](https://developer.apple.com/library/archive/technotes/tn2091/_index.html) and [Routing audio to specific devices in multidevice sessions](https://developer.apple.com/documentation/avfaudio/routing-audio-to-specific-devices-in-multidevice-sessions): AUHAL device selection and channel maps.
- [Focusrite KB 15437020104082](https://support.focusrite.com/hc/en-gb/articles/15437020104082) and [UA KB 26704705384980](https://help.uaudio.com/hc/en-us/articles/26704705384980): Voice Isolation in non-VP DAWs since Sonoma; input-1 collapse; Apr 2026 / Sep 2025.
- [Apple Developer Forums 787240](https://developer.apple.com/forums/thread/787240): aggregate channels truncated in Voice Isolation; Jun 2025.
- [MacRumors AudioRouterNow thread](https://forums.macrumors.com/threads/audiorouternow-free-open-source-audio-router-for-macos-no-kext-menu-bar.2484444/): plain HAL client log with `AUVoiceIOChatFlavor` and "Enabling HAL Voice Isolation support"; Jun 2026.
- [InvenSense AN-1140 Microphone Array Beamforming](https://admin-uat.invensense.com/sites/default/files/2026-01/Microphone-Array-Beamforming_0.pdf): broadside summing, SNR +3 dB per doubling, aliasing, matching; 2013 (rev 1.0).
- [Chromium media/audio/mac/audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc): channel counting, > 2-ch stereo fallback, `'nzca'` noise reduction; main branch, read 2026-10-28.
- [blink-dev "disableHwNoiseCanceller"](https://groups.google.com/a/chromium.org/d/msg/blink-dev/NMg2ZFxmsCg/n3jcj0gBBgAJ): macOS built-in mic hardware noise suppression (Intel era); Nov 2017.
- [Apple Platform Security: hardware microphone disconnect](https://support.apple.com/guide/security/secbbd20b00b/web): lid-close mic disconnect on Apple silicon laptops.
- [Zoom KB0057961](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0057961), [Rogue Amoeba channel handling](https://rogueamoeba.com/support/knowledgebase/?product=Audio+Hijack&showArticle=Misc-Audio-Channel-Handling): prior-art channel pickers.
- [ghost-pepper #60](https://github.com/matthartman/ghost-pepper/issues/60), [forum 683348](https://developer.apple.com/forums/thread/683348), [SO 79429470](https://stackoverflow.com/questions/79429470/regarding-the-auaudiounit-channelmap-issue-on-macos-with-avaudioengine): AVAudioEngine device and channel-map gotchas; 2021–2026.
- [Stack Overflow 78235302](https://stackoverflow.com/questions/78235302/synchronizing-screencapturekit-with-microphone-audio), [SO 72953588](https://stackoverflow.com/questions/72953588/why-enabling-voice-processing-on-avaudioinputnode-changes-channels-count-on-its): ScreenCaptureKit mic has no AEC; VP adds channels.
- [openai/whisper audio.py](https://github.com/openai/whisper/blob/main/whisper/audio.py): `SAMPLE_RATE = 16000`, so content above 8 kHz doesn't matter for ASR.
- Repo: [mic_capture_level_findings.md](../../audio/mic_capture_level_findings.md), [phase9_validation_findings.md](../../audio/phase9_validation_findings.md): measured 3-ch raw levels, the 9-ch VPIO format, Mic Mode audible on the VPIO path.

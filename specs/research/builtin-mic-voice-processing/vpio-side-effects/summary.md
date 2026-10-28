# VPIO behaviour and side effects

## Bottom Line

Turning on Apple voice processing (VPIO / `setVoiceProcessingEnabled(true)`) changes shared, system-wide audio state in three separate ways. On the **built-in MacBook mic**, the one that breaks other apps' *microphones* is the first.

1. **Raw-array switch.** AUVP turns on the built-in mic's raw array streams. Every non-VPIO client then gets 3+ quiet, unbeamformed capsules, about 25–30 dB down, until the VPIO unit is disposed.
2. **Ducking.** VPIO ducks every other app's *playback*, including the meeting's far-end audio. The `.min` ducking level reduces this but does not remove it.
3. **Reconfiguration.** VPIO creates a private aggregate device and enables "tap" reference streams on every output device. Biscotti's own forced output sample-rate change adds to this. The result is transient glitches and restarts in other apps.

Which apps break depends on how they capture. Chrome, Edge and Electron apps (Slack huddles, Teams-in-Chrome), and very likely native Teams and probably Zoom, read the plain HAL stream with their own WebRTC-style processing. They become the victims: flat level meters and a hollow-sounding voice. FaceTime, Safari and Firefox are VPIO clients themselves. Their mics are unaffected, and they cause the same attenuation in Biscotti when Biscotti does not use VPIO.

No VPIO knob avoids the mic-side effect: bypass, AGC, mute, ducking level and mic mode all leave it in place. External, USB and Bluetooth mics do not have the raw-array switch.

## Key Findings

- **Apple confirms the mechanism.** A Feedback reply (relayed on SO, ~2021) says the speaker's new input stream "is the reference tap stream for echo cancellation" and the extra built-in mic stream "is the raw mic streams enabled by AUVP… ignore the extra streams" ([SO 64966350](https://stackoverflow.com/questions/64966350/voiceprocessingio-audio-unit-adds-an-unexpected-input-stream-to-built-in-output)). Mozilla: "when used with vpio in one app, it gets 3 very quiet channels exposed to all apps" (filed as FB13697689) ([Mozilla bug 1896938](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)).
- **Measured.** A plain CoreAudio client goes from −36.5 to −66.1 dBFS when VPIO starts (M3 Pro, macOS 26.6.1). It stays attenuated while a pooled VPIO unit is alive and recovers only after disposal. An M5 / 26.5.1 rig measured a 19–29 dB system-wide loss ([bug 1896938 c60–c63](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)). Independent sightings: Biscotti AudioLab, TypeWhisper (FaceTime "3-channel route", [PR #755](https://github.com/TypeWhisper/typewhisper-mac/pull/755)), Transcripted (Safari/Firefox/WhatsApp attenuate others, Chromium does not, [#500](https://github.com/r3dbars/transcripted/issues/500)).
- **Built-in mic only.** Users say external and USB mics are fine ([bug 1896938 c34/c56](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)). This matches #66's headset workaround. The Audient multichannel report in #66 is a separate, less-understood case.
- **Chrome is plain AUHAL.** Chrome's mac capture uses VPIO only behind `EnforceSystemEchoCancellation`, which is `FEATURE_DISABLED_BY_DEFAULT`. Otherwise it is AUHAL with Chrome-wide WebRTC processing. It opens >2-channel inputs as stereo. It writes the system input volume through WebRTC AGC (`WebRtcAllowInputVolumeAdjustment`, enabled by default). It rebuilds all output streams when the default output's nominal sample rate changes ([media_switches.cc](https://github.com/chromium/chromium/blob/main/media/base/media_switches.cc), [audio_low_latency_input.cc](https://github.com/chromium/chromium/blob/main/media/audio/apple/audio_low_latency_input.cc), [audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc)). "Chrome does not use the voice processing in macOS. We [Firefox] and Safari do" ([c66](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)).
- **Ducking is intentional and only partly controllable.** An Apple engineer (Jun 2026): other apps' audio "will be significantly reduced. This is intentional" ([forum 829753](https://developer.apple.com/forums/thread/829753)). The macOS 14+ `voiceProcessingOtherAudioDuckingConfiguration` defaults to "advanced off, Default level" ([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10235/), SDK header). `.min` still "audibly dimmed Zoom playback" ([transcripted PR #1075](https://github.com/r3dbars/transcripted/pull/1075)). Chrome and Firefox fully undo it with the **private** `AudioDeviceDuck(dev, 1.0, nil, 0.5)` ([Chromium](https://github.com/chromium/chromium/blob/main/media/audio/apple/audio_low_latency_input.cc), [cubeb PR #195](https://github.com/mozilla/cubeb-coreaudio-rs/pull/195)).
- **Bypass is not an escape hatch.** "Voice Isolation and Wide Spectrum take priority over Bypass" (`AudioUnitProperties.h`). Bypass keeps the raw-array switch (Mozilla's attenuation measurement *is* bypass mode), is "very quiet" on M3 built-in mics, and has an Apple timing bug ([bug 1903002](https://bugzilla.mozilla.org/show_bug.cgi?id=1903002), [1914046](https://bugzilla.mozilla.org/show_bug.cgi?id=1914046)). AGC and mute do not release the device mode either. Only disposing the VPIO unit does.
- **Mic modes are per app and partly HAL-level.**
  - In macOS 12 they applied only to VPIO apps.
  - From Sonoma, Voice Isolation also applies to non-VPIO audio apps ([PreSonus](https://support.presonus.com/hc/en-us/articles/28066868202637-Audio-Interfaces-macOS-Sonoma-and-Sequoia-audio-quality-and-input-issues), [UA](https://help.uaudio.com/hc/en-us/articles/26704705384980-The-Audio-From-My-Interface-Is-Garbled-or-Even-Silent-on-macOS-Mic-Mode-Setting)).
  - Logs show a per-bundle `AUVoiceIOClients/<bundle>/AUVoiceIOChatFlavor` key and a per-process "HAL Voice Isolation support" toggle. Biscotti's #66 log shows it *disabled* "due to app's use of existing chat flavors" ([tart log](https://github.com/cirruslabs/tart/issues/1105), [#66](https://github.com/scosman/Biscotti/issues/66)).
  - There is no public API to set a mode ([forum 844448](https://developer.apple.com/forums/thread/844448)).
  - The #66 per-app-mode workaround is unexplained and unverified.
- **Two VPIO clients can coexist across processes** (Firefox with Safari, VPIO with FaceTime), but not cleanly:
  - Apple's WebKit says "On macOS, only one VPIO unit can run at a time" ([WebKit f8af49f](https://github.com/WebKit/WebKit/commit/f8af49f640cc922f066d0e349ff119a5ea6a7eb2); the scope is unclear).
  - A developer reports VPIO "cut off the input stream" of another app ([forum 751100](https://developer.apple.com/forums/thread/751100)).
  - Concurrent-AEC bugs are still open on 27.0.1 ([WebKit 255986](https://bugs.webkit.org/show_bug.cgi?id=255986)).
  - Each VPIO client ducks the other's audio (inference from Apple's definition of "other audio").
- **VPIO is fragile on non-standard routes.** It fails with `-10875` on mismatched input/output devices, on a 6-channel Spatial-Audio output and on mismatched sample rates (which is why Biscotti reclocks). VPIO creation takes 2–5 s. Multichannel interfaces log "Timeout waiting for streams" ([forum 772006](https://developer.apple.com/forums/thread/772006), [Forasoft](https://www.forasoft.com/ship-log/spatial-audio-vpio), [forum 756760](https://developer.apple.com/forums/thread/756760)).
- **No version has fixed this.** The macOS 14, 15, 26 and 27 release notes have no VPIO behaviour changes. The only new cross-app control is the macOS 14 ducking API. Attenuation is reproduced on 26.5.1, 26.6.1 and 27.0.1.
- **Implied rule (inference, for the plan).**
  - Built-in mic, and a VPIO meeting app already holds it (detectable as the device growing past 1 input channel before Biscotti starts): VPIO is the right choice. TypeWhisper ships this heuristic.
  - Built-in mic, plain-HAL meeting app (Chrome, Electron, Teams, Zoom): Biscotti's VPIO is what breaks it.
  - External or Bluetooth mic: the mic-side problem does not exist. Ducking and reconfiguration still apply.

## Details

- [mechanisms.md](./mechanisms.md): how VPIO works on macOS, each system-wide side effect (aggregate, tap streams, raw-array switch, ducking, mic modes / HAL Voice Isolation, forced reclock), the cause-by-symptom table for #66, and VPIO coexistence. Read first.
- [knobs-and-apis.md](./knobs-and-apis.md): every control with verbatim header text and availability: ducking config, private `AudioDeviceDuck`, bypass, AGC, mute (VPIO and HAL), muted-talker and HAL VAD, mic-mode APIs, format quirks, lifecycle. Read before changing `LiveMicCaptureEngine`.
- [meeting-app-capture-matrix.md](./meeting-app-capture-matrix.md): FaceTime, Safari, Firefox, Chrome, Electron/Slack, Teams, Zoom and WhatsApp, with how each captures, confidence, and victim/aggressor role. Explains "why Teams/Slack/Chrome". Ends with implications.
- [version-timeline.md](./version-timeline.md): macOS 10.15 → 27 changes relevant to VPIO, from the release notes, WWDC and dated reports.

## Open Questions / Gaps

- **Teams and Zoom capture APIs are not public.**
  - Teams: the SlimCore media engine; behaviour in #66 fits a plain-HAL client.
  - Zoom: its KB describes software AEC and it had no Mac mic modes in 2022.
  - Neither is confirmed. A one-minute `log stream` (filtered to `com.apple.coreaudio` / `auvp`) while each app joins a call would settle it: look for `AUVPAggregate` lines in that app's process.
- **Residual ducking at `.min` was never quantified.** Nor has `AudioDeviceDuck` undo been confirmed to work on macOS 26/27.
- **Scope of WebKit's "only one VPIO unit can run at a time".** Per process, per device or system-wide? It contradicts cross-process observations unless it means one capture device.
- **The Audient / multichannel disruption mechanism** in #66 is unexplained. The raw-array switch is documented only for built-in mics.
- **The #66 per-app mic-mode workaround** (Voice Isolation for Chrome, Standard for Biscotti) has no mechanism. It needs a hardware test.
- **HAL VAD** (`kAudioDevicePropertyVoiceActivityDetectionEnable`). Untested whether enabling it triggers the raw-array switch.
- **Firefox's current behaviour.** Firefox main's Cargo.toml (Oct 2026) no longer shows `vpio-forcelist`. I could not find the change.
- **Unfetchable sources.** No macOS 26/27 SDK header mirror was available, so header text is from the 15.5 SDK. Point-release notes were not checked. lists.apple.com and bugs.webkit.org were reachable only through Exa. The Reddit "Ventura universal voice isolation" thread was not readable.
- **Correction for the internal-evidence lane:** `mic_capture_level_findings.md` cites WebKit Bug 218012 as evidence of mic-volume ducking. That bug is iOS-only playback volume ("Does not reproduce on macOS"). The system input-volume drops are better explained by Chrome's WebRTC input-volume adjustment ([WebKit 218012](https://bugs.webkit.org/show_bug.cgi?id=218012)).

## Sources

- [WWDC23 10235 "What's new in voice processing"](https://developer.apple.com/videos/play/wwdc2023/10235/): ducking API, muted talker, HAL VAD, mic modes via VP (Jun 2023).
- [WWDC19 510](https://developer.apple.com/videos/play/wwdc2019/510/): AVAudioEngine VP mode introduced (2019).
- [WWDC25 251](https://developer.apple.com/videos/play/wwdc2025/251/): 2025 recording APIs (input picker, AUAudioMix); no VPIO change.
- [macOS 15.5 SDK headers (mirror)](https://github.com/alexey-lysiuk/macos-sdk/tree/main/MacOSX15.5.sdk): verbatim `AudioUnitProperties.h`, `AVAudioIONode.h`, `AudioHardware.h`.
- [Apple forum 829753](https://developer.apple.com/forums/thread/829753): Apple engineer on intentional ducking and band-limited VP output (Jun 2026).
- [Apple forum 772006](https://developer.apple.com/forums/thread/772006) / [810129](https://developer.apple.com/forums/thread/810129): AUVPAggregate `-10875` on mismatched devices (2025).
- [Apple forum 756760](https://developer.apple.com/forums/thread/756760): VPIO instantiation 2–5 s, FB13879429 (2024).
- [Apple forum 751100](https://developer.apple.com/forums/thread/751100): VPIO in one app cuts another's input (May 2024, unanswered).
- [Apple forum 93995](https://developer.apple.com/forums/thread/93995): pre-14 ducking had no macOS control (2017).
- [Apple forum 728370](https://developer.apple.com/forums/thread/728370), [741658](https://developer.apple.com/forums/thread/741658), [844448](https://developer.apple.com/forums/thread/844448): bypass vs mic modes, 2018+ hardware, no mic-mode setter.
- [SO 64966350](https://stackoverflow.com/questions/64966350/voiceprocessingio-audio-unit-adds-an-unexpected-input-stream-to-built-in-output): Apple Feedback reply on tap stream and raw mic streams (2020–21).
- [SO 67260345](https://stackoverflow.com/questions/67260345/mac-audiounit-audiocomponentinstancedispose-crash): stack trace showing VPIO ducking through `AudioDeviceDuck` in AudioDSP.
- [Mozilla bug 1896938](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938): raw-array attenuation analysis and measurements, 2024 → Sep 2026 (macOS 14–26).
- Mozilla bugs [1922313](https://bugzilla.mozilla.org/show_bug.cgi?id=1922313), [1914046](https://bugzilla.mozilla.org/show_bug.cgi?id=1914046), [1903002](https://bugzilla.mozilla.org/show_bug.cgi?id=1903002), [1895787](https://bugzilla.mozilla.org/show_bug.cgi?id=1895787), [1875235](https://bugzilla.mozilla.org/show_bug.cgi?id=1875235), [1865996](https://bugzilla.mozilla.org/show_bug.cgi?id=1865996), [1404972](https://bugzilla.mozilla.org/show_bug.cgi?id=1404972): cross-app volume, bypass bugs, stuck states, tap-stream devices, ducking.
- [cubeb-coreaudio-rs source](https://github.com/mozilla/cubeb-coreaudio-rs/blob/trailblazer/src/backend/mod.rs), [PR #195](https://github.com/mozilla/cubeb-coreaudio-rs/pull/195), [PR #185](https://github.com/mozilla/cubeb-coreaudio-rs/pull/185), [commit 361d2bb](https://github.com/mozilla/cubeb-coreaudio-rs/commit/361d2bbe65b464fee918dd2d4871205c071e3038), [issue #239](https://github.com/mozilla/cubeb-coreaudio-rs/issues/239): Firefox's VPIO handling (2023–26).
- Chromium source: [media_switches.cc](https://github.com/chromium/chromium/blob/main/media/base/media_switches.cc), [audio_low_latency_input.cc](https://github.com/chromium/chromium/blob/main/media/audio/apple/audio_low_latency_input.cc), [audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc), [audio_device_listener_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_device_listener_mac.cc), [webrtc_features.cc](https://github.com/chromium/chromium/blob/main/media/webrtc/webrtc_features.cc): Chrome's capture path (main, fetched 2026-10-28).
- WebKit commits [f8af49f](https://github.com/WebKit/WebKit/commit/f8af49f640cc922f066d0e349ff119a5ea6a7eb2), [7ca4198](https://github.com/WebKit/WebKit/commit/7ca419834e5cf349386849b51920d2b81d9ecb86), [a1aedbe](https://github.com/philn/WebKit/commit/a1aedbea4cfe885239f6af96b937de0f2c995b2e); bug [255986](https://bugs.webkit.org/show_bug.cgi?id=255986): Safari's VPIO handling and concurrent-AEC bug (2023–26).
- [Biscotti issue #66](https://github.com/scosman/Biscotti/issues/66): user reports and the AUVP log lines (2026).
- [TypeWhisper PR #755](https://github.com/TypeWhisper/typewhisper-mac/pull/755), [transcripted #500](https://github.com/r3dbars/transcripted/issues/500) / [PR #1075](https://github.com/r3dbars/transcripted/pull/1075), [FineTune PR #311](https://github.com/ronitsingh10/FineTune/pull/311), [Forasoft](https://www.forasoft.com/ship-log/spatial-audio-vpio), [openai/codex #12111](https://github.com/openai/codex/issues/12111): independent 2026 observations of attenuation, ducking, Spatial-Audio failure and Chromium input-volume writes.
- [PreSonus KB](https://support.presonus.com/hc/en-us/articles/28066868202637-Audio-Interfaces-macOS-Sonoma-and-Sequoia-audio-quality-and-input-issues), [UA KB](https://help.uaudio.com/hc/en-us/articles/26704705384980-The-Audio-From-My-Interface-Is-Garbled-or-Even-Silent-on-macOS-Mic-Mode-Setting), [tart #1105 log](https://github.com/cirruslabs/tart/issues/1105): Sonoma Voice Isolation for non-VPIO apps; chat-flavor and HAL VI log lines.
- [Zoom advanced audio KB](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0066398), [Teams architecture blog](https://techcommunity.microsoft.com/t5/microsoft-teams-blog/microsoft-teams-advantages-of-the-new-architecture/ba-p/3775704), [Microsoft MC891240](https://mc.merill.net/message/MC891240), [The Verge 2022](https://www.theverge.com/23123578/apple-voice-isolation-facetime-calls): Zoom and Teams processing; Zoom's 2022 lack of Mac mic modes.
- macOS [14](https://developer.apple.com/documentation/macos-release-notes/macos-14-release-notes) / [15](https://developer.apple.com/documentation/macos-release-notes/macos-15-release-notes) / [26](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes) / [27](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes) release notes: no VPIO items (fetched via the docs JSON endpoint, 2026-10-28).

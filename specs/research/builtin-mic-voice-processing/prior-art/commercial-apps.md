# Commercial apps and SDKs: what is publicly known about their mic handling

**Researched:** 2026-10-28. Per the research plan, this uses public material only: support docs, changelogs, vendor blogs, HN and forum threads, and one published third-party static teardown. Nothing here was reverse-engineered by me. Most vendors do not say how they capture the mic, so many cells read "not disclosed".

## Summary table

| Product | Mic capture (as disclosed) | VPIO? | Own AEC / NS / AGC | Separate mic/system? | Headphones guidance | Source quality |
|---|---|---|---|---|---|---|
| **Granola** (Mac) | Chromium `getUserMedia` in an Electron renderer, `echoCancellation: {ideal: "all"}` by default (server-flag switchable down to "disable_all_voice_processing"); a dormant native addon has AUHAL mic + WebRTC AEC3 | Native addon: **not VPIO** (AUHAL). Whether Chromium's `"all"` mode uses VPIO on macOS: **unknown** | AEC on by default; dormant flags for headphone bypass and gain compensation | Yes ("Me" = mic, "Them" = system) | "Using a headset where appropriate"; turn mic input volume up; use the built-in mic with Bluetooth headsets | third-party static teardown (v7.663.2) + official docs |
| **Recall.ai Desktop Recording SDK** | SDK picks "the microphone used by the meeting application", else the default; no override on macOS | No (their docs list WebRTC-based AEC) | **WebRTC-based AEC built in** | Yes | "detect the output device type and accordingly enable or disable AEC" | vendor docs and blog |
| **RecordKit** (Nonstrict SDK) | not disclosed | No | **WebRTC AEC3**, reference from a Core Audio process tap; off by default; presets | Yes | — | vendor API docs |
| **Krisp** | Inserts **virtual devices** (Krisp Microphone / Krisp Speaker) between the hardware and the call app | No | AEC needs **both** Krisp devices selected (it owns playback); recommends disabling OS/app AGC, NS, EC | (note taker records via its devices) | best = wired USB boom headset | vendor help center |
| **MacWhisper** | not disclosed | not disclosed | "Echo cancellation" beta, then "Now on for everyone, made possible by the move to CoreAudio" (system audio via Core Audio taps, macOS 26+) | Yes ("separate microphone and app audio tracks") | beta copy: for "transcribing a meeting without wearing headphones" | release notes (mirror) + press |
| **Otter** (desktop) | mic + "Screen & audio recording" permission | not disclosed | not disclosed | implied | desktop app "allows you to wear headphones"; browser mode records only what the mic hears | vendor help center |
| **Notion AI Meeting Notes** | desktop: system audio + mic (macOS 13+); browser: mic only | not disclosed | not disclosed | implied (speaker labels from mic vs system) | browser mode misses others on headphones | vendor help center |
| **Jamie** | default mic + system audio (macOS 14.4+) | not disclosed | not disclosed | implied | "Headphone mode" captures system output | vendor docs/changelog |
| **Superwhisper Meetings** | "Your microphone and the call audio record on separate channels" | not disclosed | not disclosed; its "Muffle/Lower" ducking pauses during meetings | Yes | with a Bluetooth headset, pick the built-in mic | vendor docs/blog |
| **Loom** (desktop) | Loom audio driver for system audio | not disclosed | a "background noise filter" (per a third-party blog) | No (one file) | "Why do I have an echo in my recording? … Use headphones (with a microphone)." | vendor help center |
| **Fathom 3.0** (bot-free) | "Capture Now"; "Automatically Detect Mute" setting | not disclosed | not disclosed | — | — | vendor help center |
| **Bluedot** (desktop) | macOS 12.3+; Zoom/Teams/Meet/Slack huddles | not disclosed | not disclosed | — | — | vendor help center |
| **Rewind / Limitless** | not disclosed (a 2022 teardown covers only the screen pipeline) | — | — | — | — | — |
| **Audio Hijack** (Rogue Amoeba) | "Input Device" block (no voice processing); app capture via the ARK backend (macOS 14.4+) | No | user-placed effects (e.g. "Speech Denoise" block, AUs); SoundSource can host Apple's `AUSoundIsolation` | Yes (user-built) | for top quality, a "double-ender" | vendor KB and release notes |

---

## Details and quotes

### Granola

**Official docs.** "Where speaker tags aren't available or enabled yet, you'll see Me and Them in the transcript, corresponding to your microphone input and your system audio." Accuracy tips: "Ensuring your audio devices are set up correctly, and that the input volume of your microphone isn't too low" and "Using a headset where appropriate to minimize background noise" ([How transcription works](https://docs.granola.ai/help-center/taking-notes/transcription)). Granola's Google Meet guide adds: "For best accuracy, turn your mic input volume all the way up in System Settings > Sound" ([blog, 2026-03-20](https://www.granola.ai/blog/granola-google-meet-integration-recording-transcription)).

**Third-party static teardown** of Granola desktop **v7.663.2** ([notewell `docs/02-transcription.md`](https://github.com/chaharnishant11/notewell/blob/claude/granola-reverse-engineer-lqp79l/docs/02-transcription.md)). Its author tags each claim Observed, Inferred or Unknown, and nothing was executed. I have not verified it.

- "On macOS the microphone comes from `getUserMedia` with WebRTC echo cancellation in `all` mode. System audio comes from `getDisplayMedia`, which main answers with a loopback source: a Core Audio process tap on macOS 14+, ScreenCaptureKit on macOS 13." (Observed)
- The mic constraint modes are driven by the server flag `transcription_mic_capture_processing`: `default`, `disable_echo_cancellation`, `disable_noise_suppression`, `disable_echo_and_noise_suppression`, `disable_all_voice_processing`. (Observed) *That they kept server-side switches to turn voice processing off suggests they hit cases where it hurt. This is an inference.*
- The dormant native addon: "Mic through an **AUHAL** unit (`auou/ahal/appl`), not VoiceProcessingIO", plus "Statically linked **WebRTC AEC3**. System audio is the far-end reference". It also has "AEC bypass when the output device looks like headphones (flag `disable_echo_cancellation_on_headphones`)", detected by matching "AirPods" in the device name, and "Gain compensation against OS input-volume changes (flag `automatic_gain_compensation`)" via `applyAutoGain:` / `inputVolumeDidChange`. (Observed symbols; purpose Inferred.) Why the native path is unused on macOS is "Unknown".
- **Open question** (for the VPIO subtopic): how Chromium implements `echoCancellation: "all"` on macOS, and whether that path engages VPIO. Chromium's `kChromeWideEchoCancellation` ("mix and cancel all audio playback going to a specific output device in the audio service", [media_switches.cc](https://chromium.googlesource.com/chromium/src/media/+/master/base/media_switches.cc)) is a WebRTC software canceller inside Chrome's audio service. If `"all"` stays in software, Granola's mic path never touches VPIO, which would be consistent with no public reports of Granola breaking call audio. I found no such reports, but absence of reports is weak evidence.
- MacParakeet's April 2026 plan asserted that "Granola / Fathom / Otter / Tactiq use Apple's Voice Processing I/O (VPIO)". It gave **no source**, and the teardown contradicts it for Granola. Treat that claim as unsupported.

### Recall.ai Desktop Recording SDK

- Mic selection: "For detected meetings, the SDK attempts to identify the microphone used by the meeting application. If it cannot determine an input device, it uses the system's default microphone. On macOS, you cannot currently override the microphone through the SDK" ([FAQ](https://docs.recall.ai/docs/desktop-recording-sdk-faq)).
- Echo: "Echo cancellation is not a problem when the user wears headphones. However, since you can't assume users will always wear headphones, your application needs logic to detect the output device type and accordingly enable or disable AEC" ([How to get access to system audio on macOS, 2026-05-13](https://www.recall.ai/blog/how-to-get-access-to-system-audio)).
- Approach ([Acoustic echo cancellation in desktop meeting recording, 2026-10-14](https://www.recall.ai/blog/acoustic-echo-cancellation)). Its appendix lists the SDK's AEC as "WebRTC-based AEC". On Apple's options it says: "Apple's native AEC options, such as VoiceProcessingIO and AVAudioEngine's voice processing, are integrated into the live audio input and output pipeline. They aren't post-processors that developers can simply pass microphone and meeting audio streams into." And: "The main challenge with using WebRTC isn't implementing AEC itself, but ensuring the audio streams are properly synchronized … Without proper audio synchronization, acoustic echo cancellation will not work."

### RecordKit (Nonstrict)

[`EchoCancellation` type](https://nonstrict.eu/recordkit/api/electron/types/EchoCancellation.html): "Captures system/playback audio via Core Audio process taps and removes it from the microphone signal in real time using WebRTC AEC3." The default is `'off'`. `'aggressive'` runs at 16 kHz with a residual echo gate and is "Optimized for speech-to-text pipelines"; its suppression mode "removes ~2 dB more echo but attenuates speech by 3-5 dB". `'balanced'` runs at 48 kHz and allows "AEC3's transparent mode … protects near-end speech during double-talk". Requires macOS 14.2+.

### Krisp

A different architecture: Krisp sits in the call path rather than observing it. "Krisp Microphone and Krisp Speaker are virtual devices … Krisp receives the audio from your physical microphone, processes it through Krisp Microphone, and then transmits it to the communication app" ([How Krisp Microphone and Krisp Speaker work](https://help.krisp.ai/hc/en-us/articles/4402174576402-How-Krisp-Microphone-and-Krisp-Speaker-work)). For AEC, "To make it work, have both the Krisp Microphone and Krisp Speaker selected in your conferencing app" ([Echo Cancellation with Krisp](https://help.krisp.ai/hc/en-us/articles/4424862471324-Echo-Cancellation-with-Krisp)), because it needs the playback reference. It recommends turning off OS and app AGC, NS and EC: "Krisp is designed to be the only processor on your microphone signal" ([Headset and audio recommendations](https://help.krisp.ai/hc/en-us/articles/27985368822556-Headset-and-audio-recommendations-for-Krisp)). The AI Note Taker likewise advises "select both Krisp Microphone and Krisp Speaker in your communication app to make sure the full meeting is captured" ([Record your meetings](https://help.krisp.ai/hc/en-us/articles/30146816045980-Record-your-meetings-with-Krisp-AI-Note-Taker)). *For Biscotti:* this is the "own the playback" route that makes real-time AEC causal. It costs a driver install and makes users reconfigure the call app.

### MacWhisper

From the release-notes page at [macwhisper-site.vercel.app/release_notes.html](https://macwhisper-site.vercel.app/release_notes.html). It reads like the official notes but I could not confirm it is official; it matches press coverage from [ifun.de, 2026-03-13 (v13.16)](https://www.ifun.de/fuer-diktate-und-transkripte-macwhisper-jetzt-auf-deutsch-verfuegbar-276171/) and [9to5Mac, 2026-09-23 (v15.2)](https://9to5mac.com/2026/09/23/macwhisper-update-brings-real-time-meeting-transcripts-improved-speaker-recognition-more/).

- Beta: "Beta release of echo cancellation for app audio recordings. If you are transcribing a meeting without wearing headphones you can try the new echo cancellation option from Advanced settings to not get duplicated transcriptions."
- Later: "On macOS 26 and later, system audio for app audio recordings and meetings is now captured through CoreAudio instead of ScreenCaptureKit … Echo cancellation: Now on for everyone, made possible by the move to CoreAudio above." *Inference:* tying AEC to the system-audio API suggests a reference-based software canceller that needed the tighter Core Audio tap timing. VPIO would not need the system track at all.
- "Fixed: Starting or ending a FaceTime or other call during a recording could break the recording's microphone track, leaving a file that couldn't be opened." This matches the built-in mic's format change when a call engages voice processing (cf. Biscotti's 3-channel finding).
- "Fixed: Microphones on multichannel audio interfaces are captured correctly."

### Otter, Notion, Jamie, Superwhisper, Loom, Fathom, Bluedot

- **Otter**: the desktop app needs the "Screen & audio recording" permission ("this setting allows you to wear headphones during a meeting while transcribing meeting audio") ([Otter Desktop App](https://help.otter.ai/hc/en-us/articles/35973988280215-Otter-Desktop-App-Mac-Windows)). Troubleshooting warns that "noise suppression or echo cancellation features … can mistakenly identify audio playing through your speakers as background noise", naming Krisp and the Teams app ([Troubleshoot audio](https://help.otter.ai/hc/en-us/articles/4403627500951-Troubleshoot-audio-recording-problems)). That warning is about its browser and acoustic-pickup mode.
- **Notion**: "The Notion app provides the best experience … because it captures all sides of the conversation using your system audio and mic. The browser … can only pick up audio from your microphone" ([AI Meeting Notes](https://www.notion.com/help/ai-meeting-notes)). Nothing about AEC.
- **Jamie**: "Jamie will use your default microphone automatically"; requires macOS 14.4+ ([docs](https://docs.meetjamie.ai/getting-started/recorder)). "Headphone mode … capture[s] the system audio output together with the microphone" ([changelog](https://www.meetjamie.ai/changelog/speaker-diarization-headphone-support)).
- **Superwhisper**: "Your microphone and the call audio record on separate channels" ([blog, 2026-10-14](https://superwhisper.com/blog/meetings)). "When a Bluetooth headset's microphone is active, audio quality often drops … Try selecting your built-in microphone as the input" ([docs](https://superwhisper.com/docs/common-issues/microphone-and-system-audio)). Its own output-ducking features "pause while a meeting records, so you hear the call at full volume."
- **Loom**: "Why do I have an echo in my recording? This happens if you have internal audio and speaker audio being picked up simultaneously. Use headphones (with a microphone)" ([Capture system audio](https://support.atlassian.com/loom/docs/capture-internal-audio-system-audio/)).
- **Fathom** and **Bluedot**: the help centers describe bot-free desktop capture ([Fathom](https://help.fathom.video/en/articles/449088), [Bluedot](https://help.bluedothq.com/en/articles/12818713-bluedot-desktop-app-faq)) but say nothing about mic processing or echo.

### Audio Hijack / Rogue Amoeba (pro-audio reference point)

- Capture on macOS 14.4+ uses a new backend with a "System Audio Access" permission and no driver install ([ARK capture details](https://www.rogueamoeba.com/support/knowledgebase/?product=Audio+Hijack&showArticle=Misc-ARK-Audio-Capture-Details)).
- Release notes: "a subtle visual indicator alerts you when a (possibly lower quality) built-in device is selected"; a "Speech Denoise" block exists ([release notes](https://rogueamoeba.com/audiohijack/releasenotes.php)).
- Rogue Amoeba's mic-enhancement recipe runs mic → Audio Hijack effects → Loopback virtual device → call app ([KB](https://rogueamoeba.com/support/knowledgebase/?product=Loopback&showArticle=Misc-ApplyingMicEffects)). For best voice quality they recommend a "double-ender" ([KB](https://www.rogueamoeba.com/support/knowledgebase/?showArticle=AudioHijack-DoubleEnderRecording)).
- SoundSource can host Apple's ML `AUSoundIsolation` on any app's audio ([KB](https://rogueamoeba.com/support/knowledgebase/?showArticle=SoundSource-SoundIsolation)). *Belongs to the post-processing subtopic.*

### Community signal

- An HN thread (2026) lists "Microphone bleed. People don't always use headphones, the system mic will pick up the speaker sounds, causing duplicate (approximately) transcriptions" as one of the three main unsolved problems across Mac recorders. One indie developer (Trace) replied that they had shipped "active echo cancellation … on by default" ([HN 48533220](https://news.ycombinator.com/item?id=48533220)).

## Takeaways for Biscotti

1. **No commercial product publicly documents using VPIO for a meeting-recorder mic.** The two SDKs that document their AEC (Recall.ai, RecordKit) both use WebRTC AEC3 with the system track as reference. Granola's native fallback is AUHAL plus AEC3, and its live path is Chromium's own processing.
2. **"Use headphones" is the universal documented workaround** (Loom, Granola, Recall.ai, Krisp, Meeting Transcriber). Several products turn AEC off automatically when the output is headphones.
3. **Levelling is acknowledged** (Granola tells users to max the input volume and has a dormant gain-compensation flag), but no vendor documents a fix for another call app degrading the shared mic.

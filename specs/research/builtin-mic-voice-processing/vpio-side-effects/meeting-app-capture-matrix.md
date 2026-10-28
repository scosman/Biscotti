# How each meeting app captures the mic on macOS, and what that predicts

The question: why do Teams, Slack huddles and Chrome break when Biscotti turns on VPIO, while
other apps seem fine? The answer depends on whether the meeting app is itself a **VPIO client**
(it gets its own processed uplink, so the built-in mic's raw-array switch does not affect it) or
a **plain HAL/AUHAL client** (it reads the device stream, so it receives the quiet raw capsules
once anyone runs VPIO on the built-in mic). Mechanism details are in
[mechanisms.md §2c](./mechanisms.md).

Confidence: **High** means source code or the vendor's own engineers. **Medium** means vendor
docs plus consistent indirect evidence. **Low** means inferred.

## Matrix

| App | Mic capture path on macOS | Own processing | Evidence | Confidence | Mic side when Biscotti runs VPIO on the built-in mic | Playback side |
|---|---|---|---|---|---|---|
| **FaceTime** (and Phone) | **VPIO** | Apple VP | "widely used by many apps, including our own FaceTime and Phone app" ([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10235/)) | High | Unaffected: has its own processed uplink. FaceTime is also an *aggressor*: it puts the built-in mic into raw-array mode for others ([TypeWhisper #755](https://github.com/TypeWhisper/typewhisper-mac/pull/755), [Mozilla c41](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)) | Its call audio is "other audio" to Biscotti's VPIO, so it gets ducked **[Inference]** |
| **Safari / WebKit** (Meet, Teams-web, Zoom-web, Slack-web in Safari) | **VPIO** when echoCancellation is on (default). Since late 2025, non-AEC tracks and extra mics go through a non-VPIO HAL unit | Apple VP | "Chrome does not use the voice processing in macOS. We and Safari do" ([Mozilla c66](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)); WebKit `CoreAudioCaptureUnit` + "On macOS, only one VPIO unit can run at a time" ([WebKit f8af49f](https://github.com/WebKit/WebKit/commit/f8af49f640cc922f066d0e349ff119a5ea6a7eb2)); mic modes work in Safari ([Mozilla Connect](https://connect.mozilla.org/t5/ideas/voice-isolation-on-macos/idi-p/58586)) | High | Unaffected (VPIO track). Aggressor for non-VP apps ([transcripted #500](https://github.com/r3dbars/transcripted/issues/500)) | Ducked **[Inference]** |
| **Firefox** | **VPIO** for getUserMedia with processing (since Fx 122/128). Was forced on for built-in mics (`vpio-forcelist`, Mar 2024). Disabled on macOS 12 because of OS crashes | Apple VP (libwebrtc fallback) | [cubeb mod.rs](https://github.com/mozilla/cubeb-coreaudio-rs/blob/trailblazer/src/backend/mod.rs), [force-list commit](https://github.com/mozilla/cubeb-coreaudio-rs/commit/361d2bbe65b464fee918dd2d4871205c071e3038), [Firefox commit 8f5d908](https://github.com/mozilla-firefox/firefox/commit/8f5d908198964430a215bc48bcd0dbc07a46ae5c) | High (behaviour up to 2026); see note | Unaffected while on VPIO. Aggressor ([bug 1922313](https://bugzilla.mozilla.org/show_bug.cgi?id=1922313)) | Undoes ducking on its own output device with private `AudioDeviceDuck` |
| **Chrome / Edge / Brave / Arc** (Meet, Teams-web, Zoom-web) | **Plain AUHAL** (`kAudioUnitSubType_HALOutput`). VPIO only when the `EnforceSystemEchoCancellation` feature is on, and it is **`FEATURE_DISABLED_BY_DEFAULT`** | Chrome-wide WebRTC AEC3/NS/AGC in the audio service (`ChromeWideEchoCancellation`, on by default). A `SystemLoopbackAsAecReference` feature (on by default where Core Audio taps are supported) can use system loopback as the AEC reference; I did not trace exactly when it applies. WebRTC input-volume adjustment writes the HAL input volume (on by default) | [media_switches.cc](https://github.com/chromium/chromium/blob/main/media/base/media_switches.cc), [audio_low_latency_input.cc](https://github.com/chromium/chromium/blob/main/media/audio/apple/audio_low_latency_input.cc), [audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc), [webrtc_features.cc](https://github.com/chromium/chromium/blob/main/media/webrtc/webrtc_features.cc) | High | **Victim**: gets the quiet 3+ channel raw array, opened as stereo when >2 ch, then its own processing on top. Matches the "hollow/tinny" report on macOS 27.0.1 ([#66 timbowicz](https://github.com/scosman/Biscotti/issues/66)) and the Audient report | Ducked. Also rebuilds all output streams when Biscotti changes the default output's nominal rate |
| **Electron apps** (Slack desktop + huddles, Discord, classic Teams, Codex…) | Same Chromium audio stack as Chrome, so **plain AUHAL** **[Inference]** | WebRTC in Chromium. Slack huddles run on the Amazon Chime SDK; the client identifies as `amazon-chime-sdk-js` ([AWS blog](https://aws.amazon.com/jp/blogs/news/customers-like-slack-choose-the-amazon-chime-sdk-for-real-time-communications), [MemberJunction note](https://docs.memberjunction.org/packages/ai/realtimebridge/providers/slack/)) | Electron embeds Chromium; Codex/Electron shows Chromium's WebRTC input-volume feature ([codex #12111](https://github.com/openai/codex/issues/12111)) | Medium | **Victim** (same as Chrome) | Ducked |
| **New Microsoft Teams** (Teams 2.x, `com.microsoft.teams2`) | **Not publicly documented.** UI moved from Electron to WebView2. Media runs in Microsoft's native **SlimCore** engine | Its own AI noise suppression, voice isolation (Oct 2024 on macOS), and "Automatically adjust mic sensitivity", which changes mic gain | [Teams architecture](https://techcommunity.microsoft.com/t5/microsoft-teams-blog/microsoft-teams-advantages-of-the-new-architecture/ba-p/3775704), [MC891240](https://mc.merill.net/message/MC891240), [device settings](https://support.microsoft.com/en-us/teams/notifications-settings/manage-your-device-settings-in-microsoft-teams), [VDI SlimCore](https://learn.microsoft.com/en-us/microsoftteams/vdi-2) | Low (on the capture API) | Behaves as a **victim** in #66: the level meter goes flat on the built-in mic and works again with a headset ([#66 MOccam](https://github.com/scosman/Biscotti/issues/66)). This fits a plain-HAL client | Ducked |
| **Zoom** (native) | **Not publicly documented.** Zoom's KB describes "Software-based echo cancellation" as a Zoom setting on macOS. In 2022 "Zoom had [Voice Isolation] on iOS but not the Mac" | Its own AEC/NS ("Noise removal", "Personalized audio isolation", "Original sound") | [Zoom advanced audio KB](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0066398), [Verge 2022](https://www.theverge.com/23123578/apple-voice-isolation-facetime-calls) | Low | Probably a **victim** if it is plain HAL (untested in #66). The Apple forum report of a VPIO app "cut[ting] off the input stream" of a call app alongside Zoom ([forum 751100](https://developer.apple.com/forums/thread/751100)) fits this | Ducked |
| **WhatsApp** (native) | Behaves like a VPIO client | — | Attenuates other clients like Safari and Firefox do ([transcripted #500](https://github.com/r3dbars/transcripted/issues/500)) | Low | Unaffected **[Inference]** | Ducked |

**Firefox note:** the Firefox main-branch `toolkit/library/rust/shared/Cargo.toml` (fetched
2026-10-28) lists `cubeb-coreaudio` **without** `features=["vpio-forcelist"]`. An earlier
revision has it
([ca39d56](https://github.com/mozilla-firefox/firefox/blob/ca39d56d306cc38794621918a5aca844c7518543/toolkit/library/rust/shared/Cargo.toml)),
and a Sep 2026 comment proposed dropping it
([bug 1896938 c60](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)). It may have been
removed very recently. I could not find the bug, so Firefox's current behaviour is unconfirmed.

## Why it is "mostly Teams, Slack and Chrome"

1. Those apps (Chromium/Electron for certain; Teams very likely) capture with a **plain HAL
   stream and do their own WebRTC-style processing**. They depend on the built-in mic's normal,
   Apple-processed single channel.
2. When Biscotti's VPIO turns on, Apple **enables the raw mic streams on the built-in mic**
   ([Apple Feedback reply](https://stackoverflow.com/questions/64966350/voiceprocessingio-audio-unit-adds-an-unexpected-input-stream-to-built-in-output)).
   Plain clients then get 3+ quiet, unbeamformed capsules, about 25–30 dB down
   ([Mozilla rig](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)). Their VAD or level
   meter goes flat, their AGC pushes gain up, and the far end hears a hollow, thin voice.
3. **FaceTime, Safari and Firefox** are VPIO clients. They get their own processed uplink and
   do not suffer on the mic side. They are the *cause* of the same problem in Biscotti's
   non-VPIO path. That reverse case is the original "quiet built-in mic" bug
   ([internal findings](../../audio/mic_capture_level_findings.md)).
4. **External mics, USB mics and AirPods** have no raw-array mode, so the mic-side switch does
   not happen. That is why the headset workaround in #66 works
   ([#66](https://github.com/scosman/Biscotti/issues/66);
   [Mozilla c34/c56](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)). The Audient report
   in #66 is the exception. Its mechanism is unexplained: possibly aggregate or tap-stream
   reconfiguration of a 12-in/16-out duplex device, or the mic-mode interplay.
5. Every app's playback is ducked by Biscotti's VPIO whichever type it is. That is the "audio
   character shifts" part of the report.

## What this suggests for Biscotti (for the plan writers; not decided here)

- **On the built-in mic, the choice is "who is the victim".** Either Biscotti uses VPIO and
  plain-HAL meeting apps lose their mic quality, or Biscotti does not and Biscotti loses its own
  quality whenever a VPIO meeting app is running. No VPIO setting avoids both. Bypass, `.min`
  ducking and mute do not stop the raw-array switch. See [knobs-and-apis.md](./knobs-and-apis.md).
- **A conditional rule is possible [Inference]:** use VPIO only if the built-in mic is *already*
  in raw-array mode, meaning a VPIO meeting app is running. The signal is the device's input
  stream configuration growing past 1 channel before Biscotti touches it. Otherwise use plain
  capture. TypeWhisper ships this heuristic: "enable … voice processing for the built-in
  3-channel default input route that FaceTime exposes … scoped to the built-in default input
  route" ([PR #755](https://github.com/TypeWhisper/typewhisper-mac/pull/755)). Caveats:
  - Detection must happen before Biscotti's own VPIO starts.
  - The meeting app can start after Biscotti.
  - Firefox can hold a VPIO unit for 10 s after a call.
  - Channel counts vary by model (3, 7, 9). That belongs to the built-in-array subtopic.
- **Non-built-in mics:** VPIO's raw-array side effect does not apply. Ducking, aggregate churn
  and the forced output reclock still do. Multichannel interfaces add the channel-0 and VP-tuning
  problems from #66.

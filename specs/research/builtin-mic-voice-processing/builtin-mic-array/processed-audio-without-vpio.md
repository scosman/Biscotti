# Can a non-VPIO client get Apple's processed (beamformed, levelled) built-in-mic audio?

Research date: 2026-10-28. Scope: capture paths that do **not** make Biscotti a
VoiceProcessingIO client. How VPIO disrupts other apps is covered by the VPIO subtopic.
Echo removal after capture is covered by the post-processing subtopic.

Labels: **[source]** cited, **[repo]** measured in this repo, **[inference]** my reasoning.

## Short answer

There is **no documented, programmatic, non-VP API on macOS that returns Apple's
beamformed, AGC'd, echo-cancelled built-in-mic mono.** Four partial routes exist:

1. **Be a plain client while no VP client is active.** You then get the 1-channel
   processed stream with normal levels. During a call this is usually unavailable,
   because the meeting app's VP switches the device to raw-array mode
   ([channel-modes-by-model.md](./channel-modes-by-model.md)).
2. **Per-app Mic Mode → "HAL Voice Isolation" (macOS 14+).** Since Sonoma, the
   user-selected Mic Mode applies to non-VP apps through a HAL-level processing stage.
   This is the most promising lead. Apps can read the mode and open the picker, but
   cannot set it. Whether it yields beamformed, levelled mono from the built-in array in
   raw mode is **untested**.
3. **AVCaptureSession `multichannelAudioMode` / wind-noise removal (macOS 15+).** These
   are documented for macOS and apply only to the built-in mic. No Mac usage was found.
   Untested.
4. **Do it ourselves.** Down-mix the raw array, add make-up gain and AGC, then optionally
   run Apple's `AUSoundIsolation` in-process
   ([downmixing-raw-array.md](./downmixing-raw-array.md) and the post-processing
   subtopic).

Dead ends: AVAudioSession data sources and polar patterns (not on macOS), the `'nzca'`
ambient-noise-reduction property (Intel-era), aggregate devices, ScreenCaptureKit mic
capture (no AEC), and any new macOS 26/27 API (none found).

---

## 1. Plain client with no VP client active → processed 1-ch stream

- The documented normal format is 1 channel
  ([forum 763325](https://developer.apple.com/forums/thread/763325),
  [Apple Community 255090182](https://discussions.apple.com/thread/255090182)), and in
  that mode "levels were fine" **[repo]**.
- That 1 channel is Apple-processed, not a single capsule. **[inference]** The capsules
  are raw, have no preamp and need beamforming
  ([Asahi](https://asahilinux.org/docs/sw/audio-userspace/)), yet the 1-ch stream has
  normal levels. Chromium's 2017 note supports this: "Hardware noise suppression, such as
  that provided by macOS on its built-in microphone … gets in the way of the processing
  performed by communications software"
  ([blink-dev, Intent to Implement disableHwNoiseCanceller, Nov 2017](https://groups.google.com/a/chromium.org/d/msg/blink-dev/NMg2ZFxmsCg/n3jcj0gBBgAJ)).
  That note dates from the Intel era. I found no Apple statement listing exactly what
  processing the plain 1-ch path applies on Apple silicon: beamforming, noise reduction,
  or AGC. Echo cancellation is very unlikely to be included, since the user hears echo
  on the plain-tap path **[repo]**.
- **Limitation:** a meeting recorder records during meetings, and the meeting app is
  usually a VP client (see the VPIO subtopic for which apps are). So most of the time we
  are in raw-array mode. This path only helps in-person meetings, or calls in apps that
  don't use Apple VP.
- **Can a plain client force the 1-ch format back? Unknown.** Audio MIDI Setup exposes a
  Format menu for the built-in mic. Older Apple help text referred to a selectable
  "4-channel built-in microphone format" (quoted in
  [Apple Community 254239272](https://discussions.apple.com/thread/254239272)). That
  suggests the device may list several physical formats. But the device is shared, and
  changing its physical format would break the VP client that needs the raw array
  **[inference]**. Treat this as a probe only, not a strategy (see
  [open-questions-and-probes.md](./open-questions-and-probes.md)).

## 2. Per-app Mic Mode and "HAL Voice Isolation" (macOS 14+)

### What changed between macOS 12 and macOS 14

- **macOS 12 (WWDC21):** Mic Modes were VP-only. "In order to use Mic Modes, your app must
  adopt the Core Audio AUVoiceIO audio unit." "User selection is sticky per app. Users are
  always in control; your app can't set the Mic Mode directly." The modes were *standard*
  ("standard audio DSP"), *wide spectrum* ("minimizes processing to capture all sounds
  around the device but it still includes echo cancellation") and *voice isolation*
  ([WWDC21 "What's new in camera capture"](https://developer.apple.com/videos/play/wwdc2021/10047/)).
- **macOS 14 Sonoma and later:** Focusrite says "Starting in macOS Sonoma 14.0, Apple
  introduced 'Voice Isolation' features for audio inputs. When enabled, this can alter the
  audio quality of your input, and your channel mapping." It describes the effect in
  **Logic Pro / GarageBand**, which do not use VPIO: "with 'Voice Isolation' enabled, all
  inputs receiving signal from input 1", "'Voice Isolation' only works for speech", and
  "'Voice Isolation' also only works with the first input of your interface"
  ([Focusrite KB, "macOS Sonoma/Sequoia/Tahoe recording input issues", updated 2026-04-10](https://support.focusrite.com/hc/en-gb/articles/15437020104082)).
  Universal Audio describes it for "LUNA, Logic Pro, Ableton Live or any other audio
  application": it "can involuntarily isolate, gate, silence or garble … This setting can
  be changed on a per application basis"
  ([UA KB, Sep 2025](https://help.uaudio.com/hc/en-us/articles/26704705384980)).
- **Log evidence of a HAL-level mechanism:**
  - A plain HAL client (the AudioRouterNow helper, June 2026) logs
    `AVAUVoiceIOChatFlavor … key AUVoiceIOClients/com-audiorouter-now/AUVoiceIOChatFlavor`
    and then `CoreAudio HALSystem.cpp:133 Enabling HAL Voice Isolation support`
    ([MacRumors forum post with log](https://forums.macrumors.com/threads/audiorouternow-free-open-source-audio-router-for-macos-no-kext-menu-bar.2484444/)).
  - Biscotti's own VPIO process logs
    `HALSystem.cpp:139 Disabling HAL Voice Isolation support due to app's use of existing chat flavors`
    ([issue #66 comment](https://github.com/scosman/Biscotti/issues/66#issuecomment-5583791101)).
  - **[inference]** Every CoreAudio client process has a per-bundle-ID "chat flavor"
    (Mic Mode) preference, and the HAL runs a Voice Isolation stage for non-VP processes.
    The stage is switched off when the process uses VPIO, which brings its own chat
    flavors.
- **Aggregate devices under Voice Isolation:** with Voice Isolation selected, an
  aggregate device (4-in hardware + 8-in virtual) reported only 4 input channels, "the
  input channel count of the first device in the kAudioAggregateDeviceSubDeviceListKey"
  ([Apple forum 787240, Jun 2025, unanswered](https://developer.apple.com/forums/thread/787240)).

### Public API (read, prompt, but not set)

| API | Platforms | What it does |
|---|---|---|
| `AVCaptureDevice.preferredMicrophoneMode` (class, get, KVO) | macOS 12+ | "The microphone mode that the user selects in Control Center." |
| `AVCaptureDevice.activeMicrophoneMode` (class, get, KVO) | macOS 12+ | "The value may differ from the value of the preferredMicrophoneMode property if the app's active audio route doesn't support the mode." |
| `AVCaptureDevice.showSystemUserInterface(.microphoneModes)` | macOS 12+ | Opens the system Mic Mode picker |
| `AVCaptureDevice.MicrophoneMode` `.standard` / `.wideSpectrum` / `.voiceIsolation` | macOS 12+ | "standard voice DSP" / "minimizes microphone audio processing" / "isolate the voice and attenuate other signals" |

Sources: Apple docs for
[preferredMicrophoneMode](https://developer.apple.com/documentation/avfoundation/avcapturedevice/preferredmicrophonemode),
[activeMicrophoneMode](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemicrophonemode),
[MicrophoneMode](https://developer.apple.com/documentation/avfoundation/avcapturedevice/microphonemode),
[SystemUserInterface.microphoneModes](https://developer.apple.com/documentation/avfoundation/avcapturedevice/systemuserinterface/microphonemodes).

There is no setter. The `AUVoiceIOClients/<bundle>/AUVoiceIOChatFlavor` preference key
seen in the logs is private; writing it would be unsupported and fragile. One open-source
developer reached the same conclusion: "An app can't set the system Mic Mode. Only the user
can, in Control Center" (backant-io/shepetal research notes, quoted in a search snippet; the
repository pages returned 404 when fetched, so this is unverified).

### What this could give Biscotti, and what is unknown

- **Promise [inference]:** a non-VP Biscotti whose Mic Mode is set to Voice Isolation
  might receive Apple's ML voice-isolated mono from the built-in mic. That would mean less
  room noise and less speaker bleed, without Biscotti becoming a VP client. The repo
  already observed that Voice Isolation "noticeably isolates the voice from background /
  system-audio bleed" on the VPIO path
  ([mic_capture_level_findings.md](../../audio/mic_capture_level_findings.md)).
- **Unknowns (need hardware probes):**
  1. In raw-array mode, does HAL Voice Isolation beamform the 3 capsules, or does it
     isolate only capsule 1 ("first input", by analogy to the interface reports)?
  2. Does it apply gain or AGC, or are levels still ≈ −48 dBFS?
  3. Does selecting it for Biscotti disturb the meeting app? The issue-#66 reporter found
     that giving each app a *different* Mic Mode "restores the other app's mic". That
     behaviour belongs to the VPIO subtopic.
  4. Is the Mic Mode menu even offered for a process that only runs a plain tap? Apple's
     help page says "options vary by app"
     ([Apple: Use Mic Modes on your Mac](https://support.apple.com/guide/mac-help/mchle82b42f0/mac)).
- **Risks:** "only works for speech" and "glitchy" on non-speech, which is fine for
  meetings. On multi-input interfaces it **forces input 1**, which breaks users whose mic
  is on input 2 (Focusrite's own Scarlett Solo 4th Gen has the mic on input 2). So
  Voice Isolation is only a candidate for the built-in mic, and Biscotti should read
  `activeMicrophoneMode` and warn when an interface is in use with Voice Isolation on.

## 3. AVCaptureSession: `multichannelAudioMode` and wind-noise removal (macOS 15+)

From Apple's docs:
- `AVCaptureDeviceInput.multichannelAudioMode`: iOS 18 / **macOS 15**. "This property only
  takes effect when the system routes audio through the built-in microphone. The system
  ignores the value when an external microphone is in use. The default value is none,
  which indicates to use single channel audio recording."
  ([docs](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/multichannelaudiomode))
- `AVCaptureMultichannelAudioMode`: `.none`, `.stereo`, `.firstOrderAmbisonics`
  (macOS 15) ([docs](https://developer.apple.com/documentation/avfoundation/avcapturemultichannelaudiomode)).
  `isMultichannelAudioModeSupported(_:)` checks support.
- `isWindNoiseRemovalSupported` / `isWindNoiseRemovalEnabled`: macOS 15
  ([docs](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/iswindnoiseremovalenabled)).
  Microsoft's ZoomIt for Mac uses it on macOS 15
  ([AudioDevices.swift](https://github.com/microsoft/ZoomitForMac/blob/e14bc9b9/Sources/ZoomItMacCore/Capture/AudioDevices.swift)).
- macOS 26: `AVCaptureAudioDataOutput.spatialAudioChannelLayoutTag`. With FOA mode it
  produces 4-channel FOA or 2-channel stereo
  ([docs](https://developer.apple.com/documentation/avfoundation/avcaptureaudiodataoutput/spatialaudiochannellayouttag)).
  WWDC25 introduced `AUAudioMix` (iOS **and macOS 26**), which "performs the separation
  between speech and ambience" from FOA input
  ([WWDC25 session 251](https://developer.apple.com/videos/play/wwdc2025/251/)). It is
  framed as a playback and editing feature for iPhone spatial recordings.

**Evidence on Macs: none.** Every `isMultichannelAudioModeSupported` usage I found on
GitHub is in iOS camera apps. The repo's AVCaptureSession test delivered 3 ch @ 44.1 kHz
during a meeting **[repo]**. That conflicts with "default none = single channel" unless
the default applies only to file outputs, or the property is inert on Macs. If
`.stereo` were supported on a MacBook, it would be an Apple-processed (beamformed)
built-in-mic output from a non-VP client. **Worth a 30-minute probe**
([open-questions-and-probes.md](./open-questions-and-probes.md)).

## 4. ScreenCaptureKit microphone capture (macOS 15+)

`SCStreamConfiguration.captureMicrophone` and `microphoneCaptureDeviceID` (macOS 15)
([WWDC24 10088](https://developer.apple.com/videos/play/wwdc2024/10088/)). A Stack Overflow
answer updated after testing says "ScreenCaptureKit on macOS 10.15/Sequoia does NOT echo
cancel the microphone stream"
([SO 78235302](https://stackoverflow.com/questions/78235302/synchronizing-screencapturekit-with-microphone-audio);
"10.15" is evidently a typo for 15). A third-party note calls the `.microphone` output
"unreliable for dual-track" (duration mismatches)
([tenequm skills](https://github.com/tenequm/skills/blob/main/skills/swift-macos/references/screen-capture-audio.md)).
**[inference]** It is another plain HAL client of the same device, with nothing to suggest
it gets a different (processed) stream. Not worth pursuing.

## 5. Dead ends

- **AVAudioSession data sources / polar patterns / input orientation.** This is the iOS
  way to choose a front/back beam, or stereo/cardioid. `AVAudioSession` and
  `AVAudioSessionDataSourceDescription` are listed for iOS, iPadOS, Mac Catalyst, tvOS,
  visionOS and watchOS, **not macOS**
  ([AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession),
  [AVAudioSessionDataSourceDescription](https://developer.apple.com/documentation/avfaudio/avaudiosessiondatasourcedescription)).
  Core Audio's `kAudioDevicePropertyDataSource` on the built-in device only distinguishes
  `'imic'` (internal mic) from `'emic'` (3.5 mm jack mic)
  ([TypeWhisper #1163](https://github.com/TypeWhisper/typewhisper-mac/issues/1163)).
  It is not a beam selector.
- **`'nzca'` ambient noise reduction.** Chromium still toggles this undocumented device
  property ([audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc)).
  Apple's help says the "Use ambient noise reduction" option does not appear "on Mac with
  Apple silicon or on Mac models with an Apple T2 chip" (quoted in
  [Apple Community 254239272](https://discussions.apple.com/thread/254239272)).
- **Aggregate devices.** A user or private aggregate concatenates the raw sub-device
  streams. VPIO's own aggregate is internal to `AUVPAggregate`. **[inference]** Putting
  the built-in mic in an aggregate does not route it through Apple's processing, and with
  Voice Isolation on, aggregates get truncated to their first sub-device (§2).
- **New APIs in macOS 26/27.** The 27-SDK diffs I checked show Core Audio adding only
  `kAudioDevicePropertySuggestedReferenceDevice` (macOS 27, undocumented). Its name
  suggests pairing an input with its echo-reference output, which is relevant to the
  post-processing subtopic, not here. AVFAudio adds sendable taps and scoped `AudioUnit`
  access. AVFoundation adds no capture-audio APIs
  ([miniswift CoreAudio 27 diff](https://miniswift.run/whats-new/coreaudio/),
  [AVFAudio 27 diff](https://miniswift.run/whats-new/avfaudio/),
  [Apple doc stub](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertysuggestedreferencedevice)).
  These diffs are third-party summaries; I did not diff the SDK headers myself. iOS 26
  extended Voice Isolation to "audio or video recording app[s] such as Voice Memos, or …
  certain third-party apps" ([Apple support 101993](https://support.apple.com/en-us/101993)),
  but that page is iPhone/iPad only.
- **`AVInputPickerInteraction`** (WWDC25 input picker with mic-mode view) is iOS, iPadOS
  and Mac Catalyst 26 only
  ([docs](https://developer.apple.com/documentation/avkit/avinputpickerinteraction)).

## 6. Related, not processing: HAL voice-activity detection (macOS 14)

`kAudioDevicePropertyVoiceActivityDetectionEnable` / `…State` let a plain HAL client get a
voice-activity boolean "from echo-cancelled microphone input"
([WWDC23 "What's new in voice processing"](https://developer.apple.com/videos/play/wwdc2023/10235/)).
It returns a state, not audio, but it could be a cheap "user is talking" signal for a
level meter, auto-channel detection, or a "mic seems dead" warning.

## 7. In-process Apple processing (pointer only)

`AUSoundIsolation` is described as "the model behind FaceTime's Voice Isolation". One
project measured "56 ms of added latency", and noted that it "causes `AudioUnitRender`
to allocate on the IO thread"
([YuhuanStudio/YunAudio](https://github.com/YuhuanStudio/YunAudio)). Running it on our own
down-mixed array signal is the self-contained way to get "Voice Isolation" quality without
touching device state. Evaluated in the post-processing subtopic.

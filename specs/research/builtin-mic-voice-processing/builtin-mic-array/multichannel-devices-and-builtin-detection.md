# Multichannel input devices and reliable built-in-mic detection

Research date: 2026-10-28. Covers four things:

- audio interfaces where the mic is not on channel 1;
- letting the user pick a device and channel;
- auto-detecting the live channel;
- detecting the MacBook built-in mic robustly, so a "built-in → strategy X" rule doesn't
  misfire.

Labels: **[source]** cited, **[repo]** this repo, **[inference]** my reasoning.

---

## 1. The failure we already have

From issue #66 ([comment, 2026-09-08](https://github.com/scosman/Biscotti/issues/66#issuecomment-5583791101)),
reported on an Audient iD24 (USB, 12 in / 16 out) on macOS 15:

- The mic is on **input 2**; input 1 is an unconnected XLR. Measured:
  `ch 1: peak= -120.0 dB` (digital silence), `ch 2: peak= -43.7 dB`, `ch 3..12: -120.0 dB`.
- With VPIO on, AUVP passed the device channels straight through
  (`mic channel count: 12, ref channel count: 16`, `VP <= [28 ch …]`). Biscotti's
  `extractChannel0()` then recorded input 1, giving an all-zero `mic.aac`
  (`mean_volume -91.0 dB`).
- Nothing in the UI warned. Per the reporter, `RMSMonitor` exists but is unwired
  (`micLevel: 0`).

Real products ship with the mic on input 2. Focusrite's own Scarlett Solo 4th Gen has its
mic input on Input 2, and Focusrite tells users to "enable Combine Input 1 + 2" for apps
that only use the first input
([Focusrite KB](https://support.focusrite.com/hc/en-gb/articles/15437020104082)).

## 2. Counting channels correctly

- **HAL:** sum `mNumberChannels` across the `AudioBufferList` returned by
  `kAudioDevicePropertyStreamConfiguration` (input scope). Chromium does exactly this in
  `GetDeviceTotalChannelCount`
  ([audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc)).
  The repo's `CoreAudioHelpers.channelCount` already reads this property.
- **AUHAL / AVAudioEngine:** the input element's stream format `mChannelsPerFrame`, or
  `inputNode.inputFormat(forBus: 0)`. Don't use `kAudioUnitProperty_ElementCount`: an
  Apple engineer explains that devices "have a global scope element (index 0) and one
  element for each channel", so a mono mic shows 2 elements
  ([forum 763325](https://developer.apple.com/forums/thread/763325)).
- **Channel names for UI:** `kAudioObjectPropertyElementName` (input scope,
  element = channel 1…N). Interfaces usually name channels ("Mic/Inst 2"). The built-in
  mic returns `'WHAT'` errors for these properties even though `AudioObjectHasProperty`
  is true ([forum 748749](https://developer.apple.com/forums/thread/748749)), so fall back
  to "Channel N".
- **Re-read on every configuration change.** Channel count and rate can change under you:
  the built-in mic goes 1 ↔ 3 channels (see
  [channel-modes-by-model.md](./channel-modes-by-model.md)), and AirPods go 48 ↔ 24 kHz
  when the mic engages ([macparakeet #481](https://github.com/moona3k/macparakeet/issues/481)).

## 3. Selecting a device and channel

### Device selection (AVAudioEngine)

- **Don't change the system default input to choose a device.** That "affected all other
  apps on your Mac". Ghost Pepper's fix sets the device "directly on the audio unit via
  `kAudioOutputUnitProperty_CurrentDevice`"
  ([ghost-pepper #60, Apr 2026](https://github.com/matthartman/ghost-pepper/issues/60)).
  [TN2091](https://developer.apple.com/library/archive/technotes/tn2091/_index.html)
  describes the same property: "devices can only be set to the AUHAL after enabling IO".
- **Gotcha:** `inputNode.auAudioUnit.setDeviceID(...)` left the input node's output bus at
  "0 ch, 0 Hz". The poster also found `inputNode.auAudioUnit == outputNode.auAudioUnit`,
  so the input and output nodes share one unit
  ([forum 683348, unanswered](https://developer.apple.com/forums/thread/683348)).
  **[inference]** Set the device on `inputNode.audioUnit` before reading formats or
  connecting nodes. Re-query formats afterwards.
- **Identify devices by UID, never by `AudioDeviceID`.** IDs are recreated on route
  changes (phase 9: "no object with given ID 199/216"). `AVCaptureDevice.uniqueID` for an
  audio device is the Core Audio UID: projects pass `"BuiltInMicrophoneDevice"` directly
  as an AVCaptureDevice ID ([wulkano/Aperture example](https://github.com/wulkano/Aperture/blob/7591bb540c844fe6c47edeac34b17c25e92a717f/Example/Sources/Example/main.swift)).
  So one stored UID works for HAL, AVAudioEngine, AVCaptureSession and ScreenCaptureKit
  (`microphoneCaptureDeviceID`).
- **Discovery with AVFoundation (macOS 14+):**
  `AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)`.
  `.builtInMicrophone` is deprecated as of macOS 14
  ([docs](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtinmicrophone)).
  ZoomIt for Mac uses exactly this pair
  ([AudioDevices.swift](https://github.com/microsoft/ZoomitForMac/blob/e14bc9b9/Sources/ZoomItMacCore/Capture/AudioDevices.swift)).

### Channel selection

Three ways, from simplest to most "proper":

1. **Tap all channels and select in software (recommended) [inference].** We already
   down-mix and extract manually at the source rate. Copying one or two of 12–28 float
   channels is trivially cheap. A software selection can change at any time without
   reconfiguring the engine, which matters for auto-detection, and it never interacts
   with AUHAL channel-map quirks.
2. **AUHAL channel map on the AVAudioEngine input node.** Two documented conventions
   exist:
   - [TN2091](https://developer.apple.com/library/archive/technotes/tn2091/_index.html):
     an `SInt32` array sized to the *client* channel count, where each entry is the
     *device* channel to pull, or −1 for "no source". Example `[2,3]`, set with
     `kAudioUnitScope_Output`, element 1.
   - Apple's newer multidevice guide: `AudioUnitSetProperty(inputAudioUnit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 1, …)`,
     with the note "The format's channel count should match your channel map size"
     ([Routing audio to specific devices in multidevice sessions](https://developer.apple.com/documentation/avfaudio/routing-audio-to-specific-devices-in-multidevice-sessions)).

   A developer reports that `engine.inputNode.auAudioUnit.channelMap = …` did **not**
   work for input, while `AudioUnitSetProperty(… kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 1 …)`
   did ([SO 79429470, Feb 2025](https://stackoverflow.com/questions/79429470/regarding-the-auaudiounit-channelmap-issue-on-macos-with-avaudioengine)).
   Another found that `channelMap` "only works on `AVAudioEngine.outputNode` and
   `AVAudioPlayerNode`" ([moredocs, 2024](https://moredocs.github.io/posts/channel-mapping/)).
   Because of these conflicting reports, prefer option 1.
3. **AVCaptureSession:** each `AVCaptureConnection` exposes one `AVCaptureAudioChannel`
   per channel, with `isEnabled` and `volume` (macOS) and `averagePowerLevel` /
   `peakHoldLevel` for metering
   ([docs](https://developer.apple.com/documentation/avfoundation/avcaptureaudiochannel)).
   That gives free per-channel meters for a picker UI.

### How other apps expose it (prior art)

- **Zoom:** "If the selected microphone has 3 or more detected channels, the Use specific
  audio input channels option will be automatically enabled", with a checkbox list of
  channels ([Zoom KB0057961](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0057961)).
  Without it, "Zoom will transmit audio from all the inputs of a connected audio
  interface" ([Focusrite: Zoom for Mac](https://support.focusrite.com/hc/en-gb/articles/360013026019-Setting-up-your-interface-in-Zoom-for-Mac)).
- **Audio Hijack:** the Input Device block captures "in either mono or stereo", using "the
  channel selectors in the Input Device block's Advanced section". Audio Hijack 4 also
  "visually distinguishes built-in mics and requires you to select a device"
  ([Rogue Amoeba: channel handling](https://rogueamoeba.com/support/knowledgebase/?product=Audio+Hijack&showArticle=Misc-Audio-Channel-Handling),
  [AH4 release notes](https://weblog.rogueamoeba.com/2022/03/31/audio-hijack-4-has-arrived/)).
- **Chrome:** for inputs with > 2 channels it falls back to a stereo client format
  ([audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc)).
  **[inference]** In practice that means the first two channels.

## 4. Auto-detecting the live channel [inference: design proposal]

No standard API does this. Here is a design grounded in the issue-#66 measurements.

- **Per-channel stats** over a sliding window (e.g. 3 s, hop 0.5 s): peak, RMS, and RMS in
  the speech band (~100 Hz–4 kHz).
- **Classes:**
  - *dead*: exact digital silence, or < −100 dBFS. Unconnected inputs on the iD24 read
    −120 dB.
  - *idle*: analog noise floor only, steady and low.
  - *active*: speech-band energy clearly above that channel's own noise floor, e.g.
    ≥ 10 dB over its 10th-percentile RMS.
- **Choice:**
  - Select the active channel with the highest speech-band SNR. Make it **sticky**, with
    hysteresis: switch only after another channel wins for N consecutive windows, and
    cross-fade the switch.
  - Persist the choice per device UID.
  - A user's explicit pick always overrides auto-detection.
- **Stereo or duplicate pairs:** if two active channels are highly correlated (a stereo
  mic, or the same mic on a "combined" pair), pick one or average after a polarity check
  (same machinery as [downmixing-raw-array.md](./downmixing-raw-array.md)).
- **Startup:** until the first speech is detected, record all channels' meters and choose
  the provisional channel by lowest "deadness" (non-zero, highest RMS). The final choice
  can be applied retroactively only if we keep a short pre-roll. Otherwise just accept
  that the first seconds may come from the provisional channel.
- **Warnings:**
  - The selected channel is dead for > 10–20 s while recording.
  - The mic track is all-zero at stop. This is the exact iD24 failure.
  - Voice Isolation is active (`AVCaptureDevice.activeMicrophoneMode == .voiceIsolation`)
    on a multi-input interface. That forces "all inputs receiving signal from input 1"
    ([Focusrite](https://support.focusrite.com/hc/en-gb/articles/15437020104082)) and
    truncates aggregates to the first sub-device
    ([forum 787240](https://developer.apple.com/forums/thread/787240)).
- **Cheap speech cue:** macOS 14+ `kAudioDevicePropertyVoiceActivityDetectionEnable` /
  `…State` gives device-level voice activity "from echo-cancelled microphone input"
  ([WWDC23 10235](https://developer.apple.com/videos/play/wwdc2023/10235/)). It is
  device-level, not per channel, so use it only to gate *when* to score channels.

## 5. Detecting the built-in mic reliably

### The rule

```text
isMacBuiltInMic(device) :=
    transportType(device) == kAudioDeviceTransportTypeBuiltIn   // 'bltn'
 && deviceUID(device)     == "BuiltInMicrophoneDevice"
```

Optionally confirm with `kAudioDevicePropertyDataSource` (input scope) containing `'imic'`.

### Evidence

- **Transport alone is not enough [source].** On Apple laptops the 3.5 mm headset mic is
  *also* `bltn`. TypeWhisper's enumeration lists `External Microphone`: UID
  `"BuiltInHeadphoneInputDevice"`, transport `bltn`, data source `'emic'`. It lists
  `MacBook Pro Microphone`: UID `"BuiltInMicrophoneDevice"`, transport `bltn`, data source
  `'imic'` (MacBookPro18,4, macOS 26.5.2). Their transport-only check wrongly classified
  the jack mic; the fix was "identifying the actual internal microphone by UID"
  ([TypeWhisper #1163](https://github.com/TypeWhisper/typewhisper-mac/issues/1163),
  [AudioDeviceService.swift](https://raw.githubusercontent.com/TypeWhisper/typewhisper-mac/main/TypeWhisper/Services/AudioDeviceService.swift)):
  `transportType == kAudioDeviceTransportTypeBuiltIn && deviceUID == "BuiltInMicrophoneDevice"`.
  VoiceInk uses the same UID and excludes `"BuiltInHeadphoneInputDevice"`
  ([VoiceInk AudioDeviceManager.swift](https://github.com/Beingpax/VoiceInk/blob/1027ea3c25e329cd42e7bbe18c746224ad664f7b/VoiceInk/Infrastructure/Audio/Devices/AudioDeviceManager.swift)).
- **The UID is stable across models and locales [source].** Test fixtures show the same
  UID with localised names such as "MacBook Air麦克风" and "Микрофон MacBook Pro"
  ([Voxt tests in sgl-project/sglang-omni](https://github.com/sgl-project/sglang-omni/blob/899c94d528a0e5067b0300198553a1a27bebebad/Voxt/VoxtTests/AudioInputDeviceManagerTests.swift), [OpenSuperWhisper tests](https://github.com/Starmel/OpenSuperWhisper/blob/c8e6fe79d6851078940f459ab7dbc8ee39e2a97d/OpenSuperWhisperTests/OpenSuperWhisperTests.swift)).
  **Never match on the device name.** It is localised, and it is per model ("MacBook Pro
  Microphone", "MacBook Air Microphone", "[Mac model] Microphone",
  [Apple: Change the sound input settings](https://support.apple.com/guide/mac-help/change-the-sound-input-settings-mchlp2567/mac)).
- **Lid closed = mic physically disconnected [source].** "All Apple silicon Mac laptops"
  have a hardware microphone disconnect when the lid closes
  ([Apple Platform Security](https://support.apple.com/guide/security/secbbd20b00b/web)).
  In clamshell mode the built-in device can remain listed but deliver nothing. TypeWhisper
  detects lid state via IOKit and falls back
  ([#1163](https://github.com/TypeWhisper/typewhisper-mac/issues/1163)).

### Devices that look like, or wrap, the built-in mic

| Device | How it looks | Treat as |
|---|---|---|
| 3.5 mm headset / jack mic | `bltn`, UID `BuiltInHeadphoneInputDevice`, data source `'emic'` | External mono mic, not the array |
| Studio Display mic (three-mic array) | **USB** transport. `kAudioDevicePropertyModelUID` like `Studio Display Audio Control:05AC:1114` (Apple VID 05AC); Chromium's approach to parsing VID/PID still works on macOS 26 ([SO 24944614](https://stackoverflow.com/questions/24944614/finding-the-usb-vid-pid-associated-with-a-coreaudio-device-on-osx)) | Probably an Apple array with the same VP behaviour. **Unverified**; probe its channel modes before adding it to the built-in rule |
| iPhone Continuity mic | Transport `kAudioDeviceTransportTypeContinuityCaptureWired/Wireless` ([coreaudio-rs TransportType](https://docs.rs/coreaudio/latest/src/coreaudio/data_types/device.rs.html)) | External |
| AirPods / Bluetooth | `kAudioDeviceTransportTypeBluetooth` / `BluetoothLE`; rate flips 48 ↔ 24 kHz | External; already fine per issue #66 owner comment |
| Aggregates (user, or VPIO's private one) | `kAudioDeviceTransportTypeAggregate` / `AutoAggregate` | Not the built-in rule, even if it contains the built-in mic |
| Virtual mics (Teams `MSLoopbackDriverDevice_UID`, Zoom, Krisp, BlackHole, Hue Sync) | `kAudioDeviceTransportTypeVirtual` | External / unknown |
| MacBook Neo built-in | Presumably `bltn` + `BuiltInMicrophoneDevice`; **2** capsules | Built-in, but the raw-array count may be 2 (unverified) |

### Detecting the *mode*, not just the device

The built-in rule decides strategy. The **current channel count** of
`BuiltInMicrophoneDevice` tells you which processing applies right now [inference]:

- 1 channel: Apple-processed path. Pass through.
- > 1 channel on a plain client: raw array. Down-mix and add gain.
- VPIO client: take channel 0.

Listen for stream-configuration changes on the device, plus the `AVAudioEngineConfigurationChange`
the repo already handles. `kAudioDevicePropertyDeviceIsRunningSomewhere` and per-process
`kAudioProcessPropertyIsRunningInput` (already used in `LiveProcessActivitySource.swift`)
tell you *who else* is capturing, which helps explain a mode flip in logs.

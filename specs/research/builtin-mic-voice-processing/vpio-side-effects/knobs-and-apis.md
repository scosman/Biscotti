# VPIO knobs and related APIs: what each one does about cross-app disruption

For each control, this doc gives the exact declaration, its availability, what it changes,
and whether it affects any of the disruption mechanisms in [mechanisms.md](./mechanisms.md):
the raw-array switch (§2c), ducking (§2d), aggregate/tap streams (§2a/2b) and mic modes (§2e).

Header quotes come from the macOS 15.5 SDK:
[`AudioUnitProperties.h`](https://github.com/alexey-lysiuk/macos-sdk/blob/main/MacOSX15.5.sdk/System/Library/Frameworks/AudioToolbox.framework/Versions/A/Headers/AudioUnitProperties.h),
[`AVAudioIONode.h`](https://github.com/alexey-lysiuk/macos-sdk/blob/main/MacOSX15.5.sdk/System/Library/Frameworks/AVFAudio.framework/Versions/A/Headers/AVAudioIONode.h),
[`AudioHardware.h`](https://github.com/alexey-lysiuk/macos-sdk/blob/main/MacOSX15.5.sdk/System/Library/Frameworks/CoreAudio.framework/Versions/A/Headers/AudioHardware.h).
I could not get a macOS 26 or 27 SDK header mirror, so additions in 26/27 are unverified. The
macOS 26 and 27 release notes contain no VPIO items (see
[version-timeline.md](./version-timeline.md)).

## Summary table

| Knob | Public? | Raw-array switch for other apps (§2c) | Ducking (§2d) | Other notes |
|---|---|---|---|---|
| `voiceProcessingOtherAudioDuckingConfiguration` / `kAUVoiceIOProperty_OtherAudioDuckingConfiguration` (macOS 14+) | Yes | No effect | Reduces it; `.min` is not zero | Biscotti already sets `{advanced:false, .min}` |
| `AudioDeviceDuck(dev, 1.0, nil, ramp)` | **No** (private, weak-linked) | No effect | Undoes ducking on one output device | Chrome and Firefox both call it |
| `isVoiceProcessingBypassed` / `kAUVoiceIOProperty_BypassVoiceProcessing` | Yes | **No effect** (VPIO is still hooked up) | Not documented | Mic modes override bypass; built-in mic is very quiet in bypass on M3; Apple timing bug |
| `isVoiceProcessingAGCEnabled` / `kAUVoiceIOProperty_VoiceProcessingEnableAGC` | Yes | No effect | No effect | Only affects VPIO's own uplink; small difference |
| `isVoiceProcessingInputMuted` / `kAUVoiceIOProperty_MuteOutput` | Yes | No effect while the unit is alive | No effect | Required for muted-talker detection |
| `setMutedSpeechActivityEventListener` / `kAUVoiceIOProperty_MutedSpeechActivityEventListener` (macOS 14+) | Yes | — | — | Not relevant to disruption |
| `kAudioHardwarePropertyProcessInputMute` (HAL) | Yes | No effect | — | Silences input to this process; hides the recording indicator |
| `kAudioDevicePropertyVoiceActivityDetectionEnable/State` (HAL, macOS 14+) | Yes | — | — | VAD on an echo-cancelled input without VPIO |
| `AVCaptureDevice.preferredMicrophoneMode` / `activeMicrophoneMode` (macOS 12+) | Yes, read-only | — | — | No public API to set the mode |
| `AVCaptureDevice.showSystemUserInterface(.microphoneModes)` | Yes | — | — | Opens the system picker for the user |
| Disposing the VPIO unit (not just stopping it) | — | **Only this ends the switch** | Ends ducking | Pooled or idle units keep other apps attenuated |

## Ducking

### `voiceProcessingOtherAudioDuckingConfiguration` (AVAudioEngine) / `kAUVoiceIOProperty_OtherAudioDuckingConfiguration` (AUVoiceIO)

```objc
struct AUVoiceIOOtherAudioDuckingConfiguration {
	Boolean            mEnableAdvancedDucking;
	AUVoiceIOOtherAudioDuckingLevel  mDuckingLevel;
};
typedef CF_ENUM(UInt32, AUVoiceIOOtherAudioDuckingLevel) {
	kAUVoiceIOOtherAudioDuckingLevelDefault = 0,
	kAUVoiceIOOtherAudioDuckingLevelMin = 10,
	kAUVoiceIOOtherAudioDuckingLevelMid = 20,
	kAUVoiceIOOtherAudioDuckingLevelMax = 30
};
kAUVoiceIOProperty_OtherAudioDuckingConfiguration =  2108
  API_AVAILABLE(ios(17.0), macos(14.0)) API_UNAVAILABLE(watchos, tvos);
```

- Header: "Configures the ducking of other (i.e. non-voice) audio, including advanced ducking
  enablement and ducking level… If not set, the default ducking configuration is to disable
  advanced ducking, with a ducking level set to kAUVoiceIOOtherAudioDuckingLevelDefault."
  `mEnableAdvancedDucking` "ducks other audio based on the presence of voice activity from local
  and/or remote chat participants."
- WWDC23: advanced ducking "applies more ducking when user from either side is talking, and it
  reduces ducking when neither side is talking… very similar to the ducking in FaceTime
  SharePlay." Min "minimizes the amount of ducking we apply… the setting to use if you want other
  audio volume to be as loud as possible." Before macOS 14 "we applied a fixed amount of ducking"
  ([WWDC23 10235](https://developer.apple.com/videos/play/wwdc2023/10235/)).
- Before macOS 14 there was no macOS control: the iOS-only `kAUVoiceIOProperty_DuckNonVoiceAudio`
  is `API_UNAVAILABLE(macos)` and deprecated. A 2017 forum thread asking how to disable it on
  macOS got no answer ([forum 93995](https://developer.apple.com/forums/thread/93995)).
- For a recorder: keep advanced ducking **off**. With it on, ducking is driven by local voice
  activity, so the meeting would dip whenever the user speaks. Biscotti already uses
  `.init(enableAdvancedDucking: false, duckingLevel: .min)`.
- **`.min` is not "off".** Transcripted's `.min` build "audibly dimmed Zoom playback" and was
  reverted ([PR #1075](https://github.com/r3dbars/transcripted/pull/1075)). Nobody has published
  a dB figure for `.min`. FineTune estimates the default at about 20 dB
  ([PR #311](https://github.com/ronitsingh10/FineTune/pull/311)).
- **Timing.** On macOS 14, ducking is applied when the VPIO unit is *created* (cubeb comment),
  which is before any configuration can be set on it. AVAudioEngine creates the unit inside
  `setVoiceProcessingEnabled(true)`. **[Inference]** There may be a ducking ramp between unit
  creation and the config being applied. Not measured.

### `AudioDeviceDuck` (private SPI)

```c
OSStatus AudioDeviceDuck(AudioDeviceID inDevice, Float32 inDuckedLevel,
                         const AudioTimeStamp* __nullable inStartTime,
                         Float32 inRampDuration) __attribute__((weak_import));
```

- Not in the public `AudioHardware.h` (checked in the 11.3 and 15.5 SDKs). WebKit declares it in
  `CoreAudioSPI.h` ([opensource.apple.com](https://opensource.apple.com/source/WebCore/WebCore-7605.2.8/PAL/pal/spi/cf/CoreAudioSPI.h.auto.html)).
- VPIO uses it internally: `AUVoiceProcessor::DestroyAggregateDevice → DuckOtherAudio → AudioDeviceDuck`
  ([SO 67260345 stack](https://stackoverflow.com/questions/67260345/mac-audiounit-audiocomponentinstancedispose-crash)).
- **Chrome** calls `AudioDeviceDuck(output_device_id, 1.0, nullptr, 0.5)` ("Ramp the volume back
  up over half a second") right after `AudioUnitInitialize` on its VPIO path
  ([Chromium `media/audio/apple/audio_low_latency_input.cc`](https://github.com/chromium/chromium/blob/main/media/audio/apple/audio_low_latency_input.cc)).
- **Firefox (cubeb)** does the same after creating and after starting the VPIO unit, on the VPIO
  output device or the default output. This is gated by the `no-private-apis` feature
  ([cubeb PR #195](https://github.com/mozilla/cubeb-coreaudio-rs/pull/195);
  [mod.rs](https://github.com/mozilla/cubeb-coreaudio-rs/blob/trailblazer/src/backend/mod.rs)).
  Their reason: "There is a secret (as in not in the official docs) API to disable ducking"
  ([Mozilla bug 1865996](https://bugzilla.mozilla.org/show_bug.cgi?id=1865996)).
- FineTune claims ducking "cannot be disabled via any public API on Apple Silicon with SIP
  enabled" ([PR #311](https://github.com/ronitsingh10/FineTune/pull/311)). This is consistent:
  `AudioDeviceDuck` is private, not public.
- **For Biscotti:** calling `AudioDeviceDuck(defaultOutput, 1.0, nil, 0.5)` once VPIO is running
  is the only known way to fully undo playback ducking. Risks: it is private API (acceptable for
  a Developer-ID app, but could break); it has only been confirmed on macOS 14-era testing; and it
  does nothing for the mic-side problem. **Unverified on macOS 26/27.**

## Bypass: `isVoiceProcessingBypassed` / `kAUVoiceIOProperty_BypassVoiceProcessing`

- Header: "Bypass all processing for microphone uplink done by the voice processing unit. When
  set to 0 (default), the processing is activated otherwise it is disabled. **Voice Isolation
  and Wide Spectrum take priority over Bypass.**" AVAudioIONode: "Querying this property when
  voice processing is disabled will return false." Available on macOS 10.15+.
- Mozilla: "On VPIO there are only two knobs: bypass and agc… For some more recent Macbook Pro
  builtin microphones, bypass-on seems to render a low volume… with bypass-on, agc-on doesn't
  seem to have the expected effect" ([bug 1914046](https://bugzilla.mozilla.org/show_bug.cgi?id=1914046)).
  On an M3: "Bypass: very quiet regardless of AGC setting"
  ([bug 1896938 c22](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)). Measured bypass
  stream: −66.1 dBFS on M3 Pro / macOS 26.6.1, but −27.6 dBFS on an M2
  ([c62–c63](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)). Bypass is
  hardware-dependent and unreliable.
- An Apple bug: "enabling Bypass on a VPIO unit prior to starting effectively makes it stay in
  bypass for at least one start/stop cycle, no matter what the bypass property is set to later
  on" ([bug 1903002](https://bugzilla.mozilla.org/show_bug.cgi?id=1903002)). Pehrson's view:
  "'bypass' has some issues suggesting it is not well tested by Apple"
  ([bug 1404972 c47](https://bugzilla.mozilla.org/show_bug.cgi?id=1404972)).
- **For cross-app disruption:** bypass keeps the VPIO unit, the aggregate and the raw-array mode
  in place. Other clients still lose 25–30 dB (measurement 2 in the
  [rig](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938) *is* VPIO in bypass). Bypass is
  **not** a way to get "VPIO without disruption". On M3+ it also loses the clean signal. On iOS,
  bypass on iPhone 14 hid the mic-mode picker while the mode kept applying
  ([forum 728370](https://developer.apple.com/forums/thread/728370)).

## AGC: `isVoiceProcessingAGCEnabled` / `kAUVoiceIOProperty_VoiceProcessingEnableAGC`

- Header: "Enable automatic gain control on the processed microphone uplink signal. On by
  default." Available on macOS 10.15+.
- Mozilla on M3, not in bypass: "volume is fine, AGC setting seems to make a marginal
  difference" ([bug 1896938 c22](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)).
  Chrome's VPIO path sets it from the getUserMedia constraints (`SetSystemAGC`)
  ([audio_low_latency_input.cc](https://github.com/chromium/chromium/blob/main/media/audio/apple/audio_low_latency_input.cc)).
- No evidence that VPIO's AGC writes the shared HAL input volume
  (`kAudioDevicePropertyVolumeScalar`). The input-volume drops seen system-wide (Biscotti's
  0.67 → 0.27 during Meet) more likely come from **Chrome's WebRTC input-volume adjustment**.
  `kWebRtcAllowInputVolumeAdjustment` is `FEATURE_ENABLED_BY_DEFAULT`, and Chrome's
  `SetInputVolume` writes `kAudioDevicePropertyVolumeScalar` on the device
  ([webrtc_features.cc](https://github.com/chromium/chromium/blob/main/media/webrtc/webrtc_features.cc),
  [audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc)).
  Codex (Electron) users saw the system input level dragged down and fixed it with
  `--disable-features=WebRtcAllowInputVolumeAdjustment`
  ([openai/codex #12111](https://github.com/openai/codex/issues/12111)). **[Inference]** When
  Biscotti's VPIO makes Chrome's input quiet, Chrome's AGC may raise the system input volume,
  which then changes Biscotti's input too.

## Muting

- VPIO: `kAUVoiceIOProperty_MuteOutput` ("Mutes the output of the processed microphone uplink")
  and AVAudioEngine `voiceProcessingInputMuted`. Muted-talker detection
  (`kAUVoiceIOProperty_MutedSpeechActivityEventListener` /
  `setMutedSpeechActivityEventListener`, macOS 14+) requires mute to be done this way
  ([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10235/); header).
- HAL: `kAudioHardwarePropertyProcessInputMute` ('pmin'): "a non-zero value indicates that all
  data coming into the process for all devices will be silent." WWDC23 recommends it for non-VPIO
  apps because it "suppresses the recording indicator light in the menu bar."
- WebKit sets `kAUVoiceIOProperty_MuteOutput` only on VPIO units, and only when no other unit
  is capturing, because muting can stop a sibling unit from capturing
  ([WebKit commit a1aedbe, Nov 2025](https://github.com/philn/WebKit/commit/a1aedbea4cfe885239f6af96b937de0f2c995b2e)).
- **For cross-app disruption:** muting does not release the device mode. Mozilla's
  "pooled unit still alive" measurement shows other clients stay attenuated until the unit is
  **disposed** ([c62](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)). Muting is not a
  way to "pause" the disruption.

## HAL voice-activity detection (no VPIO needed)

- `kAudioDevicePropertyVoiceActivityDetectionEnable` ('vAd+') and
  `kAudioDevicePropertyVoiceActivityDetectionState` ('vAdS'). Header: "Voice activity detection
  can be used with input audio and has echo cancellation. Detection works when a process mute is
  used, but not with hardware mute." WWDC23: "it's detecting voice activity from echo-cancelled
  microphone input". These are HAL APIs for "those of you who are not ready yet to adopt Apple's
  voice processing APIs".
- Only a boolean speech flag, not audio. It shows the HAL has an echo-cancelled analysis path
  that does not need a client VPIO unit. Whether enabling it triggers the raw-array switch is
  **untested**.

## Mic-mode APIs (read and prompt only)

- `AVCaptureDevice.MicrophoneMode` = `.standard`, `.wideSpectrum`, `.voiceIsolation` (macOS
  12+). `preferredMicrophoneMode`: "The microphone mode that the user selects in Control Center."
  `activeMicrophoneMode`: "may differ from the value of the [preferred] property if the app's
  active audio route doesn't support the mode." Both support KVO
  ([Apple docs](https://developer.apple.com/documentation/avfoundation/avcapturedevice/microphonemode)).
- `AVCaptureDevice.showSystemUserInterface(.microphoneModes)` opens the system UI. As of a
  Sep 2026 forum question there is still no public setter for the mode, and it was unanswered
  ([forum 844448](https://developer.apple.com/forums/thread/844448)).
- Modes are per app ("Your selection will only affect the app you're using… Mic Modes persist
  for that app", [Apple iOS support, Nov 2025](https://support.apple.com/en-gb/101993); the macOS
  logs show a per-bundle `AUVoiceIOClients/<bundle>/AUVoiceIOChatFlavor` key, see
  [mechanisms.md §2e](./mechanisms.md)).
- The log key `AUVoiceIOIsAutoChatFlavorEnabled` hints that macOS has the "Automatic" mode
  internally (iOS 18 added Automatic). macOS's public `MicrophoneMode` enum has no `.automatic`.

## Format and channel behaviour (what Biscotti's tap sees)

- Enabling VP changes the input node's format, for example from `1 ch, 44100 Hz` to
  `3 ch, 44100 Hz … deinterleaved`
  ([SO 72953588, 2022](https://stackoverflow.com/questions/72953588/why-enabling-voice-processing-on-avaudioinputnode-changes-channels-count-on-its)).
  Reported counts: 9 ch at 48 kHz (Biscotti AudioLab, Scripta); "3–7 ch, 48kHz"
  ([picrophone #13](https://github.com/zenyui/picrophone/issues/13)); 28 ch on an Audient iD24.
- `kAUVoiceIOErr_UnexpectedNumberOfInputChannels = -66784` (macOS only): "an unexpected number of
  input channels was encountered during initialization of voice processing audio unit" (header).
- The real fix for channel extraction (requesting mono at the VPIO client boundary versus
  extracting channel 0) belongs to the internal-evidence and built-in-array subtopics. The
  digimata/quill RCA argues for requesting mono at the Voice I/O boundary
  ([quill RCA-001](https://github.com/digimata/quill/blob/8ab6ebb6/.issues/rca-001-voice-processing-silent-mic.md)).

## Lifecycle knobs with cross-app effect

- **Dispose promptly.** Other apps recover only when the last VPIO unit is disposed (−67 → −41
  dBFS in Mozilla's rig). Firefox deliberately keeps a VPIO unit for 10 s
  (`VPIO_IDLE_TIMEOUT`) to avoid the >3 s creation cost, and that keeps others attenuated
  ([bug 1896938 c60, c62](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)). Biscotti's
  teardown calls `setVoiceProcessingEnabled(false)` and releases the engine. It should check
  (e.g. in the unified log) that the AUVP aggregate is actually destroyed at stop.
- **Never toggle VPIO per buffer or per segment.** Each create takes seconds and re-ducks.
  WebKit reuses one VPIO unit across reconfigurations for this reason
  ([WebKit commit 7ca4198](https://github.com/WebKit/WebKit/commit/7ca419834e5cf349386849b51920d2b81d9ecb86)).

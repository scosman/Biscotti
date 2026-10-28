# How macOS voice processing (VPIO) works, and how it reaches other apps

Scope: Apple's voice-processing I/O unit (`kAudioUnitSubType_VoiceProcessingIO`, also called
AUVoiceIO / AUVoiceProcessingIO / "AUVP") and `AVAudioInputNode.setVoiceProcessingEnabled(true)`
on macOS 14–27, and the separate ways it changes what *other* processes get from the audio
system. Apple's API knobs are in [knobs-and-apis.md](./knobs-and-apis.md). Per-app capture
paths are in [meeting-app-capture-matrix.md](./meeting-app-capture-matrix.md).

Labels used below: **[Apple]** means Apple documentation, Apple engineers or an Apple
Feedback reply. **[Measured]** means someone measured it and published the numbers.
**[Code]** means it comes from published source code. **[Inference]** means it is my reading
of the evidence and nothing states it directly.

---

## 1. What VPIO is

- One duplex I/O unit that handles both mic capture (the "uplink") and playback (the
  "downlink"). It does "echo cancellation, noise suppression, automatic gain control, among
  others… tuned by acoustic engineers for each Apple product model in conjunction with each
  type of audio device". FaceTime and Phone use it. Two ways to get it: AUVoiceIO directly, or
  AVAudioEngine's voice-processing mode. "Both options provide the same voice processing
  capabilities." **[Apple]** ([WWDC23 10235](https://developer.apple.com/videos/play/wwdc2023/10235/))
- AVAudioEngine: "Voice processing requires both input and output nodes to be in the voice
  processing mode. Enabling this mode on either of the IO nodes automatically enables it on the
  other IO node… Voice processing can only be be enabled or disabled when the engine is in a
  stopped state." **[Apple]** (`AVAudioIONode.h`, macOS 15.5 SDK,
  [mirror](https://github.com/alexey-lysiuk/macos-sdk/blob/main/MacOSX15.5.sdk/System/Library/Frameworks/AVFAudio.framework/Versions/A/Headers/AVAudioIONode.h))
- Using VPIO "grants users full control over the mic mode settings for your app, including
  Standard, Voice Isolation, and Wide Spectrum". **[Apple]** ([WWDC23 10235](https://developer.apple.com/videos/play/wwdc2023/10235/))

## 2. What enabling VPIO does to the system

Each item below is a separate change in shared, system-wide state. Together they explain why
VPIO in one process is visible in others.

### 2a. A private "AUVP aggregate" device is created

- VPIO builds a private aggregate device that pairs the input and output devices. Developers
  have seen it in device lists as `VPAUAggregateAudioDevice-0x…`
  ([SO 64966350, 2020](https://stackoverflow.com/questions/64966350/voiceprocessingio-audio-unit-adds-an-unexpected-input-stream-to-built-in-output)).
  Chromium filters it out by name: "Filter out aggregate devices, e.g. those that get created by
  using kAudioUnitSubType_VoiceProcessingIO" **[Code]**
  ([audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc)).
- The aggregate is fragile. These failures are documented:
  - **Mismatched devices.** AirPods mic with MacBook speakers fails with `AUVPAggregate.cpp:1000 client-side input and output formats do not match (err=-10875)` and `Failed expectation of constructed aggregate` ([Apple forum 772006, Jan 2025](https://developer.apple.com/forums/thread/772006); repost [810129, Dec 2025](https://developer.apple.com/forums/thread/810129)). No answer from Apple beyond a request for a sample project.
  - **Spatial-Audio speakers.** These present as 6-channel 5.1 output. The 6-channel reference
    breaks init with `-10875`, and each failed attempt blocks the audio path for about 2 s
    ([Forasoft, May 2026, M1 Max](https://www.forasoft.com/ship-log/spatial-audio-vpio)).
  - **Sample-rate mismatch.** Biscotti's own AudioLab hit `-10875` when the output was 44.1 kHz and the input 48 kHz, and had to raise the output device's nominal rate to match ([internal: `mic_capture_level_findings.md`](../../audio/mic_capture_level_findings.md)). VPIO fails instead of resampling. That is the reason `ensureOutputRateMatchesInput()` exists.
  - **Multichannel interfaces.** On an Audient iD24 (12 in / 16 out) the log shows `GetDataSourceForDevice(): did not get expected number (=1) source`, `Timeout waiting for streams`, `AUVP configuration time 802 ms`, and a `[28 ch]` VP format ([issue #66 comment, 2026-09-08](https://github.com/scosman/Biscotti/issues/66)).
  - **Slow creation.** `AudioComponentInstanceNew` for VPIO "blocks for up to five seconds (at least two)", with `AUVPAggregate.cpp:2560 AggInpStreamsChanged wait failed` and `KeystrokeSuppressor … AU will be bypassed` ([Apple forum 756760, Jun 2024](https://developer.apple.com/forums/thread/756760); Apple asked for a Feedback report, FB13879429).
- Mozilla measured the lifecycle costs on macOS 14: "Creating the first VoiceProcessingIO unit
  in a process takes a long time, often > 3s"; a second is < 1 s; disposing the last one is
  slow and "will have other side effects: … bluetooth devices will move away from the handsfree
  profile, etc." **[Code]** (comment in
  [cubeb-coreaudio-rs `src/backend/mod.rs`](https://github.com/mozilla/cubeb-coreaudio-rs/blob/trailblazer/src/backend/mod.rs)).
  Adding or removing an aggregate fires `kAudioHardwarePropertyDevices` for every process that
  listens for device changes. **[Inference]**

### 2b. Output devices gain a "tap stream" (the echo reference)

- Biscotti's log in issue #66:
  `AUVPAggregate.cpp:3620 output device 113 supports tap stream and it's not yet enabled. Enable it now`,
  then `AUVP_TapTracker_EnableTap: enabled tap stream on dev-126 … dev-141 … dev-92 … dev-118`
  ([issue #66](https://github.com/scosman/Biscotti/issues/66)). This is **every** device that has
  a tap stream, not only the default output.
- Apple described the visible effect in a Feedback reply, relayed by a developer:
  "The speaker device has input stream - this is the reference tap stream for echo
  cancellation." **[Apple]** ([SO 64966350, answer ~Mar 2021](https://stackoverflow.com/questions/64966350/voiceprocessingio-audio-unit-adds-an-unexpected-input-stream-to-built-in-output))
- Effect on other apps: while VPIO runs, "MacBook Pro Speakers" shows up as an *input* device
  with 6 channels of `TerminalType 0x0000` ([Mozilla bug 1875235](https://bugzilla.mozilla.org/show_bug.cgi?id=1875235)).
  Any app that enumerates or watches device streams sees this change.

### 2c. The built-in mic switches into its raw-array mode for everyone (main input-side cause)

- From the same Apple Feedback reply: "There is additional input stream under the built-in mic
  device - this is the raw mic streams enabled by AUVP… We'd advise you to ignore the extra
  streams on the device." **[Apple]**
  ([SO 64966350](https://stackoverflow.com/questions/64966350/voiceprocessingio-audio-unit-adds-an-unexpected-input-stream-to-built-in-output))
- Mozilla engineer Andreas Pehrson, testing on an M3: "It's the builtin mic and when used with
  vpio in one app, it gets 3 very quiet channels exposed to all apps. One can observe these extra
  channels in Audio MIDI Setup when using vpio (like Firefox or Safari)." He also notes "Safari
  and other built-in macOS apps, like Facetime, behave the same" and that he filed it with Apple
  as **FB13697689** ([Mozilla bug 1896938 c22, c41](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)).
- Mozilla's force-list commit gives the case: "14" M2 Macbook Pro built-in mic exposes three
  channels instead of one … all channels with very low volume compared to a vpio setup, or to a
  raw setup with no vpio present elsewhere" **[Code]**
  ([cubeb commit 361d2bb, Mar 2024](https://github.com/mozilla/cubeb-coreaudio-rs/commit/361d2bbe65b464fee918dd2d4871205c071e3038)).
- **[Measured]** Mozilla's `vpio-levels` rig, run by a user on an M3 Pro with macOS 26.6.1. It
  measures a plain CoreAudio client ("probe") against cubeb VPIO streams
  ([bug 1896938 c62–c63, Sep 2026](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)):

  | Moment | Plain (non-VP) client, RMS dBFS | Note |
  |---|---|---|
  | No VPIO anywhere | −36.5 | baseline |
  | VPIO (bypass) running | −66.1 | "plain client loses 25-30 dB as the device switches to its 3ch raw array" |
  | VPIO bypass + VPIO processed running | −65.4 | processed VPIO stream itself −25.8 (fine) |
  | Streams destroyed, VPIO unit still pooled | −67.1 | **still attenuated while any VPIO unit is alive** |
  | VPIO unit disposed | −40.6 | recovers |

  Pehrson's own M2 run gives the same pattern: probe −42.3 → −68.5 → −66.7 → −70.2 → −40.6.
  A separate rig on an M5 / macOS 26.5.1 measured a "simultaneous native capture fell to roughly
  −52 to −62 dBFS, a 19-29 dB system-wide loss" while Firefox held VPIO
  ([c60](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)).
- The same symptom has been seen independently from the victim's side:
  - Biscotti's AudioLab: 3-channel, 44.1 kHz, peak ~0.004 (≈ −48 dBFS) from the built-in mic
    while FaceTime or a browser meeting ran
    ([internal](../../audio/mic_capture_level_findings.md)).
  - TypeWhisper: "the built-in MacBook microphone reported a 3-channel input route where speech
    was effectively lost by the normal mono path" during FaceTime
    ([TypeWhisper PR #755, Jun 2026](https://github.com/TypeWhisper/typewhisper-mac/pull/755)).
  - Transcripted found that Safari, Firefox and native WhatsApp calls attenuate other clients,
    while Chromium browsers do not ([transcripted #500](https://github.com/r3dbars/transcripted/issues/500)).
  - A Firefox user on Sonoma 14.4.1 measured Chrome's monitored mic level drop from
    "-18db -> -60db" when Firefox opened the mic
    ([Mozilla bug 1922313](https://bugzilla.mozilla.org/show_bug.cgi?id=1922313)).
- **Only the built-in mic.** Users report "It only happens with the macbook internal
  microphone. If I switch to an external microphone there is no issue" and "only arises in the
  MBP's built-in microphone. External USB mics … do not exhibit the issue"
  ([bug 1896938 c34, c56](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)). Apple's
  Feedback reply also names only the built-in mic. **[Inference]** The built-in array normally
  reaches non-VP clients as a single Apple-processed (beamformed and levelled) channel. While
  AUVP is active, the device exposes the raw capsule streams that AUVP needs, so non-VP clients
  get quiet raw capsules instead. External mics have no such alternate mode, so the switch does
  not happen. (Channel counts and modes per Mac model belong to the *built-in mic array*
  subtopic.)
- **Why "hollow / tinny" in Chrome.** Chrome opens >2-channel input devices as stereo (it uses
  `ChannelLayoutConfig::Stereo()` unless the device has ≤ 2 channels)
  ([audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc)),
  then runs its own WebRTC processing and downmix. **[Inference]** Unprocessed, unbeamformed
  capsules, possibly two of them mixed, sound comb-filtered ("hollow"), and they arrive about
  25–30 dB quieter. Teams' level meter going flat in issue #66 fits a 25–30 dB drop.

### 2d. "Other audio" ducking on the output side

- "All the audio streams other than the voice audio stream from your app are considered as
  'other audio'… That's why we duck the volume level of other audio." **[Apple]**
  ([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10235/))
- An Apple engineer said in June 2026: "when voice processing is enabled, it will duck other
  audio that is not part of the voice processing output … if another app is playing audio
  concurrently, its volume will be significantly reduced. This is intentional behavior". The
  same engineer added that VP output "is intentionally band-limited" and its levels "are not
  expected to match" non-VP **[Apple]**
  ([Apple forum 829753, Jun 2026 Audio Q&A](https://developer.apple.com/forums/thread/829753)).
- For a meeting recorder, the meeting app's playback (the remote participants) is "other
  audio" relative to Biscotti's VPIO. **[Inference]** Supporting evidence: FineTune found that
  "coreaudiod's voice-processing mixer treats our aggregate output as 'other audio' and ducks the
  call itself, silencing the remote caller"
  ([FineTune PR #311](https://github.com/ronitsingh10/FineTune/pull/311)).
- Measured or observed scope:
  - Creating a VPIO unit "causes ducking of all output streams across all devices. After setting
    the output device on the VPIO AudioUnit, ducking is undone on all output streams except for
    those on the VPIO output device" (manual testing, macOS 14)
    ([cubeb PR #195, Nov 2023](https://github.com/mozilla/cubeb-coreaudio-rs/pull/195)).
  - "On MacOS 14 the ducking happens on creation of the VPIO AudioUnit. On MacOS 10.15 it
    happens on both creation and initialization" **[Code]**
    ([cubeb mod.rs](https://github.com/mozilla/cubeb-coreaudio-rs/blob/trailblazer/src/backend/mod.rs)).
  - FineTune estimates "roughly 20 dB" at the default level
    ([PR #311](https://github.com/ronitsingh10/FineTune/pull/311); their figure, method not given).
  - Transcripted shipped VPIO with `.min` ducking (v1.1.24), found it "audibly dimmed Zoom
    playback" ("`.min` … is the lowest level, not zero"), and reverted it
    ([transcripted PR #1075](https://github.com/r3dbars/transcripted/pull/1075),
    [#500](https://github.com/r3dbars/transcripted/issues/500)).
- Implementation: a crash stack shows `AUVoiceProcessor::DestroyAggregateDevice → DuckOtherAudio → AudioDeviceDuck → HALDevice::Duck`
  inside `AudioDSP` **[Code/trace]**
  ([SO 67260345](https://stackoverflow.com/questions/67260345/mac-audiounit-audiocomponentinstancedispose-crash)).
  Ducking is therefore a HAL device-level volume ramp applied through the private
  `AudioDeviceDuck` call. That same private call is how Chrome and Firefox *undo* it (see
  [knobs-and-apis.md](./knobs-and-apis.md#audiodeviceduck-private-spi)).
- Ducking explains the issue-#66 report that "the overall audio character shifts" (the remote
  side gets quieter). It does **not** explain Teams' or Chrome's *mic* going quiet or hollow.
  That is §2c.

### 2e. Mic modes ("chat flavors") and "HAL Voice Isolation"

- macOS 12 introduced Mic Modes (Standard / Voice Isolation / Wide Spectrum) for apps that use
  VPIO. "In order to use Mic Modes, your app must adopt the Core Audio AUVoiceIO audio unit"
  (quoting WWDC21 10047,
  [Apple StackExchange](https://apple.stackexchange.com/questions/430463/how-can-i-use-macos-montereys-new-mic-mode-feature-with-zoom)).
  Mic modes need a 2018-or-later Mac **[Apple]**
  ([DTS reply, forum 741658](https://developer.apple.com/forums/thread/741658)).
- From macOS 14 Sonoma, Voice Isolation also applies to apps that do **not** use VPIO:
  - "From MacOS Sonoma 14.0 Apple have added a 'Voice Isolation' feature for audio inputs that
    can be activated on audio applications … it removes frequencies above 10 kHz"
    ([PreSonus KB](https://support.presonus.com/hc/en-us/articles/28066868202637-Audio-Interfaces-macOS-Sonoma-and-Sequoia-audio-quality-and-input-issues)).
  - "This setting can be changed on a per application basis"
    ([Universal Audio KB, updated Sep 2025](https://help.uaudio.com/hc/en-us/articles/26704705384980-The-Audio-From-My-Interface-Is-Garbled-or-Even-Silent-on-macOS-Mic-Mode-Setting)).
  - DAWs such as Logic, Digital Performer and iZotope RX show the menu
    ([MOTUnation](https://www.motunation.com/forum/viewtopic.php?t=73941),
    [JustAskJimVO, Mar 2024](https://justaskjimvo.studio/macos-mic-mode-mishaps/)).
  - Coverage is uneven. Wide Spectrum "doesn't work within the Voice Memos app" and Audacity
    showed no menu ([How-To Geek, Feb 2025](https://www.howtogeek.com/how-to-reduce-mic-echo-and-suppress-background-noise-on-your-mac/)).
    Users report Voice Isolation not taking effect in Chrome or Edge
    ([Apple Community, Feb 2025](https://discussions.apple.com/thread/255961759)).
- Unified-log evidence of the internals:
  - In any process that touches capture, `AVFCapture` logs
    `<<<< AVAUVoiceIOChatFlavor >>>> vpio_preferenceChangedListener … key AUVoiceIOClients/<bundle>/AUVoiceIOChatFlavor`
    and `…/AUVoiceIOIsAutoChatFlavorEnabled`, then
    `(CoreAudio) HALSystem.cpp:133 Enabling HAL Voice Isolation support`
    ([tart #1105 log, Jul 2025](https://github.com/cirruslabs/tart/issues/1105)). The same
    lines appear in an unrelated helper app ([MacRumors, Jun 2026](https://forums.macrumors.com/threads/audiorouternow-free-open-source-audio-router-for-macos-no-kext-menu-bar.2484444/)).
    Eclectic Light's Oct 2023 walkthrough of a macOS VM boot lists "CoreAudio support, including
    HAL Voice Isolation support" ([Eclectic Light](https://eclecticlight.co/2023/10/21/what-happens-when-you-run-a-macos-vm-on-apple-silicon/)).
  - Biscotti, in issue #66: `HALSystem.cpp:139 Disabling HAL Voice Isolation support due to app's use of existing chat flavors`.
- **[Inference]**
  - A "chat flavor" is the internal name for a mic mode.
  - Mic modes are stored per bundle ID under an `AUVoiceIOClients/<bundle>` preference.
  - "HAL Voice Isolation" is the Sonoma-era path that applies the mic mode inside the HAL for
    processes that do not use VPIO.
  - When a process uses VPIO (and so applies chat flavors itself), HAL Voice Isolation is
    disabled for that process, so the audio isn't processed twice.
  - On this reading, mic modes are per process and do not change what *other* processes get.
- A workaround was reported in issue #66: giving Chrome and Biscotti *different* mic modes
  restored Chrome's mic ([alserevs](https://github.com/scosman/Biscotti/issues/66)). One user
  reported it; it is unexplained and unverified. A plausible reading **[Inference]**: Voice
  Isolation for Chrome sends Chrome's input through HAL-level processing that reads the array
  differently from the raw-capsule path. No source confirms this, and it should be tested before
  it is documented as a workaround.
- Bypass does not escape mic modes. The SDK header: "Voice Isolation and Wide Spectrum take
  priority over Bypass." **[Apple]** (`AudioUnitProperties.h`, see
  [knobs-and-apis.md](./knobs-and-apis.md)). An iOS developer saw the same behaviour
  ([forum 728370](https://developer.apple.com/forums/thread/728370)).

### 2f. Forced sample-rate change (Biscotti's own workaround, not VPIO itself)

- Biscotti's `ensureOutputRateMatchesInput()` sets the default output device's
  `kAudioDevicePropertyNominalSampleRate` to the input rate, then restores it on stop
  (`Packages/AudioCapture/Sources/AudioCapture/LiveMicCaptureEngine.swift`). A device's nominal
  rate is shared by every client.
- Chrome watches the default output's nominal sample rate. When it changes,
  `HandleDeviceChanges()` calls `NotifyAllOutputDeviceChangeListeners()`, which rebuilds every
  output stream **[Code]**
  ([audio_manager_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_manager_mac.cc),
  [audio_device_listener_mac.cc](https://github.com/chromium/chromium/blob/main/media/audio/mac/audio_device_listener_mac.cc)).
  So a Chrome or Electron meeting gets a playback glitch at Biscotti start and again at stop.
  **[Inference]** Its echo canceller probably has to re-converge as well.
- On a MacBook, mic and speakers are both normally 48 kHz, so the guard
  (`abs(inRate - outRate) > 1`) usually does nothing. The rate change happens mainly with
  external or Bluetooth outputs. **[Inference]**

## 3. So where does the issue-#66 disruption come from?

| Symptom in #66 | Mechanism | Confidence |
|---|---|---|
| Teams/Chrome **mic** goes flat, quiet or hollow on the **built-in mic** | §2c: AUVP enables the raw mic streams on the built-in mic, and non-VP clients get quiet raw capsules until the VPIO unit is disposed | High: Apple Feedback reply, Mozilla measurements, several independent reproductions |
| "Overall audio character shifts", remote side quieter | §2d: Biscotti's VPIO ducks other audio, including the meeting app's playback; `.min` reduces this but does not remove it | High that ducking happens; medium on how big the residual is at `.min` |
| Glitch/restart at start and stop; AEC re-convergence in Chrome/Electron | §2a (aggregate create/destroy), §2b (tap streams enabled on every output device), §2f (forced output rate change) | Medium: code-level evidence for Chrome; no measured user-facing impact |
| Disruption on a **multichannel USB interface** (Audient iD24, Chrome) | Unclear. Probably §2a/2b reconfiguration plus a mis-tuned VP for a 12-in/16-out device; the raw-array switch is not documented for external devices | Low: one report |
| Mic-mode interplay | §2e: per-app mic modes; the HAL Voice Isolation toggle is per process | Low: inferred from logs |

**Bottom line:** all of these are real, but they act on different things. On the built-in
mic, the *mic* breakage in other apps comes from the shared-device mode switch, not from
ducking or reclocking. Ducking acts on *playback*. The aggregate, tap streams and reclock cause
transient reconfiguration. Biscotti's `.min` ducking setting does nothing for the mic-side
problem.

## 4. Can two VPIO clients coexist?

- **Across processes: yes.** Each VPIO client gets its own processed uplink. Mozilla ran Firefox
  and Safari VPIO at the same time ("I have had Firefox in a bad state and Safari in a good
  state at the same time", [bug 1895787 c6](https://bugzilla.mozilla.org/show_bug.cgi?id=1895787)).
  Pehrson's rig ran two VPIO units side by side (bypass and processed) and both delivered audio
  ([bug 1896938 c62](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938)). Biscotti's own
  AudioLab got loud processed mono while FaceTime or Meet held the mic
  ([internal](../../audio/mic_capture_level_findings.md)).
- **But there are caveats:**
  - An Apple WebKit engineer wrote in Nov 2025: "On macOS, only one VPIO unit can run at a time.
    This means that we can capture with echo cancellation only one microphone at a time." This is
    in the context of WebKit's GPU process
    ([WebKit commit f8af49f, rdar://163945062](https://github.com/WebKit/WebKit/commit/f8af49f640cc922f066d0e349ff119a5ea6a7eb2)).
    I could not determine whether this is per process, per device, or system-wide. It conflicts
    with the cross-process observations above unless it means "one capture device at a time".
  - A May 2024 developer reported "our app seems to cut off the input stream from the other,
    only if it has Voice Processing enabled", when recording alongside Zoom. There was no Apple
    reply ([forum 751100](https://developer.apple.com/forums/thread/751100)).
  - WebKit bug 255986 (FaceTime during a WebRTC call): "We need to verify that two concurrent
    Audio Units doing capture with echo cancellation work together properly". It was still
    reproducible on macOS 27.0.1 in Oct 2026 ([WebKit 255986](https://bugs.webkit.org/show_bug.cgi?id=255986)).
  - VPIO can get stuck in a bad state ("ref mic having 0 channels", echo let through) that only
    a reboot fixes ([bug 1895787 c6](https://bugzilla.mozilla.org/show_bug.cgi?id=1895787)).
    `sudo killall coreaudiod` is a common user fix
    ([bug 1896938 c55, c59](https://bugzilla.mozilla.org/show_bug.cgi?id=1896938);
    [Microsoft Learn: Teams audio issues on macOS](https://learn.microsoft.com/en-us/troubleshoot/microsoftteams/teams-on-mac/teams-audio-issue-mac)).
  - Each VPIO client ducks "other audio", which includes the other VPIO app's voice output
    (per Apple's definition in WWDC23). **[Inference]** Two VPIO apps therefore duck each other.
- **Practical consequence [Inference]:** if the meeting app is already a VPIO client (FaceTime,
  Safari-hosted meetings, Firefox, WhatsApp), the built-in mic is already in raw-array mode.
  Biscotti adding VPIO costs little on the mic side, and VPIO is the only way for Biscotti to get
  good audio in that state. If the meeting app is a plain HAL client (Chrome, Electron, very
  likely Teams native, probably Zoom), Biscotti's VPIO is what breaks it. See
  [meeting-app-capture-matrix.md](./meeting-app-capture-matrix.md).

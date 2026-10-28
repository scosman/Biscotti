# Current production mic path (what `main` does today)

Source: the repo at commit `1c0b182` (main, 2026-10-28; Biscotti `MARKETING_VERSION` 1.1.0 in `App/project.yml`). Line numbers are for that commit. Issue [#66](https://github.com/scosman/Biscotti/issues/66) cites `LiveMicCaptureEngine.swift:218` and `:258-283`; those were older line numbers. The code moved in PRs #94/#101, and the same calls are now at lines 178 and 251–271.

## Summary

- **VPIO is on for every input device, always.** No setting, no check for built-in vs. USB vs. Bluetooth, and no check on channel count. `AudioRecorder.live()` always builds `LiveMicCaptureEngine(encoder:)` (`Packages/AudioCapture/Sources/AudioCapture/AudioRecorder.swift:671-681`). That engine always calls `setVoiceProcessingEnabled(true)`.
- **Each engine build first forces the default *output* device's nominal sample rate to match the default *input* device's rate.** This changes a system-wide device property. It is undone only at stop.
- **Ducking is configured as `enableAdvancedDucking: false, duckingLevel: .min`.** `.min` is the lowest level the API offers, but it still ducks. #129 measured about −4 dB for the whole recording and −15 dB for about 1 s each time a new VP unit is created.
- **A silent `AVAudioSourceNode` is wired straight to `outputNode`** at the input's rate, so the VPIO duplex unit's downlink cycles.
- **Only channel 0 of the post-VP tap is recorded.** The tap callback copies `floatChannelData[0]` into the ring buffer.
- **The input device is always the system default.** No device or channel picker exists, the mic level is not monitored, and no other VP property is set (bypass, AGC, muting).

## Step by step

### Start order (`AudioRecorder.start`)

- Mic first, then system. The comment at `AudioRecorder.swift:193-195` explains why: "VPIO reclocks the output device to the input sample rate. The system tap must query the device after this completes so its ExtAudioFile client format matches the final rate."
- `startMicAndWaitForAnchor` waits up to `micFirstBufferTimeout = 3 s` for the first written mic buffer, and makes `micStartMaxAttempts = 2` attempts (`AudioRecorder.swift:62-64, 233-250`). After that comes system start with 3 attempts 250 ms apart. The comments say these retries exist because "the HAL is mid-reconfiguration (e.g. VPIO just reclocked the output device)" (`:66-79, 206-216`).

### Engine build (`LiveMicCaptureEngine.buildAndStartEngineOrThrow`, `LiveMicCaptureEngine.swift:169-184`)

```swift
ensureOutputRateMatchesInput()

let newEngine = AVAudioEngine()
engine = newEngine // store early so teardownEngine() works on failure
let input = newEngine.inputNode

try input.setVoiceProcessingEnabled(true)
input.voiceProcessingOtherAudioDuckingConfiguration = .init(
    enableAdvancedDucking: false, duckingLevel: .min
)

try installCaptureGraphAndStart(newEngine)
```

### `ensureOutputRateMatchesInput()` (`LiveMicCaptureEngine.swift:251-271`)

- It reads `kAudioDevicePropertyNominalSampleRate` for the default input and the default output. If they differ by more than 1 Hz, it saves `(outID, outRate)` the first time (`if outputRateOverride == nil`) and then calls `CoreAudioHelpers.setNominalSampleRate(inRate, for: outID)`. `CoreAudioHelpers.swift:176` is a plain `AudioObjectSetPropertyData` on the global scope.
- It then polls up to 40 × 25 ms (1 s) until the rate takes effect. **The `OSStatus` is logged but not checked**, so a rejected request still waits the full second. #129 reports that AirPods output refuses 24 kHz with `'nope'` and adds a `guard status == noErr`.
- `restoreOutputRate()` (`:274-278`) puts the saved rate back on `stop()`, on start failure, on unrecoverable recovery failure, and in `deinit`.
- *Inference from the code, not observed:* the override is saved only once per capture. If a route change moves the default output to a second device and that device is also reclocked, the second device's original rate is never saved or restored.
- Why it exists: AudioLab hardware runs 1–3 (see [prior-experiments.md](./prior-experiments.md)). VPIO is a single duplex unit. When the silent output driver ran at 44.1 kHz and the mic at 48 kHz, `engine.start()` failed with `-10875` (`AUVPAggregate.cpp: client-side input and output formats do not match`). With no output driven at all, the downlink faulted and the mic came out choppy.
- User-visible side effect: the shared output device (built-in speakers, USB DAC, AirPods) is re-clocked while another app is mid-call. The experiment notes call out "one brief audio glitch at start + one at stop as the HAL re-clocks" (`experiments/AudioLab/NOTES.md:130-132`). Reporter gphr74 on #91 had a 44.1 kHz USB DAC that Biscotti moved to 48 kHz.
- **It is not required for the reported failure.** thomasvvugt's setup on #115 had input and output both at 48 kHz, so this function did nothing, and the Slack Huddle mic still went dead. See [user-reports.md](./user-reports.md).

### Graph and tap (`installCaptureGraphAndStart`, `LiveMicCaptureEngine.swift:189-214`)

- `tapFormat = input.outputFormat(forBus: 0)` is read *after* VP is enabled. On an M-series MacBook Pro this was 48 kHz / **9 channels** in AudioLab ([prior-experiments.md](./prior-experiments.md)). On an Audient iD24 the VP aggregate was 28 channels: "mic channel count: 12, ref channel count: 16", per alserevs on [#66](https://github.com/scosman/Biscotti/issues/66#issuecomment-5583791101).
- It logs `Mic setup: input=… id rate; output=… id rate; tap rate=… channels=…` at `.notice` with public IDs and rates. This line is the main field diagnostic.
- `attachSilentOutput(to:inputRate:)` (`:282-300`): an `AVAudioSourceNode` that renders zeros with `isSilence = true`, in `AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: hwChannels)`, connected **directly to `engine.outputNode`**. It bypasses `mainMixerNode` because that node's 44.1 kHz software default caused `-10875` in AudioLab run 3.
- `installTap(onBus: 0, bufferSize: 1024, format: tapFormat, block: session.makeTapHandler())`, then `prepare()` and `start()`.

### Channel handling (`MicCaptureSession.handleTap`, `MicCaptureSession.swift:194-236`)

- The real-time callback copies **channel 0 only**: `slotPtr.update(from: srcChannels[0], count: Int(frameCount))` (`:224`). Other channels are dropped. `VPIOBufferHelper.extractChannel0` (`LiveMicCaptureEngine.swift:420-436`) does the same thing, but only the tests use it. The production session copies `[0]` inline.
- The design assumption, from the doc comment at `LiveMicCaptureEngine.swift:417-419`: "With VPIO, channel 0 is the processed/beamformed mono; the rest are raw-array reference feeds."
- Where it breaks: alserevs's Audient iD24 with the mic on **input 2**. VPIO's channel map was `map[0]=0, map[1]=1, map[2..15]=-1`, so channel 0 was the unconnected XLR on input 1. **Every** recording had a digitally silent `mic.aac` (`mean_volume -91.0 dB`) and no warning ([#66 comment](https://github.com/scosman/Biscotti/issues/66#issuecomment-5583791101)).
- A writer thread drains the ring, resamples mono to mono into 24 kHz with a fresh `AVAudioConverter` input buffer per entry, fills gaps, and writes ADTS AAC-LC at 24 kHz, mono, 64 kbps (`EncoderSettings.voice`). Ring slots hold at most 19,200 frames (96 kHz × 200 ms). Larger buffers are dropped (`MicCaptureSession.swift:38-43, 209-212`).

### Ducking

- Set once per engine build, after `setVoiceProcessingEnabled(true)`: `.init(enableAdvancedDucking: false, duckingLevel: .min)`.
- Apple's docs for `voiceProcessingOtherAudioDuckingConfiguration` (macOS 14+) say: "If not set, the default behavior is to disable advanced ducking, with a ducking level set to `default`." The level enum has only `default`, `max`, `mid` and `min`. **No level means "no ducking".** `.min` "Applies minimum ducking to other audio." ([Level](https://developer.apple.com/documentation/avfaudio/avaudiovoiceprocessingotheraudioduckingconfiguration/level), [min](https://developer.apple.com/documentation/avfaudio/avaudiovoiceprocessingotheraudioduckingconfiguration/level/min), [property](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/voiceprocessingotheraudioduckingconfiguration), fetched 2026-10-28.)
- Measured on hardware in [#129](https://github.com/scosman/Biscotti/pull/129) (M1 Max, macOS 26.6.2): "Each new voice-processing unit also ducks other audio to −15 dB (`AudioDeviceDuck … 0.177828` in the log) until its ducking property applies at engine start, 0.6–1.3 s later; a restart keeps the `.min` level (−4 dB, 0.630957)." The PR's "Not covered" section adds: "Voice processing still ducks other audio by 4 dB (`.min`, its lowest level) for the whole recording, and the volume rises again at Stop."
- This matches the output-volume reports on #91 from liamdawson ("seems to revert the output volume to 50%") and gphr74 ("output volume dip while recording and come back up when I stopped").

### Teardown (`teardownEngine`, `LiveMicCaptureEngine.swift:313-348`)

- The order is: invalidate the tap, `removeTap`, `stop()`, `setVoiceProcessingEnabled(false)`, detach the silence node. This follows WWDC19-510, which says VP can only be toggled while the engine is stopped.
- Known hazard ([#124](https://github.com/scosman/Biscotti/issues/124)): when a Bluetooth device drops, `setVoiceProcessingEnabled(false)` races AVFAudio's own property-listener block. This caused a crash (`EXC_BAD_ACCESS` in `AVAudioIOUnit::IOUnitPropertyListener`) in 1 of 3 runs, and a deadlock inside AudioDSP in 2 of 3 AirPods removals on 2026-10-26. #129 works around it.

### Route and config changes on `main`

- `.AVAudioEngineConfigurationChange` (`:382-399`): a change before the first buffer while the engine is still running is ignored ("VPIO startup-settle"). If the engine stopped before the first buffer, the **existing** engine and VP unit are restarted in place (PR #94/#101; `display_audio_startup_failure.md`). After the first buffer, the engine is fully rebuilt: teardown, which disables VP, then a new engine, which runs `ensureOutputRateMatchesInput` again and enables VP again.
- An input-device change from `LiveDeviceChangeProvider` calls `reconnect()`, which always does a full teardown and rebuild (`:126-155`, `AudioRecorder.swift:577-589`). Every rebuild creates a new VP unit and repeats the −15 dB duck transient (#129).

### What is *not* done

- No `isVoiceProcessingBypassed`, `isVoiceProcessingAGCEnabled` or `isVoiceProcessingInputMuted` calls. `grep` over `Packages/` finds none.
- No reading or recording of the active macOS Mic Mode (`AVCaptureDevice.activeMicrophoneMode`), even though `mic_capture_level_findings.md` recommends it.
- No input-device or input-channel selection. Feature request: [#116](https://github.com/scosman/Biscotti/issues/116).
- No mic level or silence detection: `CaptureState.micLevel: 0, // RMS unwired per phase 9` (`AudioRecorder.swift:412`). A 21-minute all-zero mic track finished with no warning (alserevs, #66).
- `CoreAudioHelpers.transportType(for:)` exists in production (`CoreAudioHelpers.swift:314`). Only the system engine uses it (`LiveSystemCaptureEngine.swift:807`). Nothing in the mic path asks whether the input is built-in.

## Downstream consequence of mic level and echo for transcription (for context)

`AudioMerger.mergeTwoStreams` (`Packages/Transcription/Sources/Transcription/AudioMerger.swift:90-114`) sums mic and system sample by sample. If the **global** peak is above 1.0, it scales the **whole** merged array by `1/peak`. One loud bleed peak on the mic track therefore lowers the level of the whole meeting. On #118, javimoya measured echo-bot bleed on a non-VPIO built-in mic track that peaked at "+14 dBFS" and "scales the whole meeting down (~×0.2) and remote speech reaches the transcriber twice" ([comment](https://github.com/scosman/Biscotti/pull/118#issuecomment-6446547910)). This belongs to the post-processing subtopic, and it is the concrete cost of dropping VPIO without adding echo handling.

## Stale spec to be aware of

`specs/projects/stage_a_foundations/components/audio_capture.md:196-202` and `stage_a_foundations/architecture.md:67` still say "Mic capture — plain AVAudioEngine (NOT VPIO)", rejected because "it faults". The production code reversed that decision after `mic_capture_level_findings.md` (2026-06-08). Those spec files are point-in-time records, but a reader who trusts them will get the current behaviour wrong.

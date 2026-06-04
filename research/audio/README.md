# Audio Capture & Recording Research

## Summary

For capturing meeting audio on macOS 15+, we recommend a **dual-API approach**: Core Audio process taps (`CATapDescription` / `AudioHardwareCreateProcessTap`, introduced macOS 14.2, expanded 14.4) for system/app audio (other participants), and `AVAudioEngine` for microphone input (the user). These run as two independent streams recorded into separate files using the crash-safe **CAF container** with **AAC-LC at 64 kbps mono, 48 kHz**. After the meeting, the two files are post-processed (merged or kept separate depending on the STT pipeline's needs). A health-monitor detects the known zero-buffer failure mode and performs automatic teardown/rebuild of the tap. This combination avoids the Screen Recording permission (which ScreenCaptureKit requires) and is expected to keep CPU overhead very low on Apple Silicon (estimate to validate in E1).

## Key Questions & Findings

### 1. Best macOS 15 API to capture both mic and other-participants' audio

**Finding: Use two APIs in tandem -- Core Audio process taps for system audio, AVAudioEngine for mic.**

There is no single Apple API that cleanly captures both microphone and system/app audio as independent, well-separated streams without drawbacks. The candidates evaluated:

| API | System Audio | Mic | Permission | Pros | Cons |
|-----|-------------|-----|------------|------|------|
| **Core Audio process taps** (`CATapDescription`) | Yes (per-app or global) | No | `NSAudioCaptureUsageDescription` (narrower "System Audio Recording Only" permission) | Purpose-built for audio-only capture; narrower permission scope (no screen access); no periodic re-authorization; per-process filtering; no video overhead | Poorly documented; known zero-buffer bug; no mic support; API is low-level C |
| **ScreenCaptureKit** (`SCStream`) | Yes (per-app) | Yes (macOS 15+ via `captureMicrophone`) | Screen & System Audio Recording (broader permission) | Higher-level API; can capture both mic + system audio; Apple sample code | Requires broader Screen Recording permission (alarming prompt on Sequoia); periodic re-authorization required (monthly on Sequoia, relaxed but not eliminated in 15.1); video capture overhead even for audio-only; `captureMicrophone` is new and has corruption bugs; mic + app audio arrive as interleaved types requiring careful separation |
| **AVAudioEngine / AVAudioSession** | No | Yes | `NSMicrophoneUsageDescription` | Well-documented; handles mic switching; low overhead; direct audio pipeline | System audio not supported |
| **AVFoundation (`AVCaptureSession`)** | No | Yes | Microphone | Higher-level mic capture | No system audio; less control than AVAudioEngine |
| **WhisperKit live streaming** (feed buffers directly to STT) | Indirect (needs a capture API to supply buffers) | Indirect (same) | Same as whichever capture API feeds it | Collapses capture+file+process into one pipeline; real-time partial transcripts via LocalAgreement streaming; no intermediate file | Requires ML models loaded during the entire meeting (~180 MB-3.5 GB RAM, significant CPU/NPU); no saved audio file for re-transcription with future models; couples recorder stability to ML inference stability; diarization (SpeakerKit) would also need to run live or be deferred anyway; not a capture API itself -- still needs one of the above to actually obtain audio |

**Why Core Audio taps over ScreenCaptureKit for system audio:**

1. **Permission scope & re-authorization**: Core Audio taps use `NSAudioCaptureUsageDescription`, which requests the narrower "System Audio Recording Only" permission. ScreenCaptureKit requires the broader "Screen & System Audio Recording" permission, which on macOS Sequoia shows a warning that the app "is requesting to bypass the system private window picker and directly access your screen and audio." For a meeting recorder that never needs screen content, requesting screen access is unnecessarily alarming. Both APIs trigger the same purple system-audio indicator dot when active. Crucially, ScreenCaptureKit's Screen Recording permission requires **periodic re-authorization** -- monthly on Sequoia, reduced but not eliminated in 15.1 ([9to5Mac](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/), [iDownloadBlog: 15.1 changes](https://www.idownloadblog.com/2024/10/09/macos-sequoia-15-1-macos-screen-recording-prompts-frequency-reduced/)). The narrower audio-capture permission does not require periodic re-authorization. ([Apple Support](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac), [AudioCap README](https://github.com/insidegui/AudioCap))

2. **No video overhead**: ScreenCaptureKit is designed around screen capture; even for audio-only use, you must configure a display/window filter. Core Audio taps are audio-native with no video pipeline. ([Recall.ai comparison](https://www.recall.ai/blog/how-to-access-to-system-audio))

3. **Stability**: There are unverified reports of a ScreenCaptureKit `EXC_BAD_ACCESS` crash in `swift_getErrorValue` during `SCStreamDelegate.didStopWithError` after 3-4 segments of 60-second recordings (source: community reports; no specific bug tracker URL confirmed). Core Audio taps have the zero-buffer issue (see Risks section) but it is recoverable.

4. **ScreenCaptureKit mic support is immature**: `captureMicrophone` (macOS 15+) delivers mic and app audio as interleaved sample buffers with different `CMFormatDescriptions` through the same delegate. Writing both to a single `AVAssetWriterInput` corrupts the file. This is a solvable problem but adds complexity and fragility. ([Apple Developer Forums](https://developer.apple.com/forums/thread/805892))

**Why AVAudioEngine for mic rather than ScreenCaptureKit mic:**
AVAudioEngine is the standard, well-documented, stable API for microphone capture on macOS. It requires only the `NSMicrophoneUsageDescription` permission (which users expect a meeting app to request). It provides direct access to the audio pipeline with buffer callbacks, automatic format conversion, and straightforward device selection. ([Apple AVAudioEngine docs](https://developer.apple.com/documentation/avfaudio/avaudioengine))

**Sources:**
- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [AudioCap by insidegui](https://github.com/insidegui/AudioCap)
- [AudioTee by makeusabrew](https://github.com/makeusabrew/audiotee) / [Strongly Typed article](https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos)
- [Recall.ai: How to access system audio on macOS](https://www.recall.ai/blog/how-to-access-to-system-audio)
- [CoreAudio Taps for Dummies](https://www.maven.de/2025/04/coreaudio-taps-for-dummies/)
- [From Core Audio to LLMs (DEV Community)](https://dev.to/yingzhong_xu_20d6f4c5d4ce/from-core-audio-to-llms-native-macos-audio-capture-for-ai-powered-tools-dkg)

---

### 2. Independent streams vs. merged: can we get them, and which to record?

**Finding: Yes, we can and should capture mic and system audio as two independent streams. Record both separately.**

**How it works:**

- **Mic stream**: `AVAudioEngine.inputNode` provides PCM buffers from the selected microphone via an install-tap callback. This runs on a dedicated audio thread.
- **System audio stream**: `CATapDescription` configured for the target meeting app (or globally) delivers PCM buffers through an `AudioDeviceIOProc` callback on a dedicated audio thread. The two streams are inherently independent -- different APIs, different threads, different hardware paths.

**Why record separately (two files):**

1. **Speaker identification**: Knowing which audio came from the mic (user) vs. system (remote participants) is a strong signal for diarization. The STT pipeline can use this to definitively identify "me" without relying solely on voice fingerprinting.
2. **Flexibility for ArgMax SDK**: R3 research will determine whether the ArgMax SDK works better with a single merged stream or two time-aligned streams. By recording both, we preserve optionality -- we can always merge post-hoc but cannot separate post-hoc.
3. **Echo cancellation**: If both streams are separate, we can apply echo cancellation more effectively (the mic stream may pick up speaker bleed, which the system-audio stream can be used as a reference to subtract).
4. **File size is small**: Two mono voice-quality AAC streams at 64 kbps each = ~128 kbps total = ~1 MB/min. A 1-hour meeting is ~60 MB. Negligible.

**Implementation detail**: Both files share a common start timestamp (captured at recording start via `mach_absolute_time()` or `CACurrentMediaTime()`) so they can be time-aligned during post-processing.

**Sources:**
- [From Core Audio to LLMs](https://dev.to/yingzhong_xu_20d6f4c5d4ce/from-core-audio-to-llms-native-macos-audio-capture-for-ai-powered-tools-dkg) (notes two-channel structure: "two channels are always given, one for input and one for output")
- [Recall.ai](https://www.recall.ai/blog/how-to-access-to-system-audio)

---

### 3. Identifying source app and detecting meetings starting/stopping

**Finding: Core Audio provides process-level audio enumeration. We can identify which apps are producing audio and detect when they start/stop.**

**Identifying the source app:**

Starting with macOS 14.0 (Sonoma), Core Audio exposes process-level audio information:

- `kAudioHardwarePropertyProcessObjectList` (on `kAudioObjectSystemObject`): Returns an array of `AudioObjectID` values for all processes currently interacting with the audio system.
- `kAudioProcessPropertyBundleID`: Returns the bundle identifier of a process object (e.g., `us.zoom.xos`, `com.microsoft.teams2`, `com.google.Chrome`).
- `kAudioProcessPropertyPID`: Returns the POSIX process ID (macOS 14.0+).
- `kAudioProcessPropertyIsRunningInput`: Whether the process is actively using audio input (microphone).
- `kAudioProcessPropertyIsRunningOutput`: Whether the process is actively using audio output.
- `kAudioHardwarePropertyTranslatePIDToProcessObject`: Translates a PID to an `AudioObjectID` for use with `CATapDescription`.

**Detecting meetings starting/stopping:**

We can poll or listen for changes to `kAudioHardwarePropertyProcessObjectList` and cross-reference against a known list of meeting app bundle IDs:

| App | Bundle ID |
|-----|-----------|
| Zoom | `us.zoom.xos` |
| Microsoft Teams | `com.microsoft.teams2` |
| Google Chrome (Meet, etc.) | `com.google.Chrome` |
| Slack | `com.tinyspeck.slackmacgap` |
| Cisco Webex | `com.cisco.webexmeetingsapp` |
| Discord | `com.hnc.Discord` |
| FaceTime | `com.apple.FaceTime` |
| Safari (web meetings) | `com.apple.Safari` |
| Arc Browser | `company.thebrowser.Browser` |

**Detection strategy:**

1. Maintain a watchlist of known meeting-app bundle IDs (user-configurable in settings).
2. Use `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyProcessObjectList` to get notified when processes start/stop using audio.
3. When a known meeting app appears in the process list with `kAudioProcessPropertyIsRunningOutput == true` AND `kAudioProcessPropertyIsRunningInput == true` (using both mic and speaker = likely in a call), suggest starting recording via the tray notification.
4. When the process disappears or stops using audio I/O, suggest stopping recording.
5. For browser-based meetings (Chrome, Safari, Arc), detection is coarser -- the browser is "the app," not the specific tab. We can still detect when Chrome starts using mic + audio output, which is a strong signal for a web meeting. EventKit calendar data (R2) can provide corroborating evidence.

**Caveat**: `kAudioProcessPropertyIsRunningOutput` reports IO registration, not non-zero sample contribution. A muted Zoom call still reports `true`. This is acceptable for our use case (we want to know when a meeting is active, not when someone is speaking).

**Sources:**
- [Apple: kAudioHardwarePropertyProcessObjectList](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertyprocessobjectlist)
- [Apple: kAudioHardwarePropertyProcessIsAudible](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertyprocessisaudible)
- [AudioCap CoreAudioUtils.swift](https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/CoreAudioUtils.swift)
- [MacWhisper automatic meeting detection](https://macwhisper.helpscoutdocs.com/article/30-record-meetings)

---

### 4. Audio format/compression: recommended encoder settings

**Finding: AAC-LC at 64 kbps mono, 48 kHz sample rate, in a CAF container. Convert to M4A for long-term storage after recording.**

> **⚠️ Revised by Phase 9 validation (Test 5).** Final choice is **ADTS AAC-LC, 24 kHz, mono, 64 kbps** — *not* CAF. **Container:** CAF+AAC is **not crash-safe** (needs a `pakt` chunk written only on close); **ADTS** is self-syncing and decodes up to the last frame after a crash (see [finding #5](./phase9_validation_findings.md)). **Sample rate:** **24 kHz** — our STT models run at 16 kHz internally, so 24 kHz covers them with headroom for future higher-rate models at a small size cost (settles open-question #3 below). The codec/bitrate reasoning below still applies (64 kbps unchanged).

**Why AAC-LC over alternatives:**

| Codec | Quality at Target Bitrate | macOS Native Encode | macOS Native Decode | Container Support | Verdict |
|-------|--------------------------|--------------------|--------------------|-------------------|---------|
| **AAC-LC** (64 kbps) | Good for voice | Yes (AudioToolbox) | Yes | M4A, CAF, MP4 | **Recommended** -- native, proven, universal playback |
| **HE-AAC v1** (48 kbps) | Better at very low bitrates | Yes | Yes | M4A, CAF | Good alternative if file size is critical; less tooling compatibility |
| **Opus** (32-48 kbps) | Best at low bitrates | Partial (`kAudioFormatOpus` exists but poorly documented) | Yes | CAF, OGG | Superior codec but macOS native encoding support is immature; risky for production |
| **AAC-LC** (48 kbps) | Adequate for voice but at the low end of AAC-LC's effective range | Yes | Yes | M4A, CAF | Works but 64 kbps is a safer operating point for AAC-LC; at 48 kbps consider HE-AAC v1 instead |

**Why 64 kbps instead of 48 kbps**: 64 kbps mono is at the low end of AAC-LC's effective range (the codec is typically cited as performing well from 64 kbps up). At 48 kbps you are below that floor and quality degrades -- if 48 kbps is truly needed, HE-AAC v1 would be a better choice at that bitrate since it was designed for the 32-64 kbps range. We recommend 64 kbps AAC-LC as the pragmatic sweet spot: firmly within the codec's capable range for voice, with a small file size premium over 48 kbps. The file size difference is modest: 64 kbps mono = ~0.48 MB/min vs. 48 kbps = ~0.36 MB/min. For a 1-hour meeting, that is 29 MB vs 22 MB per stream. The 7 MB savings is not worth the quality trade-off. ([Hydrogenaudio](https://wiki.hydrogenaudio.org/index.php?title=Apple_AAC), [Hydrogenaudio forums](https://hydrogenaudio.org/index.php/topic,121779.0.html))

**Why 48 kHz sample rate**: The system audio from Core Audio taps arrives at the output device's native sample rate (typically 44.1 or 48 kHz). Using 48 kHz avoids unnecessary resampling in the common case and is the broadcast standard. For voice, 16 kHz would suffice for intelligibility, but since we want to preserve quality for potential re-transcription with future models, 48 kHz is a small cost for maximum fidelity.

**Why not Opus**: Opus is technically superior at low bitrates (especially for speech), but Apple's native Opus encoding via `kAudioFormatOpus` / `AVAudioConverter` is poorly documented and has known issues with `AudioStreamBasicDescription` field population. Using libopus directly adds a non-trivial dependency. Since we are only saving for archival/re-transcription (not streaming), AAC-LC at 64 kbps is entirely adequate and fully native. We can revisit Opus if Apple improves native support.

**Recommended encoder settings (Swift):**

```swift
// For AVAudioFile or AVAudioConverter output settings:
let encoderSettings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),      // AAC-LC
    AVSampleRateKey: 48_000.0,                      // 48 kHz
    AVNumberOfChannelsKey: 1,                        // Mono
    AVEncoderBitRateKey: 64_000,                     // 64 kbps
    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
]
// File type: .caf during recording (crash-safe), convert to .m4a after
```

**Sources:**
- [Apple AAC - Hydrogenaudio Knowledgebase](https://wiki.hydrogenaudio.org/index.php?title=Apple_AAC)
- [AAC for speech - Hydrogenaudio Forum](https://hydrogenaudio.org/index.php/topic,121779.0.html)
- [Opus vs AAC comparison](https://www.hitpaw.com/other-audio-formats-tips/opus-vs-aac.html)
- [Apple: kAudioFormatOpus](https://developer.apple.com/documentation/coreaudiotypes/kaudioformatopus)
- [Apple Developer Forums: AVAudioConverter Opus](https://developer.apple.com/forums/thread/127317)

---

### 5. Crash-safe streaming to disk

> **⚠️ Corrected by Phase 9 validation (Test 5).** CAF crash-safety holds **only for uncompressed PCM**, *not* for AAC-LC. Recording AAC-LC into CAF and crashing leaves an **undecodable** file ("Missing packet table") because AAC's variable-size packets need the `pakt` chunk, which `AVAudioFile` writes only on close. **Corrected approach: record PCM into CAF during capture, encode to AAC `.m4a` on stop.** See [finding #5 in the validation findings](./phase9_validation_findings.md). The mechanism below is right; only the *codec recorded during capture* changes (PCM, not AAC).

**Finding: Record into CAF (Core Audio Format) files, which are crash-safe by design. Convert to M4A post-recording for long-term storage.**

**The problem with M4A/MP4**: M4A files store their MOOV atom (metadata/index) at the end of the file. If the app crashes before the file is finalized, the MOOV atom is never written and the entire file is unreadable. This is a well-known problem. ([Apple Developer Forums](https://forums.developer.apple.com/forums/thread/720691?answerId=744192022))

**Why CAF is crash-safe**: Apple's Core Audio Format (CAF) has a specific design feature for this: when the Audio Data chunk's size field is set to `-1`, the chunk must be the last in the file, and the audio data extends to the end of the file. A reader can determine the data size by subtracting the data-chunk offset from the file size. This means:

- If the app crashes mid-write, the CAF file is still readable up to the last fully written audio packet.
- No finalization step is required for the file to be playable.
- CAF files have no 4 GB size limit (uses 64-bit offsets), unlike WAV.
- CAF natively supports AAC-LC encoding (unlike WAV which is PCM-only).

([Core Audio Format spec](https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_overview/CAF_overview.html), [Wikipedia: Core Audio Format](https://en.wikipedia.org/wiki/Core_Audio_Format))

**Recording approach:**

1. **During recording**: Write PCM buffers to a `.caf` file using `AVAudioFile(forWriting:settings:commonFormat:interleaved:)` with AAC-LC encoding settings. Each `write(from:)` call appends compressed audio data. The file is valid at every point.
2. **After recording**: Convert the `.caf` to `.m4a` using `AVAssetExportSession` or `AVAssetWriter` for better compatibility with external tools and slightly smaller file size (CAF has more header overhead). Keep the `.caf` until the `.m4a` is verified.
3. **Crash recovery on next launch**: On app startup, scan for `.caf` files that were not converted to `.m4a`. These represent interrupted recordings. Present them to the user as recovered partial recordings.

**Alternative considered**: `AVAssetWriter` with `movieFragmentInterval` for fragmented MP4. This works but adds complexity (managing fragment intervals, handling writer state) and is designed for video-centric workflows. CAF is simpler and purpose-built for audio.

**Sources:**
- [Apple: CAF Overview](https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_overview/CAF_overview.html)
- [Apple Developer Forums: Write AAC files crash-safely](https://forums.developer.apple.com/forums/thread/720691?answerId=744192022)
- [Apple: Supported Audio Formats in macOS](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/SupportedAudioFormatsMacOSX/SupportedAudioFormatsMacOSX.html)

---

### 6. Failure modes and mitigations

#### 6a. Zero-filled buffers from process tap (CRITICAL)

**Symptom**: `AudioDeviceIOProc` callback continues firing at normal cadence, but every PCM sample is exactly `0.0f`. All metadata (frame count, timestamps, buffer pointers) remains valid. The user can still hear audio through their speakers. ([Apple Developer Forums](https://developer.apple.com/forums/thread/825780))

**Observed behavior** (51-minute session on MacBook Air M2, macOS 26.5 Beta -- **note: this was observed on a beta OS; behavior may differ on macOS 15 release builds. E1 validation should confirm whether this reproduces on our target OS.**):
- Segment 1 (~7 min): Three zero-periods of 60s, 53s, 141s with brief real-PCM returns between them.
- Segment 2 (~44 min): Two zero-periods of 16m 3s and 3m 8s.

**Known triggers**:
- Sample-rate renegotiation on the output device (44.1 kHz to 48 kHz) when another app changes the output format.
- Bluetooth device state changes (AirPods sleep/wake cycles where the device UID stays the same).
- Extended uptime -- first few minutes are consistently clean.
- MacBook Air more frequently affected than MacBook Pro (possibly thermal/power-state related).

**Detection challenge**: Zero-filled buffers are indistinguishable from legitimate silence (muted participant, waiting room). `kAudioProcessPropertyIsRunningOutput` still reports `true` during the failure.

**Mitigation strategy**:

1. **RMS health monitor**: Compute running RMS of the system-audio stream in a sliding window (e.g., 30 seconds). If RMS is exactly 0.0 for >30 seconds while `kAudioProcessPropertyIsRunningOutput` is `true` for the target process, flag as suspected tap failure.
2. **Automatic teardown/rebuild**: Perform the full recovery sequence:
   ```
   AudioDeviceStop(aggregateDevice, ioProcID)
   AudioDeviceDestroyIOProcID(aggregateDevice, ioProcID)
   AudioHardwareDestroyAggregateDevice(aggregateDevice)
   AudioHardwareDestroyProcessTap(tapObjectID)
   // Recreate everything:
   AudioHardwareCreateProcessTap(tapDescription, &tapObjectID)
   AudioHardwareCreateAggregateDevice(config, &aggregateDevice)
   AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDevice, ..., block)
   AudioDeviceStart(aggregateDevice, ioProcID)
   ```
   Partial teardown (restarting only the IOProc or only the aggregate device) is NOT reliable -- both the process tap and aggregate device must be destroyed and recreated.
3. **Logging**: Log zero-buffer events with timestamps to the research doc's validation results. This data helps Apple's Core Audio team if we file a Feedback.
4. **User notification**: If teardown/rebuild fails to restore audio after 2 attempts, show a non-intrusive notification suggesting the user restart the app. This should be extremely rare.

**Sources:**
- [Apple Developer Forums: AudioHardwareCreateProcessTap delivers all-zero buffers](https://developer.apple.com/forums/thread/825780)

#### 6b. Level attenuation with multi-output devices

**Symptom**: Consistent volume reduction that scales with the number of stereo output pairs on the target device. Devices with 4 stereo pairs (8 outputs) show -12.04 dB relative to source. True 2-channel devices (built-in speakers, AirPods) show ~0 dB attenuation.

**Cause**: Undocumented behavior in macOS's audio mixing pipeline. The attenuation roughly follows the formula `20 * log10(N_pairs)` dB, but this is **not universal** -- it depends on how each app routes its output (to "System/Default Output" vs. directly to a specific multi-output device). Apps routing to the default output often show no attenuation even on multi-pair devices, while apps routing directly to a multi-output interface show the scaled attenuation. This means a single tap capturing multiple processes may see inconsistent levels across them.

**Mitigation**:
- Query the output device's channel count and apply gain compensation as a heuristic.
- For most users (built-in speakers, AirPods, standard USB headsets = 2-channel devices), this is a non-issue (~0 dB attenuation).
- For users with professional multi-output audio interfaces, apply the compensation formula as a best-effort correction, but be aware it may not perfectly compensate all processes.
- This primarily affects recording level, not playback -- the user hears audio at normal volume through their device.

**Sources:**
- [Apple Developer Forums: Core Audio Tap per-device attenuation vs. stereo output pairs](https://developer.apple.com/forums/tags/core-audio) (separate thread from the zero-buffer issue; exact thread URL not confirmed via search but the report is by developer "David" under the Core Audio tag, describing RME Fireface 8-out / -12.04 dB measurements)

#### 6c. Microsoft Teams silent capture

**Symptom**: `CATapDescription` process tap captures zero audio from Microsoft Teams specifically. Other apps (Zoom, Chrome) work normally.

**Cause**: Teams may use a non-standard audio pipeline (WebRTC-based) or route audio through a sub-process that the tap does not target. Teams' non-standard 24 kHz output rate may also cause format negotiation failures.

**Mitigation**:
- Use a **global tap** (all processes, no exclusions) instead of per-process tap for Teams. This captures all system audio but avoids the per-process targeting issue.
- Alternatively, ScreenCaptureKit may capture Teams audio where process taps fail (suggested as a diagnostic in the [meeting-transcriber issue](https://github.com/pasrom/meeting-transcriber/issues/79)).
- This is an edge case to validate in the experiment (E1). If it persists, we may need a fallback path using a global tap or ScreenCaptureKit for Teams specifically.

**Sources:**
- [meeting-transcriber Issue #79](https://github.com/pasrom/meeting-transcriber/issues/79)

#### 6d. Device switching mid-recording

**Symptom**: User plugs in headphones, connects AirPods, or switches audio devices during a meeting. The tap and/or mic capture may stop producing audio.

**Mitigation**:
- Listen for `kAudioHardwarePropertyDefaultOutputDevice` and `kAudioHardwarePropertyDefaultInputDevice` changes via `AudioObjectAddPropertyListenerBlock`.
- On output device change: teardown and rebuild the process tap + aggregate device targeting the new output.
- On input device change: stop and restart the AVAudioEngine with the new input device.
- Both operations should be near-instantaneous (sub-second gap in recording).

#### 6e. Permission denial

**Symptom**: User denies audio capture permission. The tap creates successfully but delivers silence. There is no public API to check `NSAudioCaptureUsageDescription` permission status.

**Mitigation**:
- AudioCap uses private TCC framework APIs for permission checking, but this prevents App Store distribution.
- For our non-sandboxed experiment: attempt to start capture, detect zero buffers in the first 2 seconds, and prompt the user to grant permission in System Settings.
- For the production app: rely on the OS permission prompt and handle the denial case with a clear in-app explanation.

**Sources:**
- [AudioCap AudioRecordingPermission.swift](https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/AudioRecordingPermission.swift)

---

### 7. CPU/memory/NPU cost

**Finding: The recording path is expected to be extremely lightweight -- very low CPU, ~10-20 MB memory, zero NPU usage. CPU estimate to be validated in E1.**

**CPU**:
- Core Audio's IO callback mechanism runs on a dedicated real-time audio thread managed by the system. The callback itself only needs to copy PCM buffers and write to a file -- no DSP, no ML, no heavy processing.
- Normal `coreaudiod` overhead is ~0.4% CPU on Apple Silicon when processing audio. The IOProc callback adds negligible overhead on top of this.
- AAC-LC encoding via AudioToolbox is a software encoder (not hardware-accelerated on Apple Silicon). However, encoding a single mono 64 kbps voice stream is computationally trivial -- AAC-LC is a low-complexity profile by design. CPU cost should still be very small but this is an **estimate to validate in E1** with actual profiling.
- AVAudioEngine for mic capture similarly runs on a dedicated audio thread with near-zero overhead for simple tap-and-write.
- **Total expected CPU**: Expected to be very low (likely well under 5%) during active recording on any Apple Silicon Mac. **This is an estimate -- E1 should measure actual CPU with Instruments to confirm.**

**Memory**:
- Process tap + aggregate device: ~2-5 MB for Core Audio internal structures.
- AVAudioEngine: ~2-5 MB for the engine graph and buffers.
- Audio file buffers: ~1-2 MB (rotating write buffers).
- **Total expected memory**: ~10-20 MB.

**NPU**: Zero. No ML inference occurs during recording. The NPU is entirely available for other tasks (and will be needed later for STT/diarization in R3).

**Disk I/O**: At 64 kbps AAC-LC mono x 2 streams = 128 kbps = 16 KB/s. This is negligible for any SSD.

**Sources:**
- [MacRumors Forums: coreaudiod CPU usage on M1](https://forums.macrumors.com/threads/fix-sustained-12-15-coreaudiod-cpu-usage-on-m1-possibly-intel-too.2331498/)
- [Core Audio Essentials](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/CoreAudioEssentials/CoreAudioEssentials.html)


---

### 8 Check logs/warnings

Do a full recording an check any xcode logs and warnings for potential issues/concerns.

---

## Recommendation

### Chosen API

| Component | API | Permission |
|-----------|-----|------------|
| **System audio** (other participants) | Core Audio process taps: `CATapDescription` + `AudioHardwareCreateProcessTap` + aggregate device | `NSAudioCaptureUsageDescription` |
| **Microphone** (user) | `AVAudioEngine` with `inputNode` tap | `NSMicrophoneUsageDescription` |
| **Meeting detection** | `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyBundleID` polling/listening | No additional permission |

**Why not WhisperKit live streaming?** WhisperKit supports real-time streaming transcription by accepting `[Float]` PCM buffers via `transcribe(audioArray:)` and applying a LocalAgreement streaming policy for incremental results. In principle this could collapse the capture-file-process pipeline into a single live path. We evaluated and rejected it for Steak for three reasons: (1) Steak explicitly saves audio files to re-transcribe later with better models -- a live-only pipeline produces no archival recording. (2) Loading STT models during the meeting consumes 180 MB to 3.5 GB of RAM and significant CPU/NPU, directly violating the "lightweight, rock-solid recorder" requirement. (3) Coupling ML inference to the recorder means an inference crash or memory-pressure kill takes down recording too. WhisperKit streaming remains a viable architecture for apps that want live captions without archival, but for Steak the capture and transcription stages should be decoupled: record to file during the meeting, run WhisperKit on the file after the meeting ends. ([WhisperKit GitHub](https://github.com/argmaxinc/WhisperKit), [WhisperKit on macOS guide](https://www.helrabelo.dev/blog/whisperkit-on-macos-integrating-on-device-ml))

### Stream Strategy

- **Two independent mono streams**, each written to its own file.
- Both streams start with a shared reference timestamp for post-hoc alignment.
- File naming: `{meetingID}_mic.caf` and `{meetingID}_system.caf`.

### Encoder Settings

| Setting | Value |
|---------|-------|
| Format | AAC-LC (`kAudioFormatMPEG4AAC`) |
| Sample rate | 48,000 Hz |
| Channels | 1 (mono) |
| Bitrate | 64,000 bps |
| Quality | `.high` |
| Container (recording) | CAF (`.caf`) -- crash-safe |
| Container (storage) | M4A (`.m4a`) -- converted post-recording |

### Crash-Safe Approach

1. Record to `.caf` files with the Audio Data chunk size set to `-1` (automatic in `AVAudioFile`).
2. On normal recording stop: convert `.caf` to `.m4a` via `AVAssetExportSession`, delete `.caf` after verification.
3. On crash recovery (next launch): detect orphaned `.caf` files, present as recovered partial recordings, convert to `.m4a`.

### Process Tap Configuration

```swift
// Pseudocode for system audio capture setup:

// 1. Create tap description targeting the meeting app (or global)
let tapDesc = CATapDescription(processes: [meetingAppProcessID])  // or empty for global
tapDesc.uuid = UUID()
tapDesc.name = "steak-system-tap"
tapDesc.privateTap = true
tapDesc.muteBehavior = .unmuted    // Don't mute the user's audio output
tapDesc.exclusive = false
tapDesc.mixdown = true             // Mono mixdown

// 2. Create process tap
AudioHardwareCreateProcessTap(tapDesc, &tapObjectID)

// 3. Create aggregate device with tap
let config: [String: Any] = [
    kAudioAggregateDeviceUIDKey: tapDesc.uuid.uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
         kAudioSubTapDriftCompensationKey: true]
    ]
]
AudioHardwareCreateAggregateDevice(config, &aggregateDeviceID)

// 4. Read tap format
// kAudioTapPropertyFormat -> AudioStreamBasicDescription

// 5. Set up IO callback
AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { 
    inNow, inInputData, inInputTime, outOutputData, inOutputTime in
    // Write inInputData buffers to CAF file
    // Monitor RMS for zero-buffer detection
}

// 6. Start
AudioDeviceStart(aggregateDeviceID, ioProcID)
```

### Architecture for the Experiment (E1)

```
AudioEngine (class, @MainActor-isolated)
  |
  +-- SystemAudioCapture (actor)
  |     - CATapDescription + aggregate device + IOProc
  |     - Writes to {id}_system.caf
  |     - RMS health monitor
  |     - Auto teardown/rebuild on zero-buffer detection
  |
  +-- MicCapture (actor)
  |     - AVAudioEngine + inputNode tap
  |     - Writes to {id}_mic.caf
  |     - Device-change listener
  |
  +-- MeetingDetector (actor)
  |     - Polls kAudioHardwarePropertyProcessObjectList
  |     - Matches against known meeting-app bundle IDs
  |     - Publishes meeting-started / meeting-stopped events
  |
  +-- RecordingCoordinator
        - Starts/stops both captures together
        - Manages file lifecycle (CAF -> M4A conversion)
        - Crash recovery on launch
```

---

## Risks & Gotchas

| Risk | Severity | Mitigation | Status |
|------|----------|------------|--------|
| Zero-filled buffers from process tap | High | RMS monitor + auto teardown/rebuild | Design ready; observed on macOS 26.5 beta only -- E1 must confirm on macOS 15 |
| Microsoft Teams silent capture | Medium | Fall back to global tap or ScreenCaptureKit for Teams | Needs E1 validation |
| Level attenuation on multi-output devices | Low | Gain compensation based on channel count | Simple formula, low priority |
| No public API to check audio capture permission | Medium | Detect zero buffers on first attempt, prompt user | Acceptable UX |
| Device switching mid-recording | Medium | Property listeners + teardown/rebuild | Standard pattern |
| AVAudioEngine mic switching | Low | Listen for default input device changes, restart engine | Well-documented |
| CAF-to-M4A conversion failure | Low | Keep CAF as fallback; CAF is playable everywhere on macOS | Defense in depth |
| ScreenCaptureKit `EXC_BAD_ACCESS` crash (unverified) | N/A (avoided) | We do not use ScreenCaptureKit | Risk eliminated by API choice |

---

## Open Questions for the Team

1. **Global tap vs. per-process tap as default**: Should we default to a global system audio tap (captures everything including notification sounds, music) and let the user choose to narrow it, or default to per-process tap targeting the detected meeting app? Global is simpler and avoids the Teams issue; per-process is cleaner audio but requires correct process targeting. **Recommendation**: Start with global tap for reliability, add per-process targeting as a refinement.

2. **Teams workaround validation**: The Microsoft Teams silent-capture issue needs to be validated in E1. If confirmed, we need to decide: (a) always use global tap, (b) use ScreenCaptureKit as a fallback for Teams only, or (c) accept the limitation and document it. Option (a) is simplest.

3. **Sample rate for long-term storage**: ~~We recommend 48 kHz...~~ **RESOLVED in Phase 9 → 24 kHz.** Our STT (transcription) models run at **16 kHz internally**, so 24 kHz covers them with **headroom** for future models that may want higher-rate audio, at a small size cost. Capture at **24 kHz mono, 64 kbps AAC-LC** (ADTS). A middle ground between the original 48 kHz fidelity lean and a bare 16 kHz floor.

4. **Opus revisit timeline**: Apple has added `kAudioFormatOpus` but native encoding support is immature. Should we plan to revisit Opus encoding when Apple stabilizes the API (likely macOS 16+)? At 32 kbps Opus, file sizes would be ~50% smaller than 64 kbps AAC-LC with comparable or better voice quality.

5. **ArgMax SDK stream preference (R3 dependency)**: The choice between sending two separate streams vs. a merged stream to the STT/diarization pipeline depends on R3 findings. Our two-file recording approach preserves both options. R3 should specifically test: (a) merged mono, (b) two time-aligned mono files with speaker-side labels.

6. **Notarization impact**: Core Audio taps with `NSAudioCaptureUsageDescription` do not require any special entitlement beyond the Info.plist key for non-sandboxed apps. However, for App Store distribution (if ever considered), the private TCC API usage in permission checking would need to be removed. R4 should confirm the exact notarization requirements.

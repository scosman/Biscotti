---
status: complete
---

# Component: Passive Capture (AudioCapture + CaptureFiles)

## Purpose and scope

Replace the default VPIO mic engine with a passive raw tap that never changes shared audio state. Record every live channel of multichannel devices as per-segment channel files. Write timeline sidecars for both tracks. Publish live levels.

**Not in scope:**
- Any DSP beyond the mean-of-live-channels `mic.aac` downmix and resampling. All interpretation belongs to `AudioProcessing`.
- Device selection UI.
- Any change to the system tap's capture method.

Functional requirements: [functional_spec.md](../functional_spec.md) F1. Contracts: [architecture.md](../architecture.md) §2–3.

## Package layout changes (`Packages/AudioCapture`)

```
Package.swift                          + product "CaptureFiles"; target AudioCapture depends on CaptureFiles
Sources/CaptureFiles/                  NEW (Foundation only; no CoreAudio)
  MeetingAudioFiles.swift              naming + derivation (architecture §2)
  CaptureTimelineEvent.swift           Codable event enum + payload structs
  CaptureTimelineWriter.swift          append-only JSONL writer
  CaptureTimelineReader.swift          tolerant reader → CaptureTimeline (segments, gaps)
  CaptureDeviceInfo.swift              {uid, name, transport, isBuiltInMic} + isBuiltInMic(transport:uid:)
Sources/AudioCapture/
  CaptureOptions.swift                 NEW
  MicCaptureMode.swift                 NEW (.passive, .appleVoiceProcessing)
  CaptureLevels.swift                  NEW
  PassiveMicCaptureEngine.swift        NEW (default)
  VoiceProcessingMicCaptureEngine.swift  RENAMED from LiveMicCaptureEngine.swift; uses mono session mode
  MicCaptureSession.swift              CHANGED: multichannel ring, segments, channel files, timeline, levels
  MicChannelFileWriter.swift           NEW: one mono ADTS writer + its resampler
  MicDownmix.swift                     NEW: pure live-mask + mean-of-live helpers (unit tested)
  AACFileHelper.swift                  RENAMED from VPIOFileHelper.swift (no longer VPIO-specific)
  PCMBufferHelper.swift                RENAMED from VPIOBufferHelper (in the old engine file) — convert/writeBuffer
  LiveSystemCaptureEngine.swift        CHANGED: timeline events, optional PCM reference writer, systemLevel
  SystemGapFillWriter.swift            CHANGED: fan-out to multiple files; returns frames for timeline
  CaptureEngine.swift                  CHANGED: + `var levels: CaptureLevels { get }` (default .zero)
  CaptureState.swift                   CHANGED: new fields
  AudioRecorder.swift                  CHANGED: options plumbing, level publication, comments
  CoreAudioHelpers.swift               CHANGED: + streamConfigurationChannelCount(for:scope:), transportFourCC(for:)
```

## Public interface additions

```swift
// CaptureFiles
public struct CaptureDeviceInfo: Codable, Sendable, Equatable {
    public let uid: String
    public let name: String
    public let transport: String        // FourCC as 4-char string, e.g. "bltn", "usb ", "blue"
    public let isBuiltInMic: Bool
    public static func isBuiltInMic(transport: String, uid: String) -> Bool  // transport == "bltn" && uid == "BuiltInMicrophoneDevice"
}

// AudioCapture
public enum MicCaptureMode: String, Sendable, Codable { case passive, appleVoiceProcessing }

public struct CaptureOptions: Sendable, Equatable {
    public var micMode: MicCaptureMode = .passive
    /// Write mic.seg<K>.ch<N>.aac for multichannel segments (policy D1–D3 decided at Checkpoint 1).
    public var writeChannelFiles: Bool = true
    /// Lab-only: write <systemStem>.ref.caf (Float32 mono LPCM, 48 kHz).
    public var writeSystemPCMReference: Bool = false
    public static let `default` = CaptureOptions()
}

public struct CaptureLevels: Sendable, Equatable {
    public var rms: Float               // 0...1, last ~100 ms of the (mono) written signal
    public var channelPeaks: [Float]    // per captured device channel, 0...1, last ~100 ms (mic only)
    public var channelCount: Int        // current device channel count (mic only)
    public var deviceIsBuiltInMic: Bool // mic only
    public var suspectedSilent: Bool    // mic only, see F1.6
    public static let zero: CaptureLevels
}

public struct CaptureState { // existing fields +
    public let micChannelLevels: [Float]
    public let micChannelCount: Int
    public let micDeviceIsBuiltIn: Bool
    public let micSuspectedSilent: Bool
}

public extension AudioRecorder {
    static func live(encoder: EncoderSettings = .voice, options: CaptureOptions) -> AudioRecorder
}

/// Read-only snapshot of the current default input device. It never opens the device. Used by the lab's idle monitor.
public struct InputDeviceSnapshot: Sendable, Equatable {
    public let device: CaptureDeviceInfo
    public let channelCount: Int          // kAudioDevicePropertyStreamConfiguration, input scope
    public let nominalSampleRate: Double
}
public enum InputDeviceProbe {
    public static func defaultInput() -> InputDeviceSnapshot?
}
```

`AudioRecorder.live(encoder:)` keeps working and is equivalent to `options: .default`. The internal `init` gains an `options` parameter, default `.default`, used only for timeline and system-reference plumbing; the engines receive their options at construction. The state timer, which already ticks at about 4 Hz, raises its rate to 5 Hz and fills `micLevel`, `systemLevel` and the new fields from `micEngine.levels` and `systemEngine.levels`.

## PassiveMicCaptureEngine

A `final class PassiveMicCaptureEngine: CaptureEngine, @unchecked Sendable` with the same lifecycle structure as the current engine: an `engineQueue`, the capturing flag, the config-change observer, `start`, `stop`, `reconnect`, and the first-buffer callback. The differences:

**Build**
1. Create an `AVAudioEngine` and **touch only `inputNode`**. Never access `outputNode` or `mainMixerNode`, because accessing them can instantiate output I/O.
2. Do not call `setVoiceProcessingEnabled`, do not configure ducking, and do not change the nominal sample rate of any device.
3. `let hwFormat = input.inputFormat(forBus: 0)`. Tap with `input.installTap(onBus: 0, bufferSize: 1024, format: nil)`, so the tap format is the hardware format. Read `tapFormat = input.outputFormat(forBus: 0)` for logging.
4. Before installing the tap, call `session.beginFormat(MicSegmentFormat(device:, deviceChannels:, capturedChannels: min(deviceChannels, 16), inputSampleRate: tapFormat.sampleRate, monoOnly: false))`. Device info comes from `CoreAudioHelpers` for the default input device: UID, name, transport FourCC, and channel count from `kAudioDevicePropertyStreamConfiguration` (input scope, summing `mNumberChannels` over its buffers). If the stream-configuration count disagrees with `tapFormat.channelCount`, use `tapFormat.channelCount` (what we actually receive) and log the mismatch once.
5. `engine.prepare(); try engine.start()`.

**Config change** (`AVAudioEngineConfigurationChange` for our engine): on `engineQueue`, if capturing and not tearing down:
- invalidate the tap;
- tear the engine down;
- rebuild (steps 1–5).

Rebuilding calls `beginFormat` again, so the session starts a new segment when the format differs. A pre-first-buffer "absorb" path isn't needed: there's no VPIO startup settle. If a rebuild fails, apply the existing unrecoverable-error handling.

**Reconnect** (default input changed): same as the config-change rebuild. It must not erase the file.

**Teardown:** remove the tap, then stop the engine. There's no VP toggle and no output-rate restore.

**Not changed:** `AudioRecorder`'s first-buffer anchor wait and its retry policy.

## VoiceProcessingMicCaptureEngine (comparison only)

This is the current `LiveMicCaptureEngine`, renamed, with its behaviour unchanged:
- VPIO;
- the output reclock;
- `.min` ducking;
- the silent output node.

The only change: before installing its tap it calls `session.beginFormat(…, capturedChannels: 1, monoOnly: true)`, so the session copies only channel 0 (the processed mono) and writes no channel files. Add the class-level comment `// TODO(passive_mic_pipeline, Checkpoint 2): delete or promote to a user setting.`

`AudioRecorder.live(options:)` chooses the engine from `options.micMode`. The app's `RecordingController` keeps calling `AudioRecorder.live(encoder:)`, which means `.passive`.

## MicCaptureSession (multichannel)

### Ring

These are preallocated in `init`; the real-time path never allocates.

| Constant | Value | Notes |
|---|---|---|
| `ringCapacity` | 128 | |
| `maxCapturedChannels` | 16 | |
| `slotFloatCapacity` | 65,536 | floats per slot (256 KB). An entry needs `frameLength × capturedChannels ≤ slotFloatCapacity`, otherwise it's dropped and counted, as today. Examples: 16 ch × 4096 frames, 3 ch × 21,845 frames, 1 ch × 65,536 frames. |
| Virtual size | 32 MB | Resident memory is proportional to the frames actually written. |

`SlotHeader` adds `channelCount: UInt16` and `formatGeneration: UInt32`. The tap callback copies the first `capturedChannels` channels, from `floatChannelData[c]` for c in 0..<capturedChannels, into the slot contiguously (channel-major: `slot[c * frames + i]`).

### Format generations

`beginFormat(_:)` is called on `engineQueue` while no tap is installed. It:
1. stores the `MicSegmentFormat` in a `Mutex` slot;
2. increments an `Atomic<UInt32> formatGeneration`;
3. makes the tap handler read the generation at enqueue time. It's an atomic load, which is fine on the RT path.

`makeTapHandler()` captures the current `capturedChannels` immutably for that tap, so an old tap can never write a different channel count.

### Writer thread, per entry

The steps, in order:

1. **Segment management.** If `entry.formatGeneration != currentGeneration`:
   1. `endSegment()`: close the channel writers. For each channel whose `everLive == false`, delete its file and add it to `deadChannels`. Write `segmentEnd {segment, sample: micFramesWritten, deadChannels}`.
   2. `startSegment(format)`: increment `segmentIndex`. Open channel writers if `writeChannelFiles && !monoOnly && capturedChannels > 1`. Write `segmentStart`, with `channelFiles` listing every opened file, live or not yet.
   3. Reset the live mask.
2. **Live mask.** For each channel, compute `peak = vDSP_maxmgv`. If `peak > 1e-5` (−100 dBFS), set `everLive[c] = true`.
3. **Downmix** with `MicDownmix.meanOfLive(entry, liveMask) → [Float]` into a preallocated scratch buffer of at most 65,536 floats:
   - 1 channel: a copy;
   - otherwise: `Σ live / liveCount`;
   - no live channel: zeros.
4. **Gap fill.** Existing logic, but the silence goes to `mic.aac` **and** to every open channel writer, and a `gap {sample, frames, reason:"hostTimeGap"}` event is written. The frame counts at 24 kHz are identical across writers, because they come from the same host-time gap computed at the output rate.
5. **Write the mono mix to `mic.aac`.** Existing converter path (input rate → 24 kHz) and `PCMBufferHelper.writeBuffer`.
6. **Write each channel file.** For each open channel writer, `channelWriter.write(samples: slot[c * frames ..< (c + 1) * frames], sampleRate:)`. Each writer owns its own `AVAudioConverter`, mono to mono, so the discrete-layout zeroing pitfall can't happen.
7. **Count frames.** `micFramesWritten` advances by the frames written to `mic.aac`, measured as converter output frames. Segment `sample` values use this counter.
8. **Levels**, at most every 100 ms:
   - `rms` of the downmix over the window;
   - `channelPeaks[c]`;
   - a silence tracker: `secondsBelow90dB` accumulates while every channel's peak is below −90 dBFS and resets otherwise; `suspectedSilent = secondsBelow90dB ≥ 30`.

   These are published through a `Mutex<CaptureLevels>` that only the writer thread writes.
9. **First buffer.** The existing first-buffer anchor logic (`onFirstBuffer`) is unchanged. The first entry also writes `start {track:"mic", hostTime, outputSampleRate, micMode}` before the first `segmentStart`.

On `close()`:
1. drain the ring;
2. call `endSegment()`;
3. write `stop {sample}`;
4. synchronize and close the timeline;
5. dispose the files (existing behaviour).

On a writer error: if `mic.aac` fails, the existing `writeError` path applies. If a channel writer fails, that writer is closed, removed from the active set, and logged once. Its file is kept up to the failure point, and the timeline gets a `{"type":"channelWriteFailed","segment":K,"channel":N,"sample":S}` event, which readers treat as end-of-data for that file.

### MicChannelFileWriter

```swift
final class MicChannelFileWriter {   // writer-thread only
    init(url: URL, encoder: EncoderSettings) throws          // AACFileHelper.createExtAudioFile(mono, 24 kHz, 64 kbps)
    func write(samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> OSStatus  // resample via own converter (rebuilt if rate changes)
    func writeSilence(frames: Int) -> OSStatus                // at output rate
    func close()
    private(set) var everLive: Bool
}
```

## LiveSystemCaptureEngine changes

- **Timeline.** The writer thread owns a `CaptureTimelineWriter` for `<systemStem>.timeline.jsonl` and writes these events:
  - `start {track:"system", hostTime of first frame, outputSampleRate: 24000}`;
  - `leadingSilence {frames}`, in output frames: the existing count converted from tap rate to 24 kHz with `round(frames × 24000 / tapRate)`;
  - `gap {sample, frames}` for every `SystemGapFillWriter` fill; `processBuffer` already returns the frames filled;
  - `reconnect {sample, hostTime}` on `reconnect()`;
  - `segmentStart {…, channels, inputSampleRate}` whenever `detectAndApplyFormatChange()` reports a change;
  - `stop {sample}`.

  `sample` is tracked as output frames: input frames converted at the tap rate.
- **PCM reference** (`writeSystemPCMReference`).
  - A second `ExtAudioFileRef` is created: CAF, LPCM Float32, mono, 48 kHz, with the same client format as the AAC file.
  - Leading silence, gap fills and audio writes go to both files. `SystemGapFillWriter.processBuffer` and `writeLeadingSilence` accept `[ExtAudioFileRef]`.
  - Write errors on the reference are logged once, after which that file is dropped. They never affect `system.aac`.
- **Levels.** `levels.rms` comes from the mono tap data over 100 ms windows; channel fields are unused.

## Pure helpers (unit-testable without hardware)

- `MicDownmix.updateLiveMask(_ mask: inout [Bool], channels: UnsafePointer<Float>, frames: Int, channelCount: Int)` and `meanOfLive(...)`.
- `CaptureDeviceInfo.isBuiltInMic(transport:uid:)`.
- `MeetingAudioFiles` derivation.
- The timeline writer and reader.

## Test plan (`AudioCaptureTests`)

| Test | Verifies |
|---|---|
| `meetingAudioFiles_derivesAllNames` | Names follow architecture §2, for `mic.aac` and for custom stems |
| `timeline_roundTrip_allEventTypes` | Writer → reader is lossless; `segments` and `gaps` are derived correctly |
| `timeline_reader_toleratesTruncatedLastLine_unknownType_missingStop` | Crash tolerance |
| `isBuiltInMic_requiresTransportAndUID` | `bltn` + `BuiltInMicrophoneDevice` → true; `bltn` + `BuiltInHeadphoneInputDevice` → false; `usb ` + any UID → false |
| `downmix_meanOfLive_ignoresDeadChannels` | Channel 1 at −120 dB and channel 2 speech → output equals channel 2 |
| `downmix_liveMaskIsSticky` | A channel stays live after going quiet |
| `session_monoDevice_writesOnlyMicAAC` | 1 channel → no channel files; timeline has one single-channel `segmentStart` |
| `session_threeChannel_writesChannelFiles_realAAC48to24` | Synthetic 48 kHz 3-ch buffers produce `mic.aac` plus `seg1.ch1-3.aac`. Decoded durations match within 1 AAC frame; `mic.aac` correlates with the mean |
| `session_deadChannelDeletedAtSegmentEnd` | An all-zero channel's file is deleted; `deadChannels` is listed |
| `session_formatFlip_1to3to1_createsSegments` | `beginFormat` changes give segments 1, 2, 3. Channel files only for segment 2. `sample` boundaries are consistent with the `mic.aac` length |
| `session_gapFill_appliesToChannelFiles` | A host-time gap produces equal silence in `mic.aac` and the channel files, and a `gap` event |
| `session_monoOnlyMode_copiesChannel0_noChannelFiles` | VPIO-mode behaviour |
| `session_channelCap16` | A 20-channel buffer captures 16 channels |
| `session_levels_publishRMSAndPeaks_andSuspectedSilent` | Levels track the input; `suspectedSilent` after 30 s below −90 dBFS, and it resets |
| `systemGapFill_fansOutToMultipleFiles` | The PCM reference gets identical silence |
| `recorder_options_selectEngine_andPublishLevels` | Fakes: `levels` flow into `CaptureState` |
| Existing suites | Renamed types compile; all existing tests stay green |

Hardware validation of `PassiveMicCaptureEngine` happens in the lab (`mp_*`) and in the `ac_*` re-run. Per the staleness rule, Phase 4 marks every `ac_*` recordable step `not-run`.

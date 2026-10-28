---
status: complete
---

# Component: AudioProcessing Core

## Purpose and scope

This is a new SPM package, `Packages/AudioProcessing`. Given a meeting's raw files, it produces:
- the 16 kHz mono mix for transcription;
- the processed mic file for playback;
- a report.

It's pure DSP: no devices and no permissions. It runs inside the Transcriber XPC, `audioproc-cli`, and the lab.

**Not in scope:**
- the echo engine internals: see [echo_cancellation.md](./echo_cancellation.md);
- test generators: see [test_signal_kit.md](./test_signal_kit.md);
- live or streaming operation.

Behaviour: [functional_spec.md](../functional_spec.md) F2, F7.

## Package layout

```
Packages/AudioProcessing/
  Package.swift
  Sources/AudioProcessing/
    Pipeline/MeetingAudioProcessor.swift      facade, stage orchestration, cancellation, queue
    Pipeline/ProcessingOptions.swift
    Pipeline/ProcessedMeetingAudio.swift
    Pipeline/ProcessingReport.swift           Codable report + ProcessingWarning
    Pipeline/AudioProcessingError.swift
    IO/AudioFileDecoder.swift                 any AVAudioFile-readable file → 16 kHz mono [Float] (chunked)
    IO/ProcessedMicWriter.swift               [Float] 16 kHz → <stem>.processed.aac (atomic)
    IO/MeetingInputs.swift                    discovery: MeetingAudioFiles + timelines → MicLayout/SystemLayout
    DSP/Biquad.swift                          RBJ biquads (HPF/LPF/BPF), cascade, stateful
    DSP/FrameStats.swift                      20 ms framing, RMS dB, percentiles, adaptive floor, VAD mask
    DSP/Correlation.swift                     vDSP FFT xcorr, GCC-PHAT, normalized xcorr at ±lag
    DSP/FractionalDelay.swift                 linear-interp delay line for drift/sub-sample shifts
    DSP/PeakLimiter.swift                     lookahead limiter
    Channels/ChannelAnalyzer.swift            per-segment stats + pairwise correlation
    Channels/ChannelPlan.swift
    Channels/ChannelCombiner.swift            applies plans → combined mic [Float]
    Alignment/TrackAligner.swift
    Alignment/AlignmentMap.swift
    Echo/EchoCanceller.swift                  protocol + factory (engines in echo_cancellation.md)
    Echo/EchoCancellationStage.swift          drives an engine over segments with aligned reference
    Echo/EchoMetrics.swift                    real-data ERLE estimate
    Leveling/Leveller.swift
    Mixing/MeetingMixer.swift
    Lab/StorageProjection.swift               pure MB/hr projections for policies D1–D4 (used by the lab)
    Lab/ProcessingVariant.swift               variant matrix enumeration + stable IDs (used by the lab)
  Sources/CWebRTCAEC3/ …  Sources/CLocalVQE/ …  (echo_cancellation.md)
  Sources/AudioProcessingTestSupport/ …        (test_signal_kit.md)
  Sources/audioproc-cli/                        process | bakeoff | inspect
  Tests/AudioProcessingTests/
  Vendor/                                       vendored upstream sources (echo_cancellation.md)
```

**Dependencies:**
- `.package(path: "../AudioCapture")`, product `CaptureFiles`;
- `swift-argument-parser` (CLI only);
- Accelerate, AVFoundation, AudioToolbox.

## Constants

```swift
public enum AudioProcessingConstants {
    public static let sampleRate: Double = 16_000      // working + output rate
    public static let frameSamples = 320                // 20 ms analysis frame
    public static let targetSpeechDBFS: Float = -23     // leveller target (speech-active RMS)
    public static let limiterCeilingDBFS: Float = -1
    public static let pipelineVersion = 1
}
```

## Public interface

```swift
public struct MeetingAudioInput: Sendable, Equatable {
    public var files: MeetingAudioFiles          // from CaptureFiles
    public var referenceOverride: URL?           // e.g. system.ref.caf (lab)
    public init(files: MeetingAudioFiles, referenceOverride: URL? = nil)
}

public struct ProcessingOptions: Sendable, Codable, Equatable {
    public enum Echo: String, Sendable, Codable { case off, webRTCAEC3, localVQE, speex }
    public enum ChannelPlanOverride: Sendable, Codable, Equatable { case monoMixOnly, singleChannel(Int) } // 1-based
    public var echoCancellation: Echo            // default = EchoCancellerFactory.defaultKind (bake-off winner)
    public var leveling: Bool = true             // false → plain sum + limiter ("None")
    public var channelPlanOverride: ChannelPlanOverride? = nil
    public var writeProcessedMic: Bool = true
    public var writeReport: Bool = true
    public var returnIntermediates: Bool = false // lab only
    public static let `default`: ProcessingOptions
}

public struct ProcessedMeetingAudio: Sendable {
    public let mix: [Float]                      // 16 kHz mono
    public var duration: TimeInterval { Double(mix.count) / 16_000 }
    public let report: ProcessingReport
    public let intermediates: Intermediates?     // when returnIntermediates
    public struct Intermediates: Sendable {
        public let combinedMic: [Float]          // after channel combine, before AEC
        public let echoCancelledMic: [Float]     // after AEC (== combinedMic where skipped)
        public let leveledMic: [Float]
        public let leveledSystem: [Float]
    }
}

public enum MeetingAudioProcessor {
    public static func process(_ input: MeetingAudioInput,
                               options: ProcessingOptions = .default) async throws -> ProcessedMeetingAudio
}

public enum AudioProcessingError: Error, Equatable {
    case noAudio                                  // both tracks missing/empty
    case decodeFailed(path: String, message: String)
}
```

## Stage 0 — Discovery and decoding

`MeetingInputs.discover(files) -> (MicLayout, SystemLayout)`:
- **`MicLayout`** has three parts:
  - `mono: URL?` (`mic.aac` if it exists and is non-empty);
  - `segments: [MicSegment]` from the timeline, each with `sampleRange` in 24 kHz `mic.aac` frames, `channels`, `device`, and `channelFiles: [Int: URL]` (only files that exist; `channelWriteFailed` truncation is applied);
  - `gaps`.

  With no timeline, there's one segment over the whole file and no channel files.
- **`SystemLayout`** has `url: URL?` (`referenceOverride` takes precedence over `system.aac` **for the reference only**; the mix always uses `system.aac`), plus segments and gaps from the system timeline.
- **Conversions.** 24 kHz timeline samples convert to 16 kHz indices with `round(s × 2 / 3)`.

`AudioFileDecoder.decodeMono16k(url) throws -> [Float]`:
- `AVAudioFile` (ADTS AAC, CAF and WAV are all supported);
- read in 1 s chunks into an `AVAudioConverter` to 16 kHz mono Float32;
- mono-to-mono or stereo-to-mono only. Channel files are mono by construction, and multichannel files are never fed to the converter (the known zeroing pitfall).
- It reserves capacity from `file.length`.

A decode error on `mic.aac` or `system.aac` throws `.decodeFailed`. A decode error on a channel file adds a warning and drops that channel.

## Stage 1 — Channel analysis and combining {#channel-analysis}

For each `MicSegment` with at least 2 usable channel files (or with `channelPlanOverride` set), `ChannelAnalyzer.analyze(segment) -> ChannelPlan.Segment`. Each channel file is decoded at 16 kHz once and streamed through statistics. The full signal is kept only for channels used in pairwise correlation, and for at most 60 s.

**Per-channel statistics:**
- pre-filter with a band-pass from 300 to 3400 Hz (two biquads);
- 20 ms frames; `frameDB = 10·log10(mean(x²) + 1e-12)`;
- `isDead`: overall peak below −100 dBFS (normally already deleted by capture);
- `floorDB`: 10th percentile of `frameDB`;
- `speechDB`: 90th percentile;
- `snrDB = speechDB − floorDB`;
- `activeFrames`: frames where `frameDB > floorDB + 8`.

**Candidates:** channels that are not dead and have `snrDB ≥ 10`. If there are none, use `.single(best)` where best = max `speechDB`, with warning `noConfidentChannel`. If even that is dead, use `mic.aac` for the segment.

**Pairwise correlation** against the reference channel `b` (max `speechDB` among candidates):
- choose up to 60 s of `b`'s active frames, as the 30 highest-energy 2 s windows;
- for each other candidate `c`, compute the normalized cross-correlation of the band-passed signals over those windows at lags in ±80 samples (±5 ms);
- take `ρ = argmax |xcorr|`, `lag`, and `invert = xcorr(lag) < 0`.

**Plan:**
- `correlated` = { c : |ρ_c| ≥ 0.5 and `speechDB_c ≥ speechDB_b − 12` } ∪ {b}. That is, the same acoustic source (array capsules), excluding very weak capsules.
- `independent` = candidates not in `correlated` with `snrDB ≥ 15`. These are different sources, such as a second person's mic.
- Contributions:
  - correlated channels get `gain = 1/√|correlated|`, `lag = lag_c` (relative to b), and `invert`;
  - independent channels get `gain = 1`, lag 0, no inversion.
- **Plan types:** `.single(channel)` when there's exactly one contribution; otherwise `.sum([Contribution])`. `rationale` records the numbers for the report.

**Overrides:**
- `monoMixOnly`: every segment uses `mic.aac`;
- `singleChannel(n)`: `.single(n)` wherever that channel exists, `mic.aac` elsewhere.

**`ChannelCombiner.combine(layout, plans) -> [Float]`:**
- Allocate `combinedMic` at the 16 kHz length of `mic.aac`. If `mic.aac` is missing, use the longest channel-segment end.
- Fill regions with no plan from `mic.aac`.
- For each planned segment:
  - zero the region;
  - for each contribution, decode the channel file and accumulate `gain · (invert ? −1 : 1) · x[i − lag]` into the region at the segment's 16 kHz offset;
  - clamp to the region; channel files shorter than the region leave zeros.
- Decoded channel buffers are released after accumulation.
- At 16 kHz, comb filtering from unaligned array capsules lies above Nyquist (about 8.6 kHz for 2 cm), so integer-lag alignment is enough.

## Stage 2 — Track alignment

`TrackAligner.align(mic: [Float], reference: [Float], micLayout:, systemLayout:) -> AlignmentMap`.

**Segmentation.** Split the timeline at every mic segment boundary, every gap in either track, and every system reconnect or format change, mapped to 16 kHz. The result is `AlignmentMap.Segment`s with `range`.

**Per segment:**
1. **Pre-processing.** Band-pass 300–3400 Hz on both signals. Compute `refActive` frames (reference `frameDB > refFloor + 10` and `> −70 dBFS`).
2. **Windows.** 4 s analysis windows, hop 2 s. Skip a window unless at least 30% of its frames are `refActive`.
3. **Correlation.** For each window, run GCC-PHAT between `mic[w]` and `ref[w − maxLag … w + window]`, where `maxLag = 2.5 s` and `minLag = −0.05 s` (positive means the echo lags the reference). Use FFT length = the next power of two of (window + lag span), with vDSP real FFT.
4. **Per-window estimate.**
   - `lagSamples` = argmax.
   - `psr` (peak-to-sidelobe ratio) = `(peak − mean(sidelobe)) / std(sidelobe)`, where sidelobe means the correlation excluding ±2 ms around the peak.
   - Valid if `psr ≥ 8`.
5. **Segment fit.**
   - If 3 or more windows are valid: robust linear fit `lag(t) = a + b·t` (Theil–Sen over valid windows); `driftPPM = b / 16_000 × 1e6`.
   - If 1–2 are valid: constant `lag = median`, drift 0.
   - If none: `echoDetected = false`.
   - `echoDetected = validWindows / candidateWindows ≥ 0.3 && candidateWindows ≥ 2`.
   - `confidence = median(psr of valid windows)`.

**Output:** `AlignmentMap { segments: [{range, echoDetected, delayAtStart: Double (samples), driftPPM, confidence, validWindows, candidateWindows}] }`.

**Reference provision.** `AlignmentMap.referenceSample(at i) -> Float` returns `ref(i − d(i) + causalMargin)`, where `d(i) = delayAtStart + driftPPM·1e-6·(i − range.lowerBound)` and `causalMargin = 320 samples (20 ms)`. That margin keeps the echo slightly after the provided reference, which both engines expect. Fractional delays use linear interpolation (`FractionalDelay`). Outside the reference bounds it returns 0. The aligned reference is never materialized for the whole file; the echo stage pulls frames.

## Stage 3 — Echo cancellation (driver)

`EchoCancellationStage.run(mic: inout [Float], reference: [Float], map: AlignmentMap, kind) -> [EchoSegmentResult]`.
- If `kind == .off`, or the reference is missing: a no-op, recorded.
- For each segment with `echoDetected`:
  1. create a fresh engine (`EchoCancellerFactory.make(kind)`);
  2. feed `frameSize` frames: `mic[i…]` and `map.referenceSample` for the same indices;
  3. write the output back into `mic` in place, compensating `engine.latency` by delaying writes through a small ring and flushing with zero input at the segment end;
  4. measure `EchoMetrics.estimateERLE(before:after:reference:map:)` on that segment, keeping a copy of the segment's `before` frames only for frames where the reference is active (bounded scratch).
- An engine error mid-segment restores the segment's `before` audio, which is kept in a segment-sized scratch buffer for segments up to 10 minutes. Longer segments are processed in 10-minute sub-blocks with the engine state carried across, and the scratch is per sub-block. A `aecFailed` warning is added.
- Segments without echo are untouched (`skipReason: noEchoDetected`).

**`EchoMetrics.estimateERLE`:**
1. Find echo-dominant frames: `refActive` frames where the normalized correlation between `before` and the aligned reference over that 20 ms frame and its ±1 frame neighbours has |ρ| ≥ 0.3.
2. `ERLE = 10·log10(Σ before² / Σ after²)` over those frames.
3. Report it as `erleEstimateDB` (nil if there are fewer than 50 such frames).

It's labelled "estimate" in the report and the lab.

## Stage 4 — Levelling

`Leveller.level(_ x: inout [Float], segments: [Range<Int>], exclude: [Bool]?) -> LevelingResult` is applied to the mic after AEC and to the system track.

1. **Frames and VAD.** 20 ms frames, `frameDB`, and an adaptive floor: the 10th percentile over a centered 10 s window, computed by a sliding percentile over 500-frame windows, recomputed every 50 frames and interpolated. `speech[f] = frameDB > floor + 8 && frameDB > −85`.
2. **Echo-aware exclusion (mic only).** `exclude[f] = refActive[f] && segmentEchoDetected`. Excluded frames don't count toward loudness. They still receive gain.
3. **Block loudness.** 100 ms blocks (5 frames). `L(block)` = RMS dB over qualifying frames (speech and not excluded) in a centered 6 s window. With fewer than 25 qualifying frames (0.5 s), widen to 30 s. If it's still too few, the block is `nil` and holds the neighbour's gain.
4. **Target gain.** `g(block) = clamp(target − L, −20, +45)` dB.
5. **Smoothing.**
   1. a median filter over 11 blocks (1.1 s);
   2. a symmetric slew limit of 6 dB/s, as a forward pass then a backward pass, taking the min of excess changes;
   3. **no slew across segment boundaries**, because the level legitimately jumps 20–30 dB when the built-in mic switches modes; each segment is smoothed independently.
6. **Apply** per sample, with linear interpolation of the dB gain between block centres converted to linear gain.
7. **Limit** with `PeakLimiter` (lookahead 5 ms, ceiling −1 dBFS, release 50 ms, hard ceiling guaranteed).

**Result:** `LevelingResult { medianGainDB, p10GainDB, p90GainDB, speechLoudnessBeforeDB, speechLoudnessAfterDB, speechFraction }`.

When `options.leveling == false`, skip steps 1–6. The mixer then applies only the limiter to the sum.

## Stage 5 — Mixing

`MeetingMixer.mix(mic: [Float], system: [Float]) -> [Float]`:
- output length = max(lengths), with the shorter padded with zeros;
- the sum is accumulated into the longer buffer in place;
- then `PeakLimiter` (−1 dBFS).

It replaces `AudioMerger`; there are no labels (unused in production).

## Stage 6 — Outputs

- **`ProcessedMicWriter.write(leveledMic, to: files.processedMic)`:** ADTS AAC-LC, 16 kHz mono, 48 kbps, through `ExtAudioFile`. It writes `<name>.tmp` and then `FileManager.replaceItemAt`. On failure: warning `processedMicWriteFailed`; any partial temporary file is removed.
- **`ProcessingReport`:** written as pretty-printed JSON with sorted keys to `files.processingReport`, using the same temporary-file-and-replace pattern.

```swift
public struct ProcessingReport: Codable, Sendable, Equatable {
    public var pipelineVersion: Int
    public var options: ProcessingOptions
    public var inputs: Inputs              // which files found, durations, timeline present
    public var channelPlans: [ChannelPlanReport]   // per mic segment: stats per channel, plan, rationale
    public var alignment: [AlignmentSegmentReport]
    public var echo: EchoReport            // engine kind, per segment: applied/skipReason, erleEstimateDB, rtf
    public var micLeveling: LevelingResult?
    public var systemLeveling: LevelingResult?
    public var warnings: [ProcessingWarning]   // {code, message, segment?}
    public var timings: [String: Double]   // seconds per stage
}
```

Timings are excluded from determinism comparisons.

## Facade orchestration

`MeetingAudioProcessor.process`:
1. Hop to the private queue. Install the cancellation handler.
2. Discover the files.
3. Decode the system track into `system`, then decode the reference: if `referenceOverride` is set, decode it into a separate `reference`; otherwise `reference = system` (shared, no copy).
4. Build `combinedMic` (stage 1).
5. Throw `.noAudio` if both are empty.
6. Run alignment if both tracks exist.
7. Run AEC in place on `combinedMic` (stage 3).
8. If intermediates were requested, copy them.
9. Level the mic, excluding frames per the alignment map. Level the system track. Both in place.
10. Write the processed mic, from the levelled mic buffer and before mixing.
11. Mix into the longer buffer. Free the other.
12. Write the report.
13. Return.

Peak memory is the decoded system track plus `combinedMic`, plus the reference override if set, plus bounded scratch.

## Transcription integration

In `Packages/Transcription/Sources/Transcription/AudioLoading.swift`:

```swift
static func loadAndMerge(micPath: String, systemPath: String) async throws -> MergeResult {
    let files = MeetingAudioFiles(mic: URL(fileURLWithPath: micPath), system: URL(fileURLWithPath: systemPath))
    do {
        let processed = try await MeetingAudioProcessor.process(.init(files: files))
        return MergeResult(samples: processed.mix, duration: processed.duration)
    } catch AudioProcessingError.noAudio {
        throw TranscriptionError.invalidInput("At least one audio stream (mic or system) must contain non-zero samples")
    } catch let AudioProcessingError.decodeFailed(path, message) {
        throw TranscriptionError.invalidInput("Failed to load audio from \(path): \(message)")
    }
}
```

- Existing file-existence checks (missing files → `invalidInput`) are kept at the top for parity with today's error messages.
- `loadSamples(fromPath:)` is unchanged; other code may still use it.
- `InProcessTranscriptionEngine.loadAndMergeAudio` and `SpeakerAnalyzer.analyze` add `await`.
- `AudioMerger.swift` and `MergeTests.swift` are deleted.

## CLI (`audioproc-cli`)

| Command | Purpose |
|---|---|
| `process <meetingDir> [--mic mic.aac --system system.aac] [--echo off|webRTCAEC3|localVQE] [--no-leveling] [--reference path] [--mono-only|--channel N] [--out dir]` | Runs the pipeline. Writes `mix.wav` (16 kHz Float32 WAV), `mic.processed.aac` and the report into `--out` (default: the meeting dir, for the processed file and report; `mix.wav` only with `--out`). Prints a summary. |
| `bakeoff [--engines …] [--out report.md] [--json out.json]` | See [echo_cancellation.md](./echo_cancellation.md#bake-off). |
| `inspect <meetingDir>` | Prints the parsed timelines, segments and channel files with their durations. |

## Test plan (`AudioProcessingTests`)

Scenarios come from `AudioProcessingTestSupport`. Durations are 10–20 s at 16 kHz unless noted.

| Test | Verifies |
|---|---|
| `decoder_aacAndWav_to16kMono_lengthAndContent` | A written AAC round-trip decodes to the expected length (±1 AAC frame) with correlation above 0.95 |
| `frameStats_percentilesAndVAD_onSpeechPlusNoise` | VAD recall above 0.9 on fixture speech at −45 dBFS with −70 dBFS noise |
| `channels_interfaceMicOnInput2_picksInput2` | ch1 dead, ch2 speech, ch3 preamp noise → `.single(2)` |
| `channels_builtInArray_inPhase_sumsAll` | 3 correlated capsules (lags 0/1/0, gains 0/−3/−1 dB) → `.sum` of 3, gains 1/√3 |
| `channels_polarityFlip_inverted` | Channel 2 inverted → contribution has `invert = true`; combined SNR ≥ best single + 3 dB |
| `channels_weakCapsule_excluded` | A capsule 15 dB down is excluded |
| `channels_twoPeople_independent_bothIncluded` | Uncorrelated speech on ch1 and ch2 → both in the plan with gain 1 |
| `channels_segmentFlip_usesMonoForSingleChannelRegions` | Timeline with segments 1ch/3ch/1ch → combined equals `mic.aac` in the 1ch regions and the plan in the 3ch region |
| `channels_overrides_monoMixOnly_singleChannel` | Override behaviour |
| `aligner_findsDelay_60ms_and_800ms` | Lag within ±1 ms; `echoDetected` |
| `aligner_drift100ppm_fitsDrift` | `driftPPM` within ±20 ppm over 60 s |
| `aligner_noEcho_headphones_notDetected` | Independent mic and system → `echoDetected = false` |
| `aligner_gapSplitsSegments_reestimates` | A delay change at a gap is tracked per segment |
| `echoStage_off_isIdentity` | Bit-identical passthrough |
| `echoStage_skipsSegmentsWithoutEcho` | Untouched audio; skip reason recorded |
| `echoStage_engineError_restoresSegment` | A fake engine that throws mid-segment → original audio and an `aecFailed` warning |
| `echoStage_latencyCompensation` | A fake engine with latency 64 → output sample-aligned |
| `erleEstimate_matchesGroundTruth_within3dB` | On S1-type data with a known residual |
| `leveller_bringsQuietSpeechToTarget` | −50 dBFS speech → speech loudness −23 ± 2 dBFS |
| `leveller_levelJumpAtSegmentBoundary_noSlewAcross` | A +25 dB step at a boundary is handled per segment; no overshoot above −1 dBFS |
| `leveller_echoExclusion_gainNotDrivenByEcho` | Mic with loud echo and quiet near-end → gain targets near-end speech (near-end loudness −23 ± 3) |
| `limiter_neverExceedsCeiling` | Random bursts → peak ≤ −1 dBFS + 0.01 dB |
| `mixer_padsShorter_andLimits` | Lengths and ceiling |
| `pipeline_endToEnd_syntheticMeeting_realAACFiles` | Folder with `mic.aac`, 3 channel files, timelines and `system.aac` (all real AAC written by the test kit) → the mix has user-to-remote loudness within ±3 dB, an ERLE estimate ≥ 10 dB with the default engine, the report and processed mic exist |
| `pipeline_legacyFolder_noTimeline_vpioStyle` | Only `mic.aac` + `system.aac` → succeeds; one segment |
| `pipeline_degradation_missingSystem_missingMic_bothMissing` | Mic-only, system-only, and `.noAudio` |
| `pipeline_determinism_twoRunsIdentical` | Identical mix bytes and report (excluding timings) |
| `pipeline_cancellation_throwsCancellationError` | Cancellation is honoured within 1 s of audio processing time |
| `pipeline_leveling_off_isSumPlusLimiter` | The "None" option |

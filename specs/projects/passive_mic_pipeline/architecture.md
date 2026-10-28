---
status: complete
---

# Architecture: Passive Mic Pipeline

Behaviour is defined in [functional_spec.md](./functional_spec.md). Evidence is in the [research summary](../../research/builtin-mic-voice-processing/summary.md). This doc covers topology, file contracts, data flow, cross-cutting rules and build changes. Per-component designs:

| Component | Doc |
|---|---|
| Passive capture (AudioCapture changes, `CaptureFiles` target) | [components/capture_passive_mic.md](./components/capture_passive_mic.md) |
| AudioProcessing core (decode, channel plan, alignment, levelling, mixing, facade, report, CLI) | [components/audio_processing.md](./components/audio_processing.md) |
| Echo cancellation engines, packaging and bake-off | [components/echo_cancellation.md](./components/echo_cancellation.md) |
| Test-signal kit and metrics | [components/test_signal_kit.md](./components/test_signal_kit.md) |
| Mic Pipeline Lab (ManualTestApp) | [components/mic_pipeline_lab.md](./components/mic_pipeline_lab.md) |

There's no separate `ui_design.md`. The only UI is the internal lab tab, designed in its component doc, and the app's user-facing UI doesn't change.

---

## 1. Topology

```
                         ┌──────────────────────────── Packages/AudioCapture ───────────────────────────┐
                         │  CaptureFiles (new target, pure Foundation)                                  │
                         │    MeetingAudioFiles  (naming)   CaptureTimeline (JSONL schema, writer, reader)│
                         │        ▲                                                                       │
                         │  AudioCapture (existing target) ──depends on──► CaptureFiles                 │
                         │    PassiveMicCaptureEngine (new, default)   VoiceProcessingMicCaptureEngine  │
                         │    MicCaptureSession (multichannel)         LiveSystemCaptureEngine (+timeline)│
                         └──────────────────────────────────────────────────────────────────────────────┘
                                         ▲ CaptureFiles only
┌──────────────────────────── Packages/AudioProcessing (NEW) ──────────────────────────────────────────┐
│  AudioProcessing (Swift; Accelerate, AVFoundation for decode/encode)                                 │
│     MeetingAudioProcessor facade ─► Decoder ─► ChannelCombiner ─► TrackAligner ─► EchoCancellation   │
│                                       ─► Leveller/Limiter ─► Mixer ─► ProcessedMicWriter + Report     │
│  CWebRTCAEC3 (vendored C++ + C shim)   CLocalVQE (vendored C/C++ + ggml + GGUF resource)             │
│  CSpeexDSP (only if both candidates fail the packaging gate)                                         │
│  AudioProcessingTestSupport (speech fixtures, simulators, ground-truth metrics, scenarios)           │
│  audioproc-cli (process | bakeoff | inspect)                                                         │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘
          ▲                                            ▲                              ▲
 Packages/Transcription                       Packages/BiscottiKit            ManualTestApp
  AudioLoading → MeetingAudioProcessor         MeetingDetailUI uses            Mic Pipeline Lab tab
  (AudioMerger removed)                        CaptureFiles for playback        (AudioCapture + AudioProcessing)
  └─ hosted in XPCServices/BiscottiTranscriber  ManualTestKit: mic_pipeline script
```

**Dependency rules**
- `AudioCapture` never depends on `AudioProcessing`. `AudioProcessing`'s library and CLI targets never link capture code; they share only the `CaptureFiles` target, which holds the on-disk contract. One exception: `AudioProcessingTests` also depends on the `AudioCapture` product for a single capture-parity test (see [test_signal_kit.md](./components/test_signal_kit.md#consumers-and-dependency-wiring)).
- `AudioProcessing` depends only on `AudioCapture`'s `CaptureFiles` product, Apple frameworks (Foundation, Accelerate, AVFoundation, AudioToolbox), vendored C/C++, and `swift-argument-parser` (CLI only).
- `Transcription` adds a dependency on `AudioProcessing`. `BiscottiKit` adds the `CaptureFiles` product, which comes from the `AudioCapture` package it already depends on. `ManualTestApp` adds the `AudioProcessing` package.

## 2. File layout

These are the on-disk contract between capture, processing and playback. All names come from `MeetingAudioFiles` in `CaptureFiles`; no other code hard-codes them except the existing `mic.aac` and `system.aac` creation in `RecordingController`, which stays unchanged.

The names below assume today's `mic.aac` / `system.aac`. Derivation rules (`stem` = file name without extension):

| Artifact | Name | Written by | Lifetime |
|---|---|---|---|
| Mic mono track | `mic.aac` (from `CapturePaths.micAAC`) | capture | permanent |
| System track | `system.aac` (from `CapturePaths.systemAAC`) | capture | permanent |
| Mic channel file | `<micStem>.seg<K>.ch<N>.aac` (K, N are 1-based) | capture | per storage policy (D1–D4) |
| Mic timeline | `<micStem>.timeline.jsonl` | capture | permanent |
| System timeline | `<systemStem>.timeline.jsonl` | capture | permanent |
| PCM system reference | `<systemStem>.ref.caf` | capture, only when `writeSystemPCMReference` is on | lab only, unless Checkpoint 1 decides otherwise (F5) |
| Processed mic | `<micStem>.processed.aac` | processing | regenerated on every processing run |
| Processing report | `processing.report.json`, in the mic file's directory | processing | regenerated on every processing run |

`MeetingAudioFiles` API, in `CaptureFiles`:

```swift
public struct MeetingAudioFiles: Sendable, Equatable {
    public let mic: URL
    public let system: URL
    public init(mic: URL, system: URL)
    /// Convenience for consumers that only know the mic path: system = sibling "system.aac".
    public init(micSiblingOf mic: URL)
    public var directory: URL { get }                 // mic.deletingLastPathComponent()
    public var micTimeline: URL { get }
    public var systemTimeline: URL { get }
    public var systemPCMReference: URL { get }
    public var processedMic: URL { get }
    public var processingReport: URL { get }
    public func micChannelFile(segment: Int, channel: Int) -> URL   // 1-based
    /// Returns processedMic if it exists on disk, else mic.
    public func preferredPlaybackMic(fileManager: FileManager = .default) -> URL
}
```

## 3. Timeline sidecar (JSON Lines)

The timeline is written by capture on writer threads (never on real-time threads) and read by processing and the lab. Each line is one JSON object with a `type` discriminator. The schema is versioned through the `start` event.

```jsonc
{"type":"start","version":1,"track":"mic","hostTime":51234.567891,"outputSampleRate":24000,"micMode":"passive"}
{"type":"segmentStart","segment":1,"sample":0,"hostTime":51234.567891,
 "device":{"uid":"BuiltInMicrophoneDevice","name":"MacBook Pro Microphone","transport":"bltn","isBuiltInMic":true},
 "channels":3,"capturedChannels":3,"inputSampleRate":48000,
 "channelFiles":["mic.seg1.ch1.aac","mic.seg1.ch2.aac","mic.seg1.ch3.aac"]}
{"type":"gap","sample":1440000,"frames":7200,"reason":"hostTimeGap"}
{"type":"reconnect","sample":1447200,"hostTime":51294.61}
{"type":"segmentEnd","segment":1,"sample":2880000,"deadChannels":[3]}
{"type":"segmentStart","segment":2,"sample":2880000,"hostTime":51354.1,"device":{...},"channels":1,"capturedChannels":1,"inputSampleRate":48000,"channelFiles":[]}
{"type":"leadingSilence","frames":3120}            // system track only
{"type":"stop","sample":43200000}
```

Rules:
- `sample` is the frame index in that track's own AAC timeline (24 kHz output frames written so far, including silence).
- Frame 0 of a channel file corresponds to its segment's `segmentStart.sample` in `mic.aac`.
- The mic track gets a `segmentStart` on every new device format, single-channel ones included. `channelFiles` is empty when the segment is single-channel or the channel-file policy is off.
- The system track uses `start`, `leadingSilence`, `gap`, `reconnect`, `segmentStart` (format change, `channelFiles` always empty) and `stop`.
- **Readers must tolerate:**
  - unknown `type` values (skip them);
  - a malformed final line (crash mid-write: ignore it);
  - a missing `stop` (crash: the track ends at the file's decoded length);
  - a missing file (older recordings: treat as one segment covering the whole file).
- Swift types live in `CaptureFiles`: `CaptureTimelineEvent` (an enum with associated structs, using custom `Codable` on `type`), `CaptureTimelineWriter` (append-only `FileHandle`, `synchronize()` on stop), and `CaptureTimelineReader` (returns `CaptureTimeline` with derived `segments` and `gaps`).

## 4. Data flow

### Recording time (AudioCapture)

```
AVAudioEngine inputNode (no VP, no output) ──tap (RT)──► MicCaptureSession ring (≤16 ch, prealloc)
     writer thread: per entry ─► format generation changed? → segmentEnd/segmentStart (+timeline, channel writers)
                              ─► live-mask update, mean-of-live → resample 48→24 → mic.aac (gap fill as today)
                              ─► per live/pending channel → resample → mic.segK.chN.aac (same gap fill)
                              ─► levels (RMS, per-channel peak, silence tracker) → atomics
Core Audio process tap ─IOProc─► LiveSystemCaptureEngine writer ─► system.aac (+ leading silence, gap fill)
                                                                 ─► system.timeline.jsonl
                                                                 ─► system.ref.caf (lab option)
```

### Transcription time (Transcriber XPC)

```
TranscriptionService → engine.processAudio(micPath, systemPath, vocab)       [unchanged API]
  InProcessTranscriptionEngine / SpeakerAnalyzer / voiceprint backfill
    AudioLoading.loadAndMerge(micPath:systemPath:)  ── now ──►  MeetingAudioProcessor.process(...)
        decode → combine channels → align → AEC → level → mix (16 kHz) ─► WhisperKit + SpeakerKit
        side outputs: mic.processed.aac, processing.report.json
```

`AudioLoading.loadAndMerge` keeps its signature and return type (`samples`, `duration`), so every call site stays the same. It becomes `async` because the processor is async; its three call sites are already in async contexts. `AudioMerger.swift` and `MergeTests.swift` are deleted.

### Playback (app)

`MeetingDetailViewModel` builds its playback mic URL with `MeetingAudioFiles(micSiblingOf: micURL).preferredPlaybackMic()`. There's no DataStore schema change: the processed file is a derived sibling, deleted along with the meeting directory.

## 5. Concurrency and real-time rules

- **Capture:** the existing rules hold:
  - the tap callback does no allocation and no I/O, and takes the tap lock with `lockIfAvailable` only;
  - everything else happens on the writer thread;
  - ring slots are preallocated (sizes in the capture component doc);
  - timeline writes, file opens and closes, and channel-file deletion happen only on the writer thread or the engine queue.
- **Processing:**
  - `MeetingAudioProcessor.process` is `async throws`. It runs its CPU-bound work on a private serial `DispatchQueue` (QoS `.userInitiated`) through a checked continuation, so it never blocks the Swift cooperative pool for minutes.
  - Cancellation is cooperative: a `withTaskCancellationHandler` sets an atomic flag, which is checked between stages and every 10 s of audio inside loops. When set, the processor throws `CancellationError`.
  - Echo-canceller instances are not `Sendable`. Each is created, used and destroyed inside one processing run on that queue.

## 6. Error handling and logging

| Layer | Strategy |
|---|---|
| Capture | Unchanged: engine errors propagate as `CaptureError`; write errors are recorded and surfaced after `stop()`. Timeline write failures are logged once and never stop audio capture. Channel-file write failures are recorded per channel: that channel's file is abandoned, `mic.aac` continues, and a `channelWriteFailed` event goes to the timeline (best effort). |
| Processing | Graceful degradation per the functional spec, F2.4. Each skipped stage adds a `ProcessingWarning` (code + message) to the report. Only both tracks being missing or empty throws (`AudioProcessingError.noAudio`). `Transcription` maps that to `TranscriptionError.invalidInput`, as today. Unexpected internal errors (for example a decoder failure on `mic.aac`) throw `AudioProcessingError.decodeFailed(url:underlying:)`, which `Transcription` also maps to `invalidInput`. |
| Logging | `os.Logger` with subsystem `net.scosman.biscotti.audioprocessing` and categories `Pipeline`, `Channels`, `Alignment`, `Echo`, `Leveling`. One summary line per stage at `.notice` level, with numeric values `privacy: .public`, following the hardware debugging workflow's log rules. Capture uses the existing `net.scosman.biscotti.audiocapture` subsystem, with new categories `PassiveMic` and `Timeline`. |

## 7. Build, CI and repo changes

- `Packages/AudioProcessing/Package.swift`:
  - swift-tools 6.1, macOS 15, Swift 6 language mode;
  - `-warnings-as-errors` on the Swift targets (repo convention);
  - vendored C/C++ targets compiled with `-O2` (via `unsafeFlags`) so debug `swift test` stays fast, with warnings suppressed for vendored code only (`-w`).
- `Makefile`:
  - add `Packages/AudioProcessing` to `PACKAGES`;
  - new target `bakeoff`, which runs the release CLI and writes the report (not part of `ci`, `test` or `precommit-checks`);
  - new target `process-meeting DIR=…`, a convenience wrapper around the CLI.
- `hooks_mcp.yaml`: expose `bakeoff`, mirroring the existing tool definitions.
- `.swiftlint.yml` and `.swiftformat`: exclude `Packages/AudioProcessing/Vendor/**`.
- CI (`ci.yml`): no workflow change is needed, because `make ci` iterates over `PACKAGES`. Package-tier build time grows with the vendored C++; this is acceptable and should be noted in the PR.
- `THIRD_PARTY_NOTICES.md` (create if absent): WebRTC (BSD-3 + PATENTS), abseil (Apache-2.0), LocalVQE (Apache-2.0, plus attribution for its CC BY 4.0 training data), ggml (MIT), and SpeexDSP (BSD) if it's used. Each vendored directory carries its upstream `LICENSE` and a `VENDORED.md` with: upstream URL, version or commit, tarball SHA-256, and local modifications.
- `CLAUDE.md`:
  - add `Packages/AudioProcessing` to the package map and the manual-test staleness rule (prefix `mp_*`, which also applies to changes in `AudioCapture`'s passive path and the lab);
  - add the `bakeoff` target to the Makefile table;
  - update the "Current stage" paragraph and the custom-vocab/argmax notes only where this project changes them.
- Research docs (Phase 6): `specs/research/audio/README.md` records that production mic capture is passive (no VPIO), with links to this project and the research folder. `mic_capture_level_findings.md` gets a short "superseded by" note pointing to the research summary; the old text stays, since it's a point-in-time record.

## 8. Testing strategy (summary)

| Layer | What | Where |
|---|---|---|
| Unit: capture | Multichannel session with synthetic buffers through the real AAC 48→24 kHz path. Segments, dead-channel deletion, gap fill on channel files, timeline events, levels, built-in detection, recorder option plumbing with fakes. | `AudioCaptureTests` |
| Unit: contract | Timeline writer → reader round-trip, tolerance of crash-truncated or unknown lines, `MeetingAudioFiles` naming. | `AudioCaptureTests` (CaptureFiles) |
| Unit: DSP | Every processing stage on generated real-speech scenarios with ground truth (see the test-signal kit). | `AudioProcessingTests` |
| Integration | `MeetingAudioProcessor` end-to-end on synthetic meeting folders written as real AAC files with timelines. Degradation cases. Determinism (two runs give identical bytes). | `AudioProcessingTests` |
| Transcription | `loadAndMerge` uses the processor; old-style folders (no timeline) still work. AI tests (`make test-ai`) are unchanged and must still pass on hardware. | `TranscriptionTests` |
| Bake-off | Scenario matrix S1–S7 per engine, with the report committed. | `audioproc-cli bakeoff` |
| Manual | `mp_*` in the lab (Checkpoint 1); `ac_*` and `tx_*` re-run (Checkpoint 2). | ManualTestApp |

Test speed budget: `AudioProcessingTests` add at most about 60 s to `make test` on CI. The long scenario matrix belongs to the bake-off, not to unit tests.

## 9. Compatibility and migration

- Existing meetings have no timeline and no channel files: processing treats them as single-segment mono. VPIO-era mics usually show no echo, so AEC is skipped and they're levelled and mixed.
- `XPCProcessRequest`, `TranscriptionEngine` and `TranscriptResult` are unchanged, so the XPC service and app versions stay compatible.
- `CaptureState` gains fields with defaults. `CaptureState.idle` is updated. Existing app consumers compile without changes.
- `AudioRecorder.live(encoder:)` stays as a convenience. A new overload, `live(encoder:options:)`, takes `CaptureOptions`.

## 10. Risks and mitigations

| Risk | Mitigation |
|---|---|
| An input-only `AVAudioEngine` (no output node touched) fails to start or deliver on some device | Detected in the lab (`mp_*` steps) and the `ac_*` re-run. Fallback design, kept in reserve: replace the engine's backend with a HAL IOProc on the default input device (the same pattern as `LiveSystemCaptureEngine`), behind the same `MicCaptureSession` interface. No other component changes. |
| Vendoring AEC3 (C++ plus an abseil subset) or LocalVQE (plus ggml) into SPM is harder than expected | The F3.1 packaging gate is time-boxed in Phase 3. Drop a failing engine with the reason recorded. SpeexDSP is the last-resort fallback. |
| The AAC-coded reference caps echo cancellation | Measured at Checkpoint 1 (F5). The mitigation is ready: production `system.ref.caf`. |
| Nonlinear laptop-speaker echo leaves residual echo | The bake-off's S2 scenario plus real lab recordings. LocalVQE's neural mask handles nonlinearity; AEC3 has a residual suppressor. |
| A resource bundle (LocalVQE GGUF) isn't found inside the XPC service | `Bundle.module` lookup is covered by a Phase 6 app-build check (`make build-app`) and the `tx_*` re-run. If LocalVQE loses the bake-off, the risk disappears. |
| Memory for long meetings | In-place stages, at most 2 full-length buffers (functional spec, F2.6). A 3-hour meeting needs about 1.4 GB, about 2/3 of today's merge. |
| Thresholds in the bake-off are guesses | The report records actuals. The selection rule still produces a choice, and Checkpoint 1 reviews it. |

## 11. Execution prerequisites (for autonomous implementation)

Every phase needs a macOS compile and test loop. The cloud agent container is Linux with no Swift, so one of these must be available before `/spec implement`:
- the owner's Mac connected through Remote Control, so `make test`, `make build-app` and the `hooks-mcp` tools run locally; or
- a draft PR for this branch, so macOS CI (`make ci` and `build-app`) validates each push.

Hardware-dependent steps (the lab, `mp_*`, `ac_*`, `tx_*`) are always done by a human at the two checkpoints.

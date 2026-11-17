---
status: complete
---

# Architecture: Apple STT Validation

The functional spec (`functional_spec.md`) defines what the experiment does. This doc defines how. The component docs hold the detail:

- [`components/prep.md`](components/prep.md): the `sttlab` CLI on the home Mac. It does store reading, selection, consent, the bundle, WhisperKit, SpeakerKit and the reference (OpenRouter).
- [`components/runner.md`](components/runner.md): the runner app (Apple SpeechTranscriber) and its packaging.
- [`components/analyze.md`](components/analyze.md): normalization, alignment, metrics, speaker alignment and the report.

Decisions were made without user Q&A (the user asked for an autonomous run). Each decision has a short reason. Section 9 lists the decisions that change or add to the functional spec.

## 1. Language and packaging

**All Swift, one SPM package: `experiments/STTLab/`.**

- The speaker-alignment step must call SpeakerKit `addSpeakerInfo` (Swift), and prep must call the production `AudioMerger` and WhisperKit (Swift). Python would add a second toolchain and a re-implementation of the alignment. A re-implementation is not "the production alignment path" (spec §5.5).
- Analysis must stay easy to change (spec §2). The analysis logic is a pure Swift target with fast unit tests, and `sttlab analyze` re-runs in seconds on saved data.

```
experiments/STTLab/
├── Package.swift
├── NOTES.md                      # how to run + findings (spec §6)
├── .gitignore                    # build/, *.wav, *.aac, any data
├── scripts/package_runner.sh     # builds STTLabRunner.app (ad-hoc signed) + zip
├── Sources/
│   ├── STTLabCore/               # shared schemas + utilities. No argmax, no DataStore.
│   ├── STTLabAnalysis/           # pure analysis logic. Depends on STTLabCore only.
│   ├── STTLabHome/               # home-Mac engines + store + OpenRouter. Depends on
│   │                             #   STTLabCore, Transcription, WhisperKit, SpeakerKit, DataStore.
│   ├── sttlab/                   # CLI (ArgumentParser). Depends on STTLabHome + STTLabAnalysis.
│   └── STTLabRunner/             # SwiftUI app (executable). Depends on STTLabCore only.
└── Tests/
    ├── STTLabCoreTests/
    ├── STTLabAnalysisTests/
    └── STTLabHomeTests/
```

`Package.swift`:

- `// swift-tools-version: 6.0` (argmax v1.0.0 needs 6.0). Platform `.macOS(.v15)`. `swiftLanguageModes: [.v6]`.
- Dependencies:
  - `.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0")`. This is **exact** so the experiment matches production (Package.resolved of `Packages/Transcription` pins 1.0.0). `Transcription`'s `from: "1.0.0"` accepts it.
  - `.package(name: "Transcription", path: "../../Packages/Transcription")`. For the production `AudioMerger`.
  - `.package(name: "BiscottiKit", path: "../../Packages/BiscottiKit")`. Only the `DataStore` product is used.
  - `.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")`.
- No `-warnings-as-errors` (this is an experiment; it is not linted either).
- `STTLabRunner` links only `STTLabCore` and system frameworks (SwiftUI, AppKit, Speech, AVFoundation). The app stays small and has no model or network code.

### Build and test integration

Agents cannot run `swift build` in the Bash sandbox, and `hooks-mcp` runs only fixed `make` targets. So:

- `Makefile`: add `EXPERIMENT_PACKAGES := experiments/STTLab`. The `build` and `test` loops cover `$(PACKAGES)` and also `$(EXPERIMENT_PACKAGES)`, **but not when `CI` is set** (GitHub Actions sets `CI=true`). Use `ifndef CI` to define a `LOCAL_PACKAGES` list. CI time does not change. `clean` also removes `experiments/STTLab/.build`.
- `hooks_mcp.yaml`: add `build_sttlab` (`swift build --package-path experiments/STTLab`) and `test_sttlab` (`swift test --package-path experiments/STTLab`), with the same `tail -n 400` + `pipefail` pattern and a 600 s timeout. New sessions get them. The current session uses `build`/`test`.
- `NOTES.md` says: remove `EXPERIMENT_PACKAGES` from the Makefile when the experiment ends.
- Not linted: `LINT_PATHS` does not include `experiments/` (same as the earlier experiments).

## 2. Machines, folders, data flow

```
HOME MAC                                                          RUNNER MAC
sttlab select ─► selection.json (user edits)
sttlab confirm ─► selection.json confirmed + hash
sttlab bundle ─► bundle/ (WAV + meta + manifest + README) ── AirDrop ──► STTLabRunner.app
               ─► home/source/ (aac copies, private mapping)                 │
sttlab whisper / diarize / reference (or: sttlab home-run)                   ▼
               ─► home/whisper, home/diarization, home/reference     <bundle>-results/
sttlab analyze --results <path> ◄────────────────────────── AirDrop ◄───────┘
               ─► report/report.md, report/metrics.json, report/transcripts/
```

**Workspace** (home Mac): default `~/STTLabData/<workspace-name>/`, set with `--workspace <path>` on every command. It is outside the repo (spec §8). Layout:

```
<workspace>/
  selection.json                 # proposal → edited → confirmed
  bundle/                        # the ONLY thing that goes to the runner Mac
    manifest.json
    README.txt
    meetings/<mid>/audio.wav     # merged mono 16 kHz Float32 WAV (production AudioMerger)
    meetings/<mid>/meta.json
  home/                          # never leaves the home Mac
    source/<mid>/mic.aac, system.aac, source.json   # source.json = real meeting UUID, title, date
    whisper/<mid>.json           # status + run info + raw [TranscriptionResult]
    diarization/<mid>.json       # status + run info + serialized DiarizationResult
    reference/<mid>/plan.json, chunk_NNN.response.json, chunk_NNN.meta.json, status.json
    reference/probe/...
    logs/<command>-<timestamp>.log
  report/                        # analyze output (re-generated each run)
```

**Runner results:** `<bundle parent>/<bundle folder name>-results/` by default, or a folder the user picks:

```
<results>/
  run.json                       # one entry per runner session (machine, OS, locales)
  log.txt                        # appended
  meetings/<mid>/apple.json      # one per meeting, written when that meeting ends
```

**Meeting ids:** `m01`…`mNN`, assigned at `confirm`. The bundle and the results contain only these ids, durations, speaker counts, language and locale. Titles, dates and real UUIDs stay in `home/source/<mid>/source.json`.

## 3. Shared data model (`STTLabCore`)

All files are JSON: `JSONEncoder` with `.prettyPrinted, .sortedKeys`, and ISO-8601 dates. Every top-level file type has `schemaVersion: Int` (start at 1). Writes are atomic (write `<name>.tmp`, then `FileManager.replaceItemAt`/rename).

```swift
public enum SchemaVersions { public static let bundle = 1; public static let appleResult = 1; /* … */ }

public struct BundleManifest: Codable, Sendable {
    public var schemaVersion: Int          // == SchemaVersions.bundle
    public var bundleID: UUID
    public var createdAt: Date
    public var toolVersion: String         // STTLabCore.toolVersion, e.g. "1.0"
    public var meetings: [String]          // mids in order
}

public struct MeetingMeta: Codable, Sendable {
    public var meetingID: String           // "m01"
    public var durationSeconds: Double     // merged audio duration
    public var sampleRate: Double          // 16000
    public var speakerCount: Int           // from the existing Biscotti transcript
    public var transcriptLanguage: String  // from the existing transcript, e.g. "en"
    public var appleLocale: String         // e.g. "en_US" (from selection.json)
    public var audioFile: String           // "audio.wav"
    public var audioSHA256: String         // integrity check on the runner
}

public struct MachineInfo: Codable, Sendable {   // filled by MachineInfo.current()
    public var hostModel: String           // sysctl hw.model
    public var chip: String                // sysctl machdep.cpu.brand_string
    public var memoryBytes: UInt64         // ProcessInfo.physicalMemory
    public var osVersion: String           // ProcessInfo.operatingSystemVersionString
    public var osBuild: String             // sysctl kern.osversion
}

public struct MemoryReport: Codable, Sendable {
    public var processPeakFootprintBytes: UInt64?     // our process (phys_footprint), max over samples
    public var processLifetimePeakBytes: UInt64?      // TASK_VM_INFO ledger_phys_footprint_peak, at end
    public var sampleIntervalSeconds: Double
    public var sampleCount: Int
    public var systemProcesses: [ProcessMemory]       // runner only; empty on home
    public var systemProcessesNote: String?           // e.g. "unavailable: EPERM for pid 412 (localspeechrecognition)"
}
public struct ProcessMemory: Codable, Sendable { public var name: String; public var pid: Int32
    public var peakFootprintBytes: UInt64; public var lifetimeMaxFootprintBytes: UInt64? }

public struct ErrorInfo: Codable, Sendable {      // from any Error
    public var domain: String; public var code: Int
    public var description: String; public var debugDescription: String
    public init(_ error: any Error)               // uses NSError bridging + String(reflecting:)
}

public enum TimeSpan { }  // helpers: TimedRun { start: Date; end: Date; wallSeconds: Double }
```

Utilities in `STTLabCore`:

- `JSONFiles.write<T: Encodable>(_:to:)` (atomic) and `JSONFiles.read<T: Decodable>(_:from:)`.
- `WAVFile.writeFloat32Mono16k(samples:to:)` and `WAVFile.readFloat32Mono(url:) -> (samples: [Float], sampleRate: Double)`. Uses `AVAudioFile`, settings `kAudioFormatLinearPCM`, 16000 Hz, 1 channel, 32-bit float, `.pcmFormatFloat32`. `WAVFile.int16WAVData(samples:range:) -> Data` builds an in-memory 16-bit PCM WAV (44-byte RIFF header + clamped, rounded `Int16` samples) for the reference upload.
- `SHA256File.hex(url:)` using CryptoKit, streamed in 1 MB blocks.
- `MemorySampler` (actor): `start(interval: 0.5, watchSystemProcesses: Bool)`, `stop() -> MemoryReport`. Our footprint: `task_info(mach_task_self_, TASK_VM_INFO)` → `phys_footprint`. System processes: at each sample, list processes with `proc_listallpids` and `proc_name`, keep names that contain `speech` (case-insensitive), and read `proc_pid_rusage(pid, RUSAGE_INFO_V4)` → `ri_phys_footprint`, `ri_lifetime_max_phys_footprint`. If `proc_pid_rusage` fails, record the errno in `systemProcessesNote` and continue.
- `MachineInfo.current()` (sysctl by name).
- `RunLog`: appends timestamped lines to a log file and echoes them to stdout (CLI) or to an observer closure (app).

Engine-specific schemas (Whisper, diarization, reference, Apple) are in the component docs. `AppleMeetingResult` is in `STTLabCore`, because both the runner (writer) and analyze (reader) need it.

## 4. Engines and settings (fidelity to production)

| Engine | Where | Input | Settings |
|---|---|---|---|
| WhisperKit | `sttlab whisper` | `audio.wav` → `AudioProcessor.loadAudioAsFloatArray(fromPath:)` | Mirrors `MethodResolver.resolveV1` + `InProcessTranscriptionEngine`: model `openai_whisper-large-v3-v20240930_626MB`, repo `argmaxinc/whisperkit-coreml`, `downloadBase` = `~/Library/Application Support/Biscotti` (reuses the app's models), `DecodingOptions(wordTimestamps: true)` and nothing else. `transcribe(audioArray:decodeOptions:)`. |
| SpeakerKit | `sttlab diarize` | same samples | `PyannoteConfig(downloadBase: <same>.path, download: true, load: false, verbose: false)`, `diarize(audioArray:)`, default options. |
| Reference | `sttlab reference` | 16-bit PCM WAV chunks, cut from the same samples | `microsoft/mai-transcribe-2`, `verbose_json`, `["word","segment"]`, `language` from the locale, `provider: {zdr: true}`. |
| Apple | runner app | `audio.wav` through `AVAudioFile` | `SpeechTranscriber(locale:transcriptionOptions: [], reportingOptions: [.alternativeTranscriptions], attributeOptions: [.audioTimeRange, .transcriptionConfidence])`, `analyzeSequence(from:)` + `finalizeAndFinish(through:)`. |

The merged WAV is Float32. So WhisperKit and SpeakerKit get the same samples that production gives them (production passes the merged `[Float]` in memory). Apple reads the same file. The reference gets 16-bit chunks of the same samples (the upload format; 16-bit quantization is about −96 dB and has no effect on a cloud model). 1 hour of Float32 at 16 kHz is about 230 MB, so the full bundle is about 1.7 GB. AirDrop handles that.

The production constants are copied into `STTLabHome/ProductionSettings.swift`, because `MethodResolver` is internal. A comment names the source file. A unit test asserts the copied model name equals the string in `MethodResolver.swift` (the test reads the source file through `#filePath`), so drift is caught.

## 5. Speaker alignment (spec §5.5)

This runs in `sttlab analyze` (the `STTLabHome/SpeakerAlignment.swift` part), not in prep. The Apple words arrive later, and all engines must use one diarization.

1. Rebuild `DiarizationResult` from `home/diarization/<mid>.json` with the public generic init: `DiarizationResult(speakerCount:totalFrames:frameRate:segments:)`, and each segment through `SpeakerSegment(speaker:startFrame:endFrame:frameRate:)`. The frame values are saved, so the rebuild is exact.
2. For each engine, build `[TranscriptionResult]` (the "WhisperKit-type bridge" from the research):
   - Whisper: decode the saved raw `[TranscriptionResult]` (it is `Codable`). This is the exact production input.
   - Apple: one `TranscriptionSegment` per Apple result (phrase). Its words are the grouped Apple words (analyze §3) that have times.
   - Reference: one `TranscriptionSegment` per response segment if the response has segments, else one per chunk. Words are offset by the chunk start.
   - Each bridged `WordTiming(word: " " + text, tokens: [], start: Float(start), end: Float(end), probability: Float(confidence ?? 1.0))`. Words without times are dropped from the bridge (and counted).
3. `diarization.addSpeakerInfo(to: results, strategy: .subsegment)` → `[[SpeakerSegment]]`.
4. Convert to `TranscriptResult` with a copy of `SegmentBuilder.buildSegment` (internal in Transcription; copied with a source comment), then `TranscriptSanitizer.sanitize(_:audioDuration:)` (public). This gives exactly what the app would store for that engine.
5. Hand neutral `AlignedTranscript` values (segments with speaker id, words with speaker id) to `STTLabAnalysis`.

## 6. Error handling

- **Per item, never fatal:** a meeting × engine failure (WhisperKit error, OpenRouter failure after retries, Apple error) is logged and written as a status file (`status: "failed"`, `error: ErrorInfo`). The tool continues with the next item. At the end, the command prints a summary and exits with code 1 if any item failed.
- **Fatal (exit before work):** workspace or bundle missing; selection not confirmed, or the confirmed hash does not match (bundle/whisper/diarize/reference); `OPENROUTER_API_KEY` missing (reference only); bundle schema version mismatch (runner); results/bundle id mismatch (analyze).
- **Resumable everywhere:** each command first checks for a saved output with `status: "completed"` and skips that item unless `--force`. Failed items are retried on the next run. Reference resumes per chunk.
- **Logging:** `RunLog` writes to `home/logs/<command>-<ISO timestamp>.log` and stdout. The runner writes `<results>/log.txt` and shows the last 200 lines in the window.
- **Secrets:** the API key is read from `ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]` and goes only into the `Authorization` header. Request metadata saved to disk excludes headers. A unit test asserts the saved meta has no key.

## 7. Testing strategy

Framework: Swift Testing (`import Testing`). There are no tests that need models, network, or macOS 26. Those paths are covered by the manual run (they are the experiment itself).

| Target | What is tested |
|---|---|
| `STTLabCoreTests` | JSON round trip of every schema; atomic write; WAV Float32 write → read is bit-exact; `int16WAVData` header fields and sample clamping; SHA-256 of a known file; `MemorySampler` returns a non-zero footprint; `ErrorInfo` from an `NSError`. |
| `STTLabAnalysisTests` | Normalizer table tests; Hirschberg alignment equals a naive full-matrix DP (cost and op counts) on 200 seeded random pairs; WER S/D/I counts; disagreement regions and tie-break classes on hand-built triples; Apple run → word grouping, granularity classes and anomalies; timing stats; gap flags; text-quality counts; speaker agreement on synthetic aligned data; report rendering smoke test (all sections present, missing engines shown as "n/a"). |
| `STTLabHomeTests` | Selection: bucket fill, shortfall fill, deterministic variety pick, eligibility rules; confirm hash and id assignment; chunk planner on synthetic signals (cuts land in silent gaps, chunk length limits, deterministic); OpenRouter request builder (fields, `zdr`, no key in saved meta) and response parser (words present / absent / with segments); retry policy with a stub transport (429 → retry, 400 → fail now, repeated timeouts → split); diarization save → rebuild is equal; `SpeakerAlignment` with a hand-built `DiarizationResult` and bridged words gives the expected speakers (no models: `addSpeakerInfo` is pure); production-constant drift test. |

The coverage target is the pure logic (selection, chunking, normalization, alignment, metrics). Model and API calls are thin wrappers around them.

## 8. Phase boundaries (for the implementation plan)

1. Package scaffold, `STTLabCore`, Makefile and hooks-mcp integration.
2. Prep: store reader, select, confirm, bundle.
3. Home engines: whisper, diarize, reference (OpenRouter + chunk planner + probe), home-run.
4. Runner app and packaging script.
5. Analysis core: normalization, alignment, WER, tie-break, text quality, timing, Apple word grouping.
6. Speaker alignment, speaker metrics, report, `analyze` command, `NOTES.md`.

## 9. Changes to and additions on the functional spec

These are small and in the spirit of the spec. They are recorded here so the reader can see them:

1. **Bundle contents.** Spec §3.3 lists the original `.aac` files in the bundle, and §3.5 says the runner bundle has only WAV, metadata and manifest. Resolution: the `.aac` copies go to `home/source/` (home only). The AirDropped `bundle/` has WAV + meta + manifest + README.
2. **Merged WAV format:** Float32 16 kHz mono, so local engines get production-identical samples. The reference gets 16-bit chunks of the same samples.
3. **Reference chunking is always on.** OpenRouter documents a 60 s upstream timeout per request. Default chunk: 300 s, cut at the quietest 0.5 s inside ±30 s of the target. A chunk that times out twice is split in two (at most 3 levels).
4. **Probe step:** `sttlab reference --probe` sends one 60 s clip and prints whether word timestamps come back, the provider, and the cost. This checks the reference before the full upload.
5. **Alternatives on.** The runner turns on `.alternativeTranscriptions` (spec §4.2 "alternatives if available"). The config is saved with each result. The report notes that production would not use alternatives.
6. **Whisper output for speaker metrics** goes through the production assembly (`addSpeakerInfo` → SegmentBuilder copy → `TranscriptSanitizer`). The WER, timing and text metrics use the raw engine words for all engines (the sanitizer only trims end-of-audio artifacts).
7. **Fillers are removed before WER** (standard practice, so the reference's filler policy does not dominate WER). They are counted separately (spec §5.3).
8. **Runner CLI mode:** `STTLabRunner --cli <bundle> [--results <dir>] [--force]` runs the same job without the UI, as a fallback if the UI fails on the runner Mac.

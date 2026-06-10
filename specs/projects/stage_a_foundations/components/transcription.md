---
status: complete
---

# Component: Transcription (`Packages/Transcription`)

Productionizes `experiments/ArgMaxKit`. Designs the real API inside the boundary the repo [`architecture.md` §2](../../../../architecture.md) draws. Consumes [`research/argmax`](../../../../research/argmax/README.md) — do not re-derive its findings.

## Purpose & Scope

**In:** diarized transcript from labeled audio file paths (mic + system), model management with rich status, crash-isolated worker (XPC + in-process fallback), custom-vocab biasing, mandatory output sanitization, re-transcribe, a CLI harness.

**Not:** persistence, vocab assembly/source-of-truth, the `.xpc` bundle/Info.plist/entry-point (app-project glue — lives in `ManualTestApp/` now, `App/` later), "me"/cross-file speaker identity (P2), UI beyond the CLI.

## Resolved Research Decisions (carried forward from `research/argmax`)

These decisions are settled and must not be re-derived. This section exists so the spec is self-contained and auditable against the research artifacts.

| Decision | Research finding | Spec/code obligation |
|---|---|---|
| **Transcription method (blended id)** | V1 offers **no transcription options** — one fixed method | A single opaque, extensible **`transcriptionMethodId`** (`"v1"`) bakes in every output-affecting parameter (STT model + quantization, diarization model, diarization strategy, word-timestamps). The engine owns the id→settings mapping; **no model/strategy/config input param**. The result **returns** the id; the data model stores it. Adding `"v2"` later is additive. |
| **STT model (inside `v1`)** | `openai_whisper-large-v3-v20240930_626MB` (quantized Sept 2024 large-v3, ~626 MB). Single model regardless of RAM. | Part of method `v1`; not a caller option |
| **Diarization model + strategy (inside `v1`)** | Pyannote v4 community-1 via SpeakerKit (~33 MB, CC-BY-4.0); `.subsegment` merge strategy | Part of method `v1`; not separately selectable in V1 |
| **XPC crash isolation** | XPC service for crash + memory isolation; in-process actor fallback | `Transcriber` has `.hosted` / `.inProcess` backends |
| **Custom vocabulary** | `promptTokens` workaround (~224-token budget); Pro swap via `[String]` API | `VocabularyFormatter` formats + truncates; caller passes `[String]` (the one per-meeting input, separate from the method) |
| **Output sanitization** | Drop/clamp segments past audio length (gotcha #14); segment `confidence==0` unreliable — derive from word `probability` (gotcha #13) | `TranscriptSanitizer` mandatory pass |
| **Sequential model load/unload** | STT then diarize, unload between, for memory-safe 8 GB operation | **internal** to the engine on ≤8 GB (not a caller option) |
| **Two-stream merge** | SDK takes single `[Float]` 16 kHz mono; merge mic+system, retain provenance labels (research §5) | `AudioMerger` sums/normalizes, emits `LabeledRange` |
| **Centroid embeddings** | NOT exposed as public API in v1.0.0 (erratum §6); `speakerEmbeddings` field reserved but empty | Field present, always `[:]` in V1 |
| **CLI stdout/stderr** | JSON to stdout, all diagnostics to stderr (gotcha #15) | `transcribe-cli` uses `OutputWriter` abstraction |
| **Licensing** | `argmax-oss-swift` MIT; vendors HuggingFace Hub Apache-2.0; SpeakerKit community model CC-BY-4.0 | Attribution required at app level (Biscotti.app, not this package) |
| **First-compile delay** | CoreML compiles models on-device, 15–90 s first time | Surfaced as `.compiling` status |
| **Offline first run** | STT model too large to bundle (~1.3–3.1 GB); SpeakerKit ~33 MB MAY be bundled | `needsDownload` / `downloadFailed` errors, never a silent hang |
| **Model download/cache** | HuggingFace Hub cache `~/.cache/huggingface/hub/`; `WhisperKitConfig.modelFolder` override; progress callbacks supported | `ensureModelsDownloaded(progress:)` with disk-space pre-check |
| **Model deletion** | Unload sets instances to nil (WhisperKit); `unloadModels()` (SpeakerKit) | `unloadModels()` on both engine and client |
| **Re-transcribe** | Result records `transcriptionMethodId`; same pipeline, possibly different vocab (or a future method) | `reTranscribe(mic:system:customVocabulary:)` on `Transcriber` (re-merges from the two source streams) |

## Public Interface

The library splits into three seams: the **engine worker** (does the ML), the **client** the app holds, and the **value types**.

### Value types

`TranscriptResult`, `TranscriptSegment`, `TranscriptWord` carry over from `experiments/ArgMaxKit/Sources/ArgMaxKit/Models.swift` (all `Sendable, Codable`), with **one change**: the result reports the method, not a raw model string —

```swift
public struct TranscriptResult: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let transcriptionMethodId: String   // e.g. "v1" — replaces the old `modelVersion`
    public let language: String
    public let speakerCount: Int
    public let segments: [TranscriptSegment]
    public let speakerEmbeddings: [Int: [Float]] // reserved; empty in v1.0.0 (erratum §6)
    public let processingDuration: TimeInterval
}
```

**The transcription method** is a single opaque, extensible identity — there is **no model/strategy/config input** in V1:

```swift
public struct TranscriptionMethod: Sendable, Equatable {
    public let id: String                       // "v1"
    public static let v1 = TranscriptionMethod(id: "v1")
    public static let current = v1              // the default the engine uses
    // The id→concrete-settings mapping (Whisper large-v3-v20240930_626MB,
    // Pyannote v4 community-1, .subsegment, word-timestamps on) is an INTERNAL detail.
}
```

The old `ProcessorConfig`/`DiarizationStrategy` public input types are removed — their settings are now internal to `TranscriptionMethod.v1` (incl. RAM-aware quantization + sequential-load on ≤8 GB).

### Model status (new — the rich status the spec requires)

```swift
public enum ModelStatus: Sendable, Equatable {
    case needsDownload
    case downloading(progress: Double)   // 0.0...1.0
    case compiling                        // CoreML first-compile (15–90s)
    case loading
    case ready                            // loaded, idle
    case running                          // a job in flight
    case error(TranscriptionError)
}
```

### The engine seam (so the worker is stub-able in tests and hostable in XPC)

```swift
/// What the out-of-process worker (and the in-process fallback) implement.
/// All transport-friendly: inputs are paths/strings, output is the Codable result.
public protocol TranscriptionEngine: Sendable {
    func ensureModelsDownloaded(
        progress: @Sendable (Double) -> Void
    ) async throws
    func processAudio(
        micPath: String, systemPath: String,
        customVocabulary: [String]
    ) async throws -> TranscriptResult     // uses TranscriptionMethod.current; returns its id in the result
    func unloadModels() async
    func status() async -> ModelStatus
}
```

- Input is the two **labeled source paths** (`micPath` + `systemPath`) — **never a pre-merged file**. The engine is the *only* component with "audio expertise": it merges the two streams to a mono 16 kHz `[Float]` **transiently, in memory**, retaining provenance labels (research §5), and discards it after the run. We persist **only** mic + system (no third "merged" file ever stored). **Re-transcribe re-merges from the same two source files** — so a transcript can always be regenerated from the durable streams. Both paths required; empty/zero-sample → `invalidInput`.

### The in-process worker (the real ML; the CLI + tests use this directly)

```swift
public actor InProcessTranscriptionEngine: TranscriptionEngine {
    public init(method: TranscriptionMethod = .current)
    // … implements the protocol; this is today's ArgMaxProcessor, refactored
    //    behind the protocol, plus merge-of-two-streams and sanitization.
    //    Resolves `method` → concrete settings internally (incl. RAM-aware quantization).
}
```

### The client the app holds (XPC-first, in-process fallback)

```swift
public actor Transcriber {
    /// `hosted`: connect to the BiscottiTranscriber.xpc service by name (app/test-app).
    /// `inProcess`: run the engine in this process (CLI, unit tests, no-XPC contexts).
    public enum Backend: Sendable {
        case hosted(serviceName: String)
        case inProcess
    }

    public init(backend: Backend, method: TranscriptionMethod = .current)

    public func ensureModelsDownloaded(progress: (@Sendable (Double) -> Void)?) async throws
    public func processAudio(mic: URL, system: URL, customVocabulary: [String]) async throws -> TranscriptResult
    public func reTranscribe(mic: URL, system: URL, customVocabulary: [String]) async throws -> TranscriptResult
    public func unloadModels() async throws
    public func statusStream() -> AsyncStream<ModelStatus>
    public func isAvailable() async -> Bool
}
```

For `.hosted`, `Transcriber` owns the `NSXPCConnection`, sets the `interruptionHandler`, maps a worker crash to `TranscriptionError.workerInterrupted` (retriable), and the next call auto-relaunches the worker. The cross-boundary `@objc` protocol carries `Data` (JSON-encoded `TranscriptResult`) per research §7; `TranscriptionEngine` above is the Swift-native seam, with a thin adapter to/from the `@objc` XPC protocol.

### Errors

```swift
public enum TranscriptionError: Error, Sendable, Equatable {
    case needsDownload
    case insufficientDisk(requiredBytes: Int64, availableBytes: Int64)
    case downloadFailed(String)
    case modelLoadFailed(String)
    case workerUnavailable
    case workerInterrupted          // retriable (jetsam/crash); next call relaunches
    case invalidInput(String)
    case transcriptionFailed(String)
    case diarizationFailed(String)
}
```
(Supersedes the experiment's `ArgMaxError`.)

### Sanitization (mandatory — pure, unit-tested)

```swift
enum TranscriptSanitizer {
    /// Drops/clamps segments past `audioDuration` (Whisper end-of-audio hallucination),
    /// and optionally drops very-low-confidence trailing single-word segments.
    static func sanitize(_ result: TranscriptResult, audioDuration: TimeInterval) -> TranscriptResult
}
```
Confidence is derived from word-level `probability` only; segment-level `confidence` from the SDK is treated as unreliable (research gotchas #13/#14).

### CLI harness (`transcribe-cli`)

`transcribe --mic <path> --system <path> [--vocab a,b,c] [--json]` → runs the **in-process** engine with `TranscriptionMethod.current` (no model/method flag in V1; merges the two streams internally), prints `TranscriptResult` JSON (incl. `transcriptionMethodId`) to **stdout**, all diagnostics/progress to **stderr** (gotcha #15).

## Internal Design

- **Merge:** decode both streams, resample to 16 kHz mono, sum/normalize to one `[Float]` (retain which sample ranges came from mic for future "me" use; V1 just merges). Disk-space pre-check (`insufficientDisk`) before any download using the variant's known size.
- **Model lifecycle:** lazy load; `sequentialLoading` unloads WhisperKit before SpeakerKit (8 GB); explicit `unloadModels`. WhisperKit unload: set instance to `nil` (no explicit unload API — research §7). SpeakerKit unload: call `diarizer.unloadModels()` then set to `nil`. Status transitions drive `ModelStatus`/`statusStream`.
- **Worker isolation:** `@objc TranscriberServiceProtocol` (reply-handler style, `Data`+`Error`) as in research §7; `Transcriber.hosted` adapts it to the async `TranscriptionEngine`.
- **Resampling:** `AudioProcessor.loadAudioAsFloatArray(fromPath:)` from WhisperKit handles resampling to 16 kHz mono. The `AudioMerger` operates on the resulting `[Float]` arrays.

## Dependencies

`argmax-oss-swift` (WhisperKit + SpeakerKit), `swift-argument-parser` (CLI). No internal Biscotti deps. Consumed by: `ManualTestApp` + its `.xpc` service (now); `TranscriptionService` (Project 4).

## Licensing & Attribution

The Transcription package pulls `argmax-oss-swift` (MIT), which vendors HuggingFace Hub Swift and Tokenizers (Apache-2.0) inside ArgmaxCore. The SpeakerKit community model (`speakerkit-coreml`) is CC-BY-4.0, requiring attribution. The app target (not this package) must include proper attribution in its license/about screen for all three licenses.

## AI Test Set Support (Project 5)

The library's design supports automated ground-truth testing:

- The CLI harness (`transcribe-cli --json`) produces machine-readable JSON on stdout, suitable for a test runner to parse and compare against ground truth.
- `TranscriptResult` is `Codable`, enabling deserialization of both the CLI output and a reference fixture.
- The `InProcessTranscriptionEngine` can be used directly in a test binary (no XPC needed).
- Tests should validate: exact speaker count match, Levenshtein distance of full concatenated transcript text within a threshold, segment timestamps within audio bounds (sanitization working), and word-level probabilities present.
- These tests require downloading real models (~1.3–3.1 GB STT + ~33 MB diarization) and a reference audio file with known ground truth. They must be excluded from the default `make test` target and run via a dedicated `make test-ai` command.

## Test Plan (all `swift test`, no live models — fixtures + stub engine)

- `VocabularyFormatterTests` — prompt formatting + ~224-token truncation (carry over + extend).
- `SanitizerTests` — drops a segment timestamped past audio length (the 52.5 s / 25.1 s case); keeps in-range; derives confidence from word probabilities; segment `confidence==0` ignored.
- `MergeTests` — two mono fixtures → one 16 kHz array of expected length; provenance labels retained; mismatched lengths handled; empty/zero-sample → `invalidInput`. (No merged-file input path — merge is always from the two source streams.)
- `StatusMachineTests` — needsDownload→downloading(progress)→compiling→loading→ready→running→ready transitions.
- `ClientErrorMappingTests` — stub engine throwing → mapped `TranscriptionError`; simulated interruption → `workerInterrupted` (retriable), next call succeeds.
- `ResultCodableTests` — `TranscriptResult` JSON round-trips, incl. `transcriptionMethodId`.
- `MethodResolutionTests` — `TranscriptionMethod.current.id == "v1"`; the internal resolver picks quantized + sequential-load at ≤8 GB and full-precision at 16 GB+ (replaces the old `ProcessorConfigTests`; the RAM logic is now internal to method resolution).
- `CLITests` — in-process run over a tiny bundled fixture yields JSON on stdout, nothing non-JSON on stdout.

**Deferred to Manual Test App:** real model download/compile, real XPC crash-isolation under memory pressure, on-device transcription quality, ANE/cache-path/8 GB behavior.

## Code changes vs. the committed Phase 1 package (for the realign phase)

The committed code (Phases 1.1–1.4) predates these decisions. The Transcription realign phase must: replace `TranscriptResult.modelVersion` → `transcriptionMethodId`; introduce `TranscriptionMethod` (`.v1`/`.current`); **remove** the public `ProcessorConfig` + `DiarizationStrategy` input types (fold their settings into the internal method resolver, keeping RAM-aware quantization + sequential-load internal); drop the `config:`/`mergedPath:` params from `TranscriptionEngine`/`Transcriber`/CLI (`processAudio(mic:system:vocab:)`, no `merged`); and report real download progress + emit `.compiling`/`.loading` (SpeakerKit `load:false`). Plus the ground-truth AI test (Project 5).

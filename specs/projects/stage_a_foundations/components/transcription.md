---
status: complete
---

# Component: Transcription (`Packages/Transcription`)

Productionizes `experiments/ArgMaxKit`. Designs the real API inside the boundary the repo [`architecture.md` §2](../../../../architecture.md) draws. Consumes [`research/argmax`](../../../../research/argmax/README.md) — do not re-derive its findings.

## Purpose & Scope

**In:** diarized transcript from labeled audio file paths (mic + system), model management with rich status, crash-isolated worker (XPC + in-process fallback), custom-vocab biasing, mandatory output sanitization, re-transcribe, a CLI harness.

**Not:** persistence, vocab assembly/source-of-truth, the `.xpc` bundle/Info.plist/entry-point (app-project glue — lives in `ManualTestApp/` now, `App/` later), "me"/cross-file speaker identity (P2), UI beyond the CLI.

## Public Interface

The library splits into three seams: the **engine worker** (does the ML), the **client** the app holds, and the **value types**.

### Value types (productionized from the experiment, mostly unchanged)

`ProcessorConfig`, `DiarizationStrategy`, `TranscriptResult`, `TranscriptSegment`, `TranscriptWord` carry over from `experiments/ArgMaxKit/Sources/ArgMaxKit/Models.swift` essentially as-is (all `Sendable, Codable`). One addition for variant selection:

```swift
public extension ProcessorConfig {
    /// Picks the quantized `_1307MB` variant on ≤8 GB Macs, full-precision otherwise,
    /// and turns on sequentialLoading on ≤8 GB. Used as the production default.
    static func ramAware(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> ProcessorConfig
}
```

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
        micPath: String?, systemPath: String?, mergedPath: String?,
        config: ProcessorConfig, customVocabulary: [String]
    ) async throws -> TranscriptResult
    func unloadModels() async
    func status() async -> ModelStatus
}
```

- Input is **labeled paths** (`micPath`/`systemPath`), not a pre-merged blob — the engine owns the merge to mono 16 kHz `[Float]` and keeps the labels (research §5). `mergedPath` is accepted for re-transcribe of an already-merged file. At least one path required (else `invalidInput`).

### The in-process worker (the real ML; the CLI + tests use this directly)

```swift
public actor InProcessTranscriptionEngine: TranscriptionEngine {
    public init(config: ProcessorConfig = .ramAware())
    // … implements the protocol; this is today's ArgMaxProcessor, refactored
    //    behind the protocol, plus merge-of-two-streams and sanitization.
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

    public init(backend: Backend, config: ProcessorConfig = .ramAware())

    public func ensureModelsDownloaded(progress: (@Sendable (Double) -> Void)?) async throws
    public func processAudio(mic: URL?, system: URL?, merged: URL?, customVocabulary: [String]) async throws -> TranscriptResult
    public func reTranscribe(merged: URL, customVocabulary: [String]) async throws -> TranscriptResult
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

`transcribe [--mic <path>] [--system <path>] [--merged <path>] [--model <id>] [--vocab a,b,c] [--json]` → runs the **in-process** engine, prints `TranscriptResult` JSON to **stdout**, all diagnostics/progress to **stderr** (gotcha #15).

## Internal Design

- **Merge:** decode both streams, resample to 16 kHz mono, sum/normalize to one `[Float]` (retain which sample ranges came from mic for future "me" use; V1 just merges). Disk-space pre-check (`insufficientDisk`) before any download using the variant's known size.
- **Model lifecycle:** lazy load; `sequentialLoading` unloads WhisperKit before SpeakerKit (8 GB); explicit `unloadModels`. Status transitions drive `ModelStatus`/`statusStream`.
- **Worker isolation:** `@objc TranscriberServiceProtocol` (reply-handler style, `Data`+`Error`) as in research §7; `Transcriber.hosted` adapts it to the async `TranscriptionEngine`.

## Dependencies

`argmax-oss-swift` (WhisperKit + SpeakerKit), `swift-argument-parser` (CLI). No internal Biscotti deps. Consumed by: `ManualTestApp` + its `.xpc` service (now); `TranscriptionService` (Project 4).

## Test Plan (all `swift test`, no live models — fixtures + stub engine)

- `VocabularyFormatterTests` — prompt formatting + ~224-token truncation (carry over + extend).
- `SanitizerTests` — drops a segment timestamped past audio length (the 52.5 s / 25.1 s case); keeps in-range; derives confidence from word probabilities; segment `confidence==0` ignored.
- `MergeTests` — two mono fixtures → one 16 kHz array of expected length; labels retained; single-stream and merged-only inputs accepted; empty/zero-sample → `invalidInput`.
- `StatusMachineTests` — needsDownload→downloading(progress)→compiling→loading→ready→running→ready transitions.
- `ClientErrorMappingTests` — stub engine throwing → mapped `TranscriptionError`; simulated interruption → `workerInterrupted` (retriable), next call succeeds.
- `ResultCodableTests` — `TranscriptResult` JSON round-trips (carry over `TranscriptResultTests`).
- `ConfigTests` — `ramAware` picks quantized + sequentialLoading at 8 GB, full at 16 GB+ (carry over `ProcessorConfigTests`).
- `CLITests` — in-process run over a tiny bundled fixture yields JSON on stdout, nothing non-JSON on stdout.

**Deferred to Manual Test App:** real model download/compile, real XPC crash-isolation under memory pressure, on-device transcription quality, ANE/cache-path/8 GB behavior.
</content>

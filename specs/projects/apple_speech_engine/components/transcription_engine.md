---
status: complete
---

# Component: Transcription Engine (Apple STT, API, XPC)

## Purpose and Scope

Add Apple `SpeechTranscriber` as a second STT step inside `Packages/Transcription`, selectable per call; split Whisper and Speaker ID into separate model components; expose an app-side Apple support API (availability, locales, assets). Run Apple inside `BiscottiTranscriber.xpc`.

Not in scope: selection policy, persistence, UI (see `speech_engine_manager.md`, `ui.md`). Whisper decoding behavior is unchanged.

## Public Interface

### New / changed types

```swift
/// Which STT engine a method uses.
public enum SpeechEngine: String, Codable, Sendable, CaseIterable { case whisper, apple }

/// Separately downloadable model components managed by this package.
/// Apple assets are system-managed and are NOT a component.
public enum ModelComponent: String, Codable, Sendable, CaseIterable {
    case whisper      // models/argmaxinc/whisperkit-coreml/<model>
    case speakerID    // models/argmaxinc/speakerkit-coreml
}
public extension Set where Element == ModelComponent { static var all: Self { Set(ModelComponent.allCases) } }

public struct TranscriptionMethod: Sendable, Equatable, Codable {   // add Codable
    public let id: String
    public static let v1, v2                         // unchanged
    public static let appleV1 = TranscriptionMethod(id: "apple-v1")
    public static let current: TranscriptionMethod = .v2   // unchanged: the Whisper default
    public var engine: SpeechEngine { id.hasPrefix("apple") ? .apple : .whisper }
}

/// Per-call transcription configuration.
public struct TranscriptionConfig: Codable, Sendable, Equatable {
    public let method: TranscriptionMethod
    /// Locale identifier for Apple (e.g. "en_US"). Ignored for Whisper.
    public let locale: String?
    public init(method: TranscriptionMethod, locale: String? = nil)
    public static func whisper() -> TranscriptionConfig          // (.current, nil)
    public static func apple(locale: String) -> TranscriptionConfig
    public var engine: SpeechEngine { method.engine }
}

public enum TranscriptionError {  // add one case
    case engineUnavailable(String)  // Apple not available on this OS / locale unsupported
}
```

Add the new case to every exhaustive `switch` (`TranscriptionService.mapEngineError`, `XPCEngineAdapter.mapError`, `ClientErrorMappingTests`).

### `Transcriber` (public actor)

Existing signatures get defaulted parameters so current callers compile unchanged:

```swift
public func ensureModelsDownloaded(
    _ components: Set<ModelComponent> = .all,
    status: (@Sendable (String) -> Void)? = nil
) async throws

public func processAudio(
    mic: URL, system: URL,
    customVocabulary: [String] = [],
    config: TranscriptionConfig? = nil        // nil → TranscriptionConfig(method: self.method)
) async throws -> TranscriptResult

public func reTranscribe(mic:system:customVocabulary:config:)   // same defaulting

public func modelsPresent(_ components: Set<ModelComponent> = .all) async -> Bool   // static disk check, no XPC

/// Unloads (so the worker releases files), then removes the component directories.
public func deleteModels(_ components: Set<ModelComponent>) async throws
```

`deleteModels([.whisper])` removes only `models/argmaxinc/whisperkit-coreml/<sttModel>`; `[.speakerID]` removes `models/argmaxinc/speakerkit-coreml`. `clearCache()` is unchanged (removes everything).

### `TranscriptionEngine` protocol (package-public seam)

```swift
func ensureModelsDownloaded(components: Set<ModelComponent>, status: @escaping @Sendable (String) -> Void) async throws
func processAudio(micPath: String, systemPath: String, customVocabulary: [String], config: TranscriptionConfig) async throws -> TranscriptResult
func unloadModels() async
func modelsPresent(components: Set<ModelComponent>) async -> Bool
func status() async -> ModelStatus
```

`InProcessTranscriptionEngine` and `XPCEngineAdapter` implement it. Static presence helpers become `static func componentPresent(_:) -> Bool` (reusing today's `whisperKitModelsPresent` / `speakerKitModelsPresent`).

### `AppleSpeechSupport` (public, app-side queries)

Called from the app process (A5). Safe to call on macOS 15 (returns unavailable / empty).

```swift
public enum AppleSpeechAvailability: Sendable, Equatable {
    case available
    case requiresOSUpdate(currentMajor: Int)   // macOS < 26
    case unavailable                            // macOS ≥ 26 but SpeechTranscriber.isAvailable == false
}

public enum AppleSpeechSupport {
    public static func availability() -> AppleSpeechAvailability
    /// Supported locale identifiers (SpeechTranscriber.supportedLocales). [] when not available.
    public static func supportedLocales() async -> [String]
    /// SpeechTranscriber.supportedLocale(equivalentTo:) — nil when unsupported/unavailable.
    public static func supportedLocale(equivalentTo identifier: String) async -> String?
    /// true when assetInstallationRequest(supporting:) returns nil for a transcriber on this locale.
    /// Side effect accepted: reserves the locale for this process (A6 releases others first).
    public static func assetsInstalled(locale: String) async throws -> Bool
    /// Installs assets; reports Progress.fractionCompleted (nil until totalUnitCount > 0).
    /// No-op when already installed. Throws TranscriptionError.downloadFailed / .engineUnavailable.
    public static func installAssets(locale: String, progress: @escaping @Sendable (Double?) -> Void) async throws
}
```

Implementation lives in `AppleSpeech/AppleSpeechSupport.swift`; each body is `#if canImport(Speech)` + `if #available(macOS 26, *) { … }` with a fallback branch.

## Internal Design

### File layout (new files under `Sources/Transcription/`)

| File | Content |
|---|---|
| `SpeechEngine.swift` | `SpeechEngine`, `ModelComponent`, `TranscriptionConfig` |
| `AppleSpeech/AppleSpeechSupport.swift` | public app-side API above |
| `AppleSpeech/AppleLocaleReservations.swift` | `@available(macOS 26, *)` helper: `prepare(locale:) async throws -> SpeechTranscriber`; releases other `AssetInventory.reservedLocales`, builds the transcriber, returns it |
| `AppleSpeech/AppleSpeechSTT.swift` | `@available(macOS 26, *)` runner: samples → `[TranscriptionResult]` |
| `AppleSpeech/AppleWordGrouping.swift` | pure (no Speech import): `AppleRunInput`/`AppleResultInput` structs → words → WhisperKit `TranscriptionResult` |
| `AppleSpeech/WAVWriter.swift` | writes `[Float]` 16 kHz mono to a temp `.wav` (`AVAudioFile`, `.pcmFormatFloat32`, interleaved false) |

### Method resolution

`ResolvedMethodSettings` gains `engine: SpeechEngine`. `MethodResolver.resolve`:
- `"v1"`, `"v2"` → as today, `engine: .whisper`.
- `"apple-v1"` → `engine: .apple`, `sttModel`/`repo` = the Whisper values (unused), `enableWordTimestamps: true`, `detectLanguage: false`, `diarizationStrategy: .subsegment`, `sequentialLoading: isLowRAM`.
- unknown → v1 (unchanged).

The engine resolves per call (`MethodResolver.resolve(config.method)`), not once at init. `init(method:)` keeps its parameter as the default for `processAudio` callers that pass `config == nil` through `Transcriber`.

### `InProcessTranscriptionEngine.processAudio(…, config:)`

```
settings = MethodResolver.resolve(config.method)
merge = loadAndMergeAudio(mic, system)                      // unchanged
status → .running
switch settings.engine:
  .whisper: stt = runWhisperSTT(samples, customVocabulary, settings)    // today's runSTT
            if settings.sequentialLoading { unloadWhisperKit() }
  .apple:   guard let locale = config.locale → throw .engineUnavailable("No locale")
            stt = runAppleSTT(samples, duration, locale)              // never touches WhisperKit; vocabulary ignored
diarization = runDiarization(samples)                       // unchanged
assembleResult(stt, diarization, duration, start, methodId: config.method.id,
               language: apple ? locale : (stt.first?.language ?? "unknown"))
```

`runAppleSTT`:
```swift
#if canImport(Speech)
if #available(macOS 26, *) { return try await AppleSpeechSTT.transcribe(samples:duration:locale:status:) }
#endif
throw TranscriptionError.engineUnavailable("Apple Speech requires macOS 26 or later")
```

### `ensureModelsDownloaded(components:status:)`

Disk check uses the sum of the requested components that are not yet present: whisper = today's `estimatedDownloadBytes` (750 MB for the 626MB model), speakerID = 50 MB. Then download only requested components in order whisper → speakerID with today's status strings. Apple assets are **not** handled here (they are installed by `AppleSpeechSupport.installAssets` in the app, and by `AppleSpeechSTT` inside the job).

### `AppleSpeechSTT.transcribe` (macOS 26, inside the XPC process)

Port of `STTLabRunner/AppleTranscription.swift`, minus the experiment bookkeeping:

1. `resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale))` else throw `.engineUnavailable("Locale \(locale) is not supported")`.
2. `transcriber = try await AppleLocaleReservations.prepare(locale: resolved)` → `SpeechTranscriber(locale: resolved, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])`. (STTLab also enabled `.alternativeTranscriptions`; alternatives are unused here.)
3. `if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])` → `status("Downloading Apple speech model")`, `try await request.downloadAndInstall()`; errors → `.downloadFailed("Apple speech assets: …")`.
4. `url = try WAVWriter.writeTemp(samples)`; `defer { try? FileManager.default.removeItem(at: url) }`; `file = try AVAudioFile(forReading: url)`.
5. `analyzer = SpeechAnalyzer(modules: [transcriber])`. Start `collector` task: `for try await r in transcriber.results where r.isFinal { out.append(AppleResultInput(r)) }`.
6. `let last = try await analyzer.analyzeSequence(from: file)`; `if let last { try await analyzer.finalizeAndFinish(through: last) } else { await analyzer.cancelAndFinishNow() }`. On error: cancel collector, `cancelAndFinishNow()`, rethrow as `.transcriptionFailed`.
7. Await the collector with watchdog `max(600, duration)` seconds (task group race, as STTLab); timeout → `.transcriptionFailed("Apple Speech timed out")`.
8. `return AppleWordGrouping.transcriptionResults(from: out, language: resolved.identifier)`.

`AppleResultInput(r)` converts an `AttributedString` result into plain data (text, runs with UTF-16 char offset/length, `audioTimeRange` start/duration seconds, `transcriptionConfidence`) — the STTLab `extractRuns` logic — so grouping is testable without Speech.

### `AppleWordGrouping` (pure)

```swift
struct AppleRunInput: Equatable, Sendable { text: String; charOffset: Int; charLength: Int; start: Double?; duration: Double?; confidence: Double? }
struct AppleResultInput: Equatable, Sendable { text: String; rangeStart: Double; rangeDuration: Double; runs: [AppleRunInput] }
struct AppleWord: Equatable { text: String; start: Double?; end: Double?; confidence: Double? }

enum AppleWordGrouping {
    static func words(in result: AppleResultInput) -> [AppleWord]                 // STTLab groupOneResult (no stats)
    static func fillUntimed(_ words: [AppleWord], result: AppleResultInput) -> [AppleWord]
    static func transcriptionResults(from results: [AppleResultInput], language: String) -> [TranscriptionResult]
}
```

- `words(in:)`: tokenize on whitespace (UTF-16 offsets, surrogate-safe), assign each token the min start / max end / mean confidence of runs overlapping it that have a time (exact STTLab algorithm).
- `fillUntimed`: an untimed word takes `start = end =` the previous timed word's end; if none yet, the next timed word's start; if the result has no timed word at all, all words get `result.rangeStart … rangeStart + rangeDuration` spread evenly by index. Words are never dropped.
- `transcriptionResults`: drop results with zero words; order results by first word start; one `TranscriptionSegment` per result (`id` = index, `start/end` = min/max word times, `text` = words joined by " ", `noSpeechProb: 0`, other numeric fields 0) whose `words` are `WordTiming(word: " " + text, tokens: [], start:, end:, probability: Float(confidence ?? 1.0))`; return a single `TranscriptionResult(text:, segments:, language:, timings: TranscriptionTimings())`. Matches STTLab `SpeakerAlignment.bridge`.

### Speaker ID, assembly, sanitizing

Unchanged: `diarization.addSpeakerInfo(to:strategy: .subsegment)` → `SegmentBuilder.buildSegments` → `TranscriptSanitizer.sanitize`. `assembleResult` takes `methodId` and `language` parameters instead of reading `self.method` / `stt.first?.language`.

### XPC

- `XPCProcessRequest` gains `public let config: TranscriptionConfig?` (decoded with `decodeIfPresent`; nil → `.whisper()`).
- New `XPCDownloadRequest: Codable { components: [ModelComponent] }`.
- `TranscriberServiceProtocol.ensureModelsDownloaded(reply:)` becomes `ensureModelsDownloaded(requestData: Data, reply:)` (app and service ship together). Service decodes components (empty/invalid → `.all`).
- `TranscriberService.processAudio` passes `request.config ?? .whisper()` to the engine.
- Service keeps a single `InProcessTranscriptionEngine()`; config is per call. Per-job process lifecycle is unchanged.
- No entitlement changes. `App/Resources/Info.plist` gets `NSSpeechRecognitionUsageDescription` = "Biscotti transcribes meetings on your Mac with Apple's built-in speech model." (A12). The XPC service plist is unchanged.

### `XPCEngineAdapter`

Encodes `config` into `XPCProcessRequest` and `components` into `XPCDownloadRequest`; `modelsPresent(components:)` uses the static component checks. No other change.

### CLI (`transcribe-cli`)

Add `--engine whisper|apple` and `--locale <id>` options (default whisper). Apple fails with a clear message below macOS 26. This gives a hardware smoke test without the app.

## Dependencies

- Uses: WhisperKit, SpeakerKit (unchanged), Apple `Speech`, `AVFoundation`, `CoreMedia` (system frameworks; no new packages).
- Used by: `BiscottiKit/TranscriptionService` (`Transcribing` adapter, `LiveAppleSpeechProvider`), `XPCServices/BiscottiTranscriber`, `ManualTestApp`, `experiments/STTLab` (only `TranscriptResult` init — unaffected).

## Test Plan (`TranscriptionTests`)

| Test | Verifies |
|---|---|
| `methodEngineMapping` | `.v1/.v2` → whisper, `.appleV1` → apple; `TranscriptionMethod` Codable round-trip |
| `configFactories` | `.whisper()` = (.current, nil); `.apple(locale:)` keeps locale |
| `resolverAppleSettings` | `apple-v1` → engine apple, subsegment, no language detection |
| `processRequestDecodesWithoutConfig` | old JSON (no `config`) decodes; adapter/service default to whisper |
| `processRequestRoundTripsConfig` | config survives encode/decode |
| `downloadRequestComponents` | components encode/decode; empty → all |
| `componentPresenceAndDelete` | temp `ModelStorage` root: presence per component; `deleteModels([.whisper])` leaves Speaker ID |
| `groupingWholeWordRuns` / `groupingLeadingSpaceRuns` / `groupingMultiRunToken` | ported STTLab grouping cases |
| `fillUntimedUsesPreviousEnd` / `…NextStart` / `…AllUntimedSpread` | untimed fill rules; no word dropped |
| `bridgeOneSegmentPerResult` | segment count/order/text/times; empty results dropped |
| `bridgeConfidenceDefault` | nil confidence → probability 1.0 |
| `bridgeThenAssembleAssignsSpeakers` | bridged results + a synthetic `DiarizationResult` → `addSpeakerInfo` + `SegmentBuilder` → expected speaker IDs (no models needed) |
| `hostedClientSendsConfig` / `…SendsComponents` | `MockXPCConnection` sees config/components |
| `appleSupportUnavailableBelow26` | on the CI runner (macOS 15): `availability()` = `.requiresOSUpdate(15)`, `supportedLocales()` = [] |
| `engineUnavailableErrorMapping` | client error mapping handles the new case |
| AI (`BISCOTTI_RUN_AI_TESTS=1`, skipped below 26): `appleEndToEnd3Speaker` | `Transcriber(.inProcess)` with `.apple(locale: "en_US")` on the 3-speaker fixture: non-empty words with times, ≥2 speakers, `transcriptionMethodId == "apple-v1"`, `language == "en_US"`, ground-truth word match above a loose floor (reuse `GroundTruth`) |

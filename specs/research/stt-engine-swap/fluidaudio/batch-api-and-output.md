# FluidAudio: Batch ASR API and Exact Output Shape

Pinned: **FluidAudio v0.17.7** (`503b4bd1`, 2026-10-07). All signatures below were copied from source at that tag. File paths are relative to `Sources/FluidAudio/`.

---

## 1. TDT path (`AsrManager`): the real signatures

`ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift`:

```swift
public actor AsrManager {
    public init(config: ASRConfig = .default, models: AsrModels? = nil)
    public func loadModels(_ models: AsrModels) async throws
    public var decoderLayerCount: Int { get }          // 2 for v2/v3 family
    public var transcriptionProgressStream: AsyncThrowingStream<Double, Error> { get async }
    public var isAvailable: Bool { get }
    public func reset()
    public func cleanup()

    public func transcribe(_ audioBuffer: AVAudioPCMBuffer,
                           decoderState: inout TdtDecoderState,
                           language: Language? = nil) async throws -> ASRResult
    public func transcribe(_ url: URL,
                           decoderState: inout TdtDecoderState,
                           language: Language? = nil) async throws -> ASRResult
    public func transcribeDiskBacked(_ url: URL,
                           decoderState: inout TdtDecoderState,
                           language: Language? = nil) async throws -> ASRResult
    public func transcribe(_ audioSamples: [Float],         // 16 kHz mono
                           decoderState: inout TdtDecoderState,
                           language: Language? = nil) async throws -> ASRResult
}
```

`TdtDecoderState` (`.../Decoder/TdtDecoderState.swift`): `public init(decoderLayers: Int = 2) throws` and `public static func make(decoderLayers: Int = 2) -> TdtDecoderState`.

Model loading (`AsrModels.swift`):

```swift
public static func download(to directory: URL? = nil, force: Bool = false,
    version: AsrModelVersion = .v3, encoderPrecision: ParakeetEncoderPrecision = .int8,
    progressHandler: ProgressHandler? = nil) async throws -> URL
public static func load(from directory: URL, configuration: MLModelConfiguration? = nil,
    version: AsrModelVersion = .v3, encoderPrecision: ParakeetEncoderPrecision = .int8,
    encoderComputeUnits: MLComputeUnits? = nil, progressHandler: ProgressHandler? = nil) async throws -> AsrModels
public static func loadLocal(from directory: URL, version: AsrModelVersion = .v3, ...) throws -> AsrModels  // never downloads
public static func downloadAndLoad(to:configuration:version:encoderPrecision:encoderComputeUnits:progressHandler:)
public static func modelsExist(at directory: URL, version: AsrModelVersion,
    encoderPrecision: ParakeetEncoderPrecision = .int8) -> Bool
public static func defaultCacheDirectory(for version: AsrModelVersion = .v3) -> URL
```

A minimal correct call against v0.17.7 (this is my construction from the signatures; it has not been compiled):

```swift
let dir = modelsRoot.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml") // see layout quirk below
try await AsrModels.download(to: dir, version: .v3, progressHandler: { p in ... })
let models = try await AsrModels.load(from: dir, version: .v3)
let asr = AsrManager(config: .default, models: models)
var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
let result: ASRResult = try await asr.transcribe(samples16kMono, decoderState: &state)
```

### Docs vs source

The draft spec suspected that the docs lag the source. This is confirmed, and it is worse than the draft said:

- [Documentation/ASR/GettingStarted.md](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/ASR/GettingStarted.md) shows `try await asrManager.configure(models: models)` and `asrManager.transcribe(samples, source: .system)`. **Neither exists in v0.17.7.** There is no `configure(models:)`, and no `transcribe(_:source:)` on `AsrManager`. `AudioSource` survives only on the streaming `SlidingWindowAsrManager`.
- `README.md` line 348 shows `try await asrManager.transcribe(samples)`. This does not compile, because all four `transcribe` overloads require `decoderState: inout`.
- History: `transcribe(_:source:)` was the API through **v0.13.0** (2026-03-25). By **v0.14.0** (2026-04-23) it was `transcribe(_:decoderState:)`. `language:` was added later. So the batch API had at least one breaking change in the last 7 months.

---

## 2. `ASRResult` and `TokenTiming` (verbatim)

`ASR/Parakeet/AsrTypes.swift`:

```swift
public struct ASRResult: Codable, Sendable {
    public let text: String
    public let confidence: Float
    public let duration: TimeInterval
    public let processingTime: TimeInterval
    public let tokenTimings: [TokenTiming]?
    public let performanceMetrics: ASRPerformanceMetrics?
    public let ctcDetectedTerms: [String]?
    public let ctcAppliedTerms: [String]?
    public var rtfx: Float { get }
}

public struct TokenTiming: Codable, Sendable {
    public let token: String
    public let tokenId: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Float
}

public struct WordTiming: Codable, Sendable {      // NOTE: no confidence field
    public let word: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
}

public func buildWordTimings(from tokenTimings: [TokenTiming]) -> [WordTiming]
```

### What each field means (from reading the code that fills it)

| Field | Semantics | Evidence |
|---|---|---|
| `text` | One string for the **whole clip**. SentencePiece pieces joined, `▁` replaced with a space, then trimmed. Punctuated and cased (see [models-and-runtime.md §3](./models-and-runtime.md#3-punctuation-and-capitalization-per-model-the-doc-contradiction-is-resolved)). | `AsrManager.convertTokensToText` |
| `confidence` | Mean of the token probabilities, **clamped to [0.1, 1.0]**. Returns **0.1** for an empty transcript and 0.5 if the token confidences are missing. | `AsrManager+TokenProcessing.swift` `calculateConfidence`: "Returns the average of token-level softmax probabilities from the decoder. Range: 0.1 (empty transcription) to 1.0" |
| `duration` | Audio length in seconds (`samples / 16000`). | `processTranscriptionResult` |
| `tokenTimings` | **Sub-word** (SentencePiece) tokens, **not words**. Always populated on the batch paths I traced (single-window, in-memory chunked, disk-backed). Typed as optional. | `processTranscriptionResult` and `ChunkProcessor` both call it with timings |
| `TokenTiming.token` | Vocabulary piece with `▁` **normalized to a leading space**. So `" The"` starts a word, `"ing"` continues a word, and `","` / `"."` are bare continuation pieces that attach to the previous word. Unknown ids become `"token_<id>"`. | `createTokenTimings` uses `normalizedTimingToken(rawToken)`. The shipped `parakeet_vocab.json` already stores pieces with a leading space (4,172 of 8,192 pieces). |
| `TokenTiming.confidence` | **Linear softmax probability in [0, 1]** over the full vocabulary for the emitted token. Not a log-probability. | `TdtJointDecision.probability`: "Full-vocab softmax probability for `token`, clamped to [0, 1]". It comes from the joint model's `token_prob` output, then `TdtDurationMapping.clampProbability` (NaN becomes 0). |
| `TokenTiming.startTime` | `(frameIndex − 1) × 0.08 s`. The −1 is an "emission-delay correction: tokens are emitted ~1 encoder frame after the acoustic event". It can be overridden by the env var `TDT_EMISSION_DELAY_FRAMES`. | `createTokenTimings` |
| `TokenTiming.endTime` | TDT path: `start + max(durationBins × 0.08, 0.08)`, using the TDT **duration head** (bins `[0,1,2,3,4]` frames, so at most 0.32 s per token). Fallback: next token's start. The minimum span is 1 ms. | `createTokenTimings`; `TdtConfig.durationBins` default |
| Timestamp precision | **80 ms quantization** (one encoder frame = 1280 samples at 16 kHz; `ASRConstants.secondsPerEncoderFrame = 0.08`). | `ASRConstants.swift` |
| `performanceMetrics`, `ctc*Terms` | nil on the plain batch path. The CTC fields are filled only by vocabulary boosting. | |

**Not provided anywhere in `ASRResult`:**
- **No segments.** There is no sentence or segment structure. You get one string plus a flat token list.
- **No detected language.** The `language: Language?` parameter is a *hint* for "script-aware token filtering (v3 only)". Its doc says verbatim: "When set, top-K tokens that don't match the language's script are skipped in favor of matching candidates. Silently ignored for v2 / tdtCtc110m / tdtJa." The model detects the language internally (NVIDIA: "Language detection operates automatically"), but FluidAudio does not surface it.
- **No no-speech probability**, and no avg-logprob per segment.
- **No word-level confidence.** `buildWordTimings` drops confidence, because `WordTiming` has no confidence field.

### Word grouping that FluidAudio provides

`buildWordTimings(from:)` starts a new word on a piece that begins with `▁` or a space. Otherwise it appends the piece to the current word. It skips `""`, `<blank>`, and `<pad>`. The word spans from the first piece's start to the last piece's end, and the text is **trimmed**, so it has no leading space. Punctuation stays attached (`"meeting,"`).

The internal seam-merge code has a more careful word model (`startsWordPiece`, `wordExtent`, `isJoiningPunctuationPiece`), which treats bare `'`/`-` as joiners and boundary-marked punctuation specially. That code is `nonisolated internal static`, so it is not public.

---

## 3. Long audio (1-hour meetings)

Geometry is the same for the TDT and Unified batch paths ([LongTranscription.md](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/ASR/LongTranscription.md) "Chunk Geometry", verified in `ChunkProcessor.swift`):

| Quantity | Value |
|---|---|
| Encoder window | 240,000 samples (15.00 s), fixed by the Core ML export |
| Visible chunk | ≈ 14.96 s, frame-aligned |
| Overlap | 2.0 s (frame-aligned) |
| Frame | 80 ms |

- **TDT path:** audio of 15 s or less is decoded in one window. Longer audio goes through `ChunkProcessor`. Its features include **parallel workers** (`parallelChunkConcurrency`, default 4), stateless chunks merged on the overlap by token-sequence and timestamp matching, **silence-aligned chunk starts** for v3 (`melChunkContext` resolves to false on v3), an opt-in `dualDecodeArbitration`, a default-on **seam-gap repair pass** (`seamGapRepair = true`, it re-decodes inter-token gaps ≥ 1.5 s), end-aligned final windows (#747), and case-folded seam dedupe (#706).
- **URL input:** files above `streamingThreshold` (480,000 samples ≈ 30 s) go through `transcribeDiskBacked`. That path memory-maps the file at 16 kHz ("constant memory usage (~1.2MB) regardless of file size"). A `[Float]` input is processed in memory with the same chunker.
- **Unified path:** `UnifiedAsrManager` decodes 15 s windows **sequentially** (no worker pool) with a fixed 15 s/2 s grid. A source comment explains: "Silence-aligned starts were measured to cost ~1 WER point on the 15 s offline encoder". Windows are merged with the same `ChunkProcessor.mergeChunks` plus `collapseSeamWordDuplicates`. It takes `[Float]` or `AVAudioPCMBuffer` only (no URL or disk-backed path).
- **Quality risk:** seams are where this library has had bugs. LongTranscription.md lists them: dropped boundary words, "glued words", "mid-word punctuation like "ye,ah" (issue #683)", scrambled sub-words across a seam (#825, fixed PR #830), "multi-second spans of clear speech missing at a seam whose overlap region is low-SNR — crosstalk, applause, soft speech (issue #758)", and "trailing words missing entirely when the final window decodes to all-blank on quiet recordings — ends early with high confidence and no error (issue #747)". Most are marked fixed. But the volume of seam fixes, across 41 commits between v0.16.1 and v0.17.7, shows this is an active area. Meeting audio (crosstalk, soft speech) is exactly the low-SNR case. The 1-hour Earnings-22 WER of 16.5% for v3 (see models doc) is the only long-form number.
- Upstream NVIDIA notes the PyTorch model can do "up to 24 minutes long with full attention (on A100 80GB) or up to 3 hours with local attention" ([v3 card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)). The Core ML export is fixed at 15 s, so FluidAudio cannot use long-context attention. Chunking is mandatory.
- Minimum input: `ASRError.invalidAudioData`, "Must be at least 300ms of 16kHz audio."

### Progress

- `AsrManager.transcriptionProgressStream` is an `AsyncThrowingStream<Double, Error>` with fraction updates for audio longer than 240,000 samples (15 s). The doc says verbatim: "Only one session is supported at a time." You must obtain the stream before calling `transcribe`.
- `UnifiedAsrManager` has **no** progress stream.

---

## 4. Unified path (`UnifiedAsrManager`): signatures and output

```swift
public actor UnifiedAsrManager {
    public init(configuration: MLModelConfiguration? = nil, config: UnifiedConfig = UnifiedConfig(),
                encoderPrecision: UnifiedEncoderPrecision = .int8)
    public func loadModels(from directory: URL) async throws
    public func loadModels(to directory: URL? = nil, configuration: MLModelConfiguration? = nil,
                           progressHandler: ProgressHandler? = nil) async throws
    public func configureVocabularyBoosting(vocabulary: CustomVocabularyContext, ctcModels: CtcModels,
                                            config: VocabularyRescorer.Config? = nil) async throws
    public struct TranscriptionWithTimings: Sendable { public let text: String; public let tokenTimings: [TokenTiming] }
    public func transcribe(_ samples: [Float]) async throws -> String
    public func transcribeWithTimings(_ samples: [Float]) async throws -> TranscriptionWithTimings
    public func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String
    public func cleanup() async
}
```

Differences from the TDT output:
- Returns `TranscriptionWithTimings`, not `ASRResult`. There is **no overall confidence and no duration** (you compute them yourself).
- `TokenTiming.confidence` is again the softmax probability of the emitted token (`UnifiedRnntDecoder`: "Softmax probability of the emitted token", from `token_prob`).
- **Timestamps are weaker.** RNNT has no duration head. Verbatim: "RNNT tokens are emitted *at* a frame and have no intrinsic duration, so every token gets a provisional one-frame end that is clamped back only when it would overrun its successor… These are emission times rather than forced-alignment boundaries: the decoder emits once it has heard enough context, so a token's start can sit slightly after the word's true onset." There is no emission-delay correction on this path (unlike TDT). The source doc comment explicitly names "word→speaker attribution" as an intended use.
- Vocabulary boosting: "Rescored text can replace words, so token timings no longer decode to the text verbatim". If boosting is on, `text` and `tokenTimings` can disagree.

---

## 5. Custom vocabulary (relevant because Biscotti's custom vocab is blocked on WhisperKit)

- `UnifiedAsrManager.configureVocabularyBoosting` (batch) exists, as does `SlidingWindowAsrManager.configureVocabularyBoosting` (streaming).
- The **TDT batch `AsrManager` has no boosting entry point.** The draft spec said boosting was only on the streaming manager. That is now partly wrong, because Unified batch has it too.
- Boosting needs a separate CTC model (`CtcModels`, Parakeet CTC 110M/0.6B) and rescores the final text. Out of scope here, noted only as an option.

---

## 6. Errors (verbatim enum)

```swift
public enum ASRError: Error, LocalizedError {
    case notInitialized, invalidAudioData, modelLoadFailed, processingFailed(String),
         modelCompilationFailed, unsupportedPlatform(String), streamingConversionFailed(Error),
         fileAccessFailed(URL, Error), encoderInstantiationFailed(String)
}
public enum AsrModelsError: LocalizedError, Sendable {
    case modelNotFound(String, URL), downloadFailed(String), loadingFailed(String), modelCompilationFailed(String)
}
```

These map onto Biscotti's existing `TranscriptionError` cases without new cases. The draft's mapping table in `specs/projects/fluid_audio_engine/functional_spec.md` §7 matches these enums.

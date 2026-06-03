# ArgMax STT + Diarization Research

## Summary

**V1 models:** **WhisperKit** (`openai_whisper-large-v3_turbo`) for speech-to-text and **SpeakerKit** (Pyannote v4 community-1, `argmaxinc/speakerkit-coreml`, ~33 MB) for speaker diarization -- both fully on-device, both free, both from the `argmax-oss-swift` SDK (MIT-licensed). Parakeet V3 and nvidia/sortformer-v2-1 are exclusively Argmax Pro SDK features and cannot be used on the free tier. Custom vocabulary is also Pro-only, but a partial workaround exists via Whisper's `promptTokens` (initial prompt) mechanism. Run the ML pipeline in an **XPC service** to isolate crashes and memory spikes from the host app, with a Swift actor managing model lifecycle inside the service. **Note: XPC + CoreML/WhisperKit is an untested combination that must be validated in E3.**

**Licensing note:** The `argmax-oss-swift` package is MIT-licensed, but vendors HuggingFace Hub Swift and Tokenizers sources under their original Apache-2.0 license inside ArgmaxCore. The free SpeakerKit community model (`speakerkit-coreml`) is CC-BY-4.0.

## Key Questions & Findings

### 1. Model Confirmation (PRIORITY): Parakeet V3 & sortformer-v2-1 on Free SDK

**Finding: Neither model is available on the free SDK. Both are Pro-only.**

- **Parakeet V3** is Argmax's optimized reimplementation of NVIDIA's Parakeet for Apple Silicon. It is distributed exclusively through the Argmax Pro SDK ([`argmaxinc/parakeetkit-pro`](https://huggingface.co/argmaxinc/parakeetkit-pro) HuggingFace repo, licensed under `argmax-fmod-license`) and requires a paid license. The `nvidia_parakeet-v3_494MB` model variant lives in that repo, including `AudioEncoder.mlmodelc`, `MelSpectrogram.mlmodelc`, `MultimodalLogits.mlmodelc`, and `TextDecoder.mlmodelc`. The free SDK (`argmax-oss-swift`) ships only OpenAI Whisper model variants via WhisperKit. The Argmax blog post "[Nvidia Frontier Speech Models on Argmax SDK](https://www.argmaxinc.com/blog/nvidia-frontier-speech-models-on-argmax-sdk)" explicitly positions Parakeet as a Pro feature. The README's Pro section lists "9x faster and higher accuracy models such as Nvidia Parakeet V3" as a Pro benefit.
- **nvidia/sortformer-v2-1** powers SpeakerKit Pro's diarization engine. With the launch of [Argmax Pro SDK 2](https://www.argmaxinc.com/blog/argmax-sdk-2), Argmax open-sourced their Pyannote v4 (community-1) implementation and moved to Sortformer for the Pro tier. The free `SpeakerKit` uses Pyannote v4 only; Sortformer models live in the `argmaxinc/speakerkit-pro` HuggingFace repo (168 MB total, includes sortformer + clusterer + embedder + segmenter).

**V1 model choices:**

| Component | V1 Choice (free, on-device) | Pro Alternative (paid) | Quality Notes |
|-----------|---------------------------|----------------------|---------------|
| STT | `openai_whisper-large-v3_turbo` (full-precision, ~3.1 GB on disk; or quantized `_turbo_1307MB` / `_turbo_954MB` variants) | Parakeet V3 (494 MB, 9x faster) | Competitive WER -- Argmax reports 2.41% WER / 99.8% QoI for the full-precision turbo variant on LibriSpeech; quantized variants trade some accuracy for size (see table in section 2) |
| Diarization | Pyannote v4 (community-1) via SpeakerKit (~33 MB, `argmaxinc/speakerkit-coreml`) | Sortformer v2-1 via Pro SDK; or Precision-2 via Argmax Marketplace (see future upgrade note in Recommendation) | "Matches the error rate of state-of-the-art systems such as Pyannote across 13 datasets" per Argmax |

Both V1 models are genuinely capable. Whisper large-v3-turbo is the industry standard open STT model optimized for speed (809M params, 4 decoder layers vs 32 in full large-v3, ~4-8x faster), and Pyannote v4 community-1 is well-regarded for diarization. The Pro models offer additional speed (Parakeet is ~9x faster than Whisper) and incrementally better diarization accuracy (Sortformer/Precision-2), but the free tier is solid for V1.

**Sources:**
- [argmax-oss-swift GitHub README](https://github.com/argmaxinc/argmax-oss-swift)
- [Nvidia Frontier Speech Models on Argmax SDK (blog)](https://www.argmaxinc.com/blog/nvidia-frontier-speech-models-on-argmax-sdk)
- [Argmax Pro SDK 2 (blog)](https://www.argmaxinc.com/blog/argmax-sdk-2)
- [SpeakerKit announcement (blog)](https://www.argmaxinc.com/blog/speakerkit)
- [pyannoteAI on Argmax SDK (blog)](https://www.argmaxinc.com/blog/pyannote-argmax)
- [argmaxinc/whisperkit-coreml on HuggingFace](https://huggingface.co/argmaxinc/whisperkit-coreml)
- [argmaxinc/speakerkit-coreml on HuggingFace](https://huggingface.co/argmaxinc/speakerkit-coreml) -- 33.1 MB total
- [argmaxinc/speakerkit-pro on HuggingFace](https://huggingface.co/argmaxinc/speakerkit-pro)
- [argmaxinc/parakeetkit-pro on HuggingFace](https://huggingface.co/argmaxinc/parakeetkit-pro)
- [pyannote/speaker-diarization-precision-2 on HuggingFace](https://huggingface.co/pyannote/speaker-diarization-precision-2)
- [pyannoteAI Pricing](https://www.pyannote.ai/pricing)

---

### 2. Model Download & Storage

**How models are downloaded:**
Both WhisperKit and SpeakerKit download models automatically from HuggingFace on first use. The Swift HuggingFace Hub client (vendored into ArgmaxCore as of v1.0.0) handles the download.

- `WhisperKit()` with no arguments auto-selects and downloads the recommended model for the device.
- `WhisperKit(WhisperKitConfig(model: "large-v3_turbo"))` pins a specific variant (use `"large-v3_turbo_1307MB"` for the quantized turbo).
- `SpeakerKit()` uses `PyannoteConfig()` defaults and downloads from `argmaxinc/speakerkit-coreml`.
- Models can be pre-downloaded via `diarizer.downloadModels()` / background download APIs.
- Background downloads are supported: `modelStore.downloadModelInBackground()` persists progress across foreground-to-background transitions and survives app kills on iOS.

**Where models are stored on disk:**
Default HuggingFace Hub cache: `~/.cache/huggingface/hub/` on macOS, structured as:
```
~/.cache/huggingface/hub/
├── models--argmaxinc--whisperkit-coreml/
│   └── snapshots/<revision>/openai_whisper-large-v3_turbo/
└── models--argmaxinc--speakerkit-coreml/
    └── snapshots/<revision>/...
```
The `WhisperKitConfig.modelFolder` property lets you override the storage location. The `HF_HUB_CACHE` environment variable also works.

**On-disk sizes:**

| Model | Identifier in `whisperkit-coreml` | Size | WER / QoI | Notes |
|-------|----------------------------------|------|-----------|-------|
| **Whisper large-v3-turbo (full-precision)** | `openai_whisper-large-v3_turbo` | **~3.1 GB** | 2.41% / 99.8% | Team choice; 809M params, full f16 weights. Best accuracy in the turbo family. |
| Whisper large-v3-turbo (quantized, recommended) | `openai_whisper-large-v3_turbo_1307MB` | ~1.3 GB | 2.6% / 97.7% | Mixed-bit quantized. Good balance of size vs. accuracy for 8 GB Macs. |
| Whisper large-v3-turbo (aggressive quant) | `openai_whisper-large-v3_turbo_1049MB` | ~1.0 GB | 4.81% / 91% | Noticeable accuracy drop. |
| Whisper large-v3-turbo (QLoRA compressed) | `openai_whisper-large-v3_turbo_954MB` | ~954 MB | -- | QLoRA compressed encoder+decoder variant. |
| Whisper large-v3 (Sept 2024, quantized) | `openai_whisper-large-v3-v20240930_626MB` | ~626 MB | -- | Previous recommendation; non-turbo, smaller but slower. |
| **SpeakerKit Pyannote v4 (community-1)** | (in `speakerkit-coreml` repo) | **~33 MB** | -- | Includes segmenter + embedder + clusterer CoreML models. |

All WhisperKit models are in the [`argmaxinc/whisperkit-coreml`](https://huggingface.co/argmaxinc/whisperkit-coreml) HuggingFace repo (30.8 GB total repo). Only the selected variant is downloaded. SpeakerKit models are in [`argmaxinc/speakerkit-coreml`](https://huggingface.co/argmaxinc/speakerkit-coreml) (33.1 MB total repo).

**First-run download UX:**
- Initial model loading may take 15-90 seconds because CoreML compiles the models on-device after the first download.
- Subsequent loads are "near-instant thanks to the OS-level compiled model cache" (Apple's `.mlmodelc` compilation cache).
- The download for the full-precision turbo model (~3.1 GB) will take several minutes depending on connection speed; the quantized `_1307MB` variant is faster to download and may be a better default. SpeakerKit's ~33 MB model downloads quickly.
- Steak should show a progress UI on first run ("Downloading speech models...") with the option to retry on failure. The SDK supports progress callbacks.

**Sources:**
- [Managing Models (Argmax Docs)](https://app.argmaxinc.com/docs/guides/managing-models)
- [HuggingFace Hub cache documentation](https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache)

---

### 3. Transcript Output Shape

WhisperKit's `transcribe()` returns `[TranscriptionResult]`. SpeakerKit's `diarize()` returns `DiarizationResult`. They are merged via `diarization.addSpeakerInfo(to: transcription)`.

**WhisperKit types** (from [Models.swift](https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Models.swift)):

```swift
// TranscriptionResult (reference type, thread-safe with @TranscriptionPropertyLock)
public class TranscriptionResult {
    public var text: String
    public var segments: [TranscriptionSegment]
    public var language: String
    public var timings: TranscriptionTimings
    public var seekTime: Float?
}

// TranscriptionSegment (value type, Hashable + Codable + Sendable)
public struct TranscriptionSegment {
    public var id: Int
    public var seek: Int
    public var start: Float          // seconds
    public var end: Float            // seconds
    public var text: String
    public var tokens: [Int]
    public var tokenLogProbs: [[Int: Float]]
    public var temperature: Float
    public var avgLogprob: Float
    public var compressionRatio: Float
    public var noSpeechProb: Float
    public var words: [WordTiming]?  // populated when wordTimestamps=true
    public var duration: Float       // computed: end - start
}

// WordTiming (value type, Codable + Sendable)
public struct WordTiming {
    public var word: String
    public var tokens: [Int]
    public var start: Float          // seconds
    public var end: Float            // seconds
    public var probability: Float
    public var duration: Float       // computed
}
```

**SpeakerKit types** (from [SpeakerKit source](https://github.com/argmaxinc/argmax-oss-swift/tree/main/Sources/SpeakerKit)):

```swift
// DiarizationResult (value type, Sendable)
public struct DiarizationResult {
    public let speakerCount: Int
    public let totalFrames: Int
    public let frameRate: Float
    public private(set) var segments: [SpeakerSegment]
    public var timings: (any DiarizationTimings)?
    // NOT public in v1.0.0 — see section 6 erratum:
    // public private(set) var speakerCentroidEmbeddings: [Int: [Float]]
    // centroidCosineDistance(between:and:) -> Float  (range 0.0-2.0)
    // nearestSpeakerCentroid(to:) -> Int?
    // Methods (public):
    // addSpeakerInfo(to:strategy:) -> [[SpeakerSegment]]
}

// SpeakerSegment (value type, Identifiable + Sendable)
public struct SpeakerSegment {
    public let id: UUID
    public let speaker: SpeakerInfo
    public let startTime: Float
    public let endTime: Float
    public let frameRate: Float
    public var startFrame: Int       // computed
    public var endFrame: Int         // computed
    public let transcription: TranscriptionSegment?
    public let speakerWords: [SpeakerWordTiming]
    public var text: String          // computed from speakerWords
}

// SpeakerInfo (enum, Hashable + Codable + Sendable)
public enum SpeakerInfo {
    case noMatch
    case multiple([Int])
    case speakerId(Int)              // cluster ID (0-based integer)
    // Computed:
    // speakerId: Int?
    // speakerIds: [Int]
    // description: "Speaker 1", "Multiple Speakers: [1, 2]", etc.
}

// SpeakerWordTiming (value type)
public struct SpeakerWordTiming {
    public let wordTiming: WordTiming
    public let speaker: SpeakerInfo
}
```

**Merging transcription + diarization:**
```swift
let speakerSegments: [[SpeakerSegment]] = diarization.addSpeakerInfo(to: transcription)
```
Two matching strategies:
- `.subsegment` (default): splits transcription segments at word gaps, assigns speakers to sub-segments. Uses `betweenWordThreshold` (default 0.15s) to split on pauses.
- `.segment`: assigns one speaker to each full transcription segment.

The result is `[[SpeakerSegment]]` -- an array of groups, where each group is an array of `SpeakerSegment` that includes the `speaker: SpeakerInfo`, timing info, and `speakerWords: [SpeakerWordTiming]` for word-level speaker attribution.

**Important note on word timestamps:** The free SDK provides word-level timestamps via `DecodingOptions(wordTimestamps: true)`, but these are Whisper's native word timestamps, not forced-alignment quality. The blog notes: "You lose word-level forced alignment in the open-source path." The word timestamps are still useful and good enough for matching with diarization, but they are not as precise as what the Pro SDK provides.

---

### 4. Custom Vocabulary Support

**Finding: Full custom vocabulary is Pro-only. A partial workaround exists for the free SDK.**

The Argmax Pro SDK supports up to 3,000 custom keywords that operate at runtime without model retraining. This is described as exceeding "most cloud APIs limited to a few hundred."

**Free SDK workaround via `promptTokens`:**
WhisperKit's `DecodingOptions` exposes:
- `promptTokens: [Int]?` -- "conditioning prompt for decoder" (equivalent to OpenAI Whisper's `initial_prompt`)
- `prefixTokens: [Int]?` -- "initial prefix for decoder"

The established workaround (from OpenAI Whisper community) is to set `promptTokens` to a tokenized string listing domain-specific terms. For example:
```swift
// Tokenize a prompt like: "Meeting about Steak App with Acme Corp. Participants: Sam, Jordan."
let promptText = "Transcript of a meeting about Steak App with Acme Corp. Participants: Sam, Jordan."
let promptTokens = tokenizer.encode(text: promptText)
let options = DecodingOptions(promptTokens: promptTokens)
```

This biases the decoder toward recognizing listed terms. It is not as reliable as the Pro SDK's custom vocabulary (which uses a separate vocabulary-matching pass), but it measurably helps with proper nouns, company names, and technical terms.

**Limits of the workaround:**
- The Whisper prompt window is ~224 tokens (about 100-150 words); you cannot list thousands of terms.
- It is a soft bias, not a guarantee -- the model may still mishear uncommon words.
- No word-level boosting or scoring; it is all-or-nothing on the prompt context.

**Recommendation:** Use the `promptTokens` approach in the free SDK. Build the API to accept a `[String]` vocabulary list, format it into a natural-language prompt, tokenize it, and pass it as `promptTokens`. This lets us swap to Pro's custom vocabulary later with no API change for callers.

**Sources:**
- [OpenAI Whisper prompt vs prefix discussion](https://github.com/openai/whisper/discussions/117)
- [Suggesting vocab for accuracy (Whisper community)](https://github.com/openai/whisper/discussions/328)
- [WhisperKit Configurations.swift source](https://github.com/argmaxinc/whisperkit/blob/main/Sources/WhisperKit/Core/Configurations.swift)

---

### 5. Input Streams: 1 vs 2

**Finding: The SDK takes a single merged `[Float]` audio array. It does not support time-aligned separate streams.**

Both `whisperKit.transcribe(audioArray:)` and `speakerKit.diarize(audioArray:)` accept a single `[Float]` array (16 kHz PCM). There is no API for providing two separate streams (mic + system audio) to aid diarization.

**Recommendation:**
- **Record** mic and system audio as separate streams (per audio research R1) for maximum flexibility.
- **Merge** the streams into a single mono mixdown before feeding to the SDK.
- **Use the known stream provenance** as a heuristic to identify "me": if the mic-only stream has audio energy at a timestamp where SpeakerKit identifies a speaker transition, the speaker active on the mic stream is likely "me." This is post-processing logic in Steak, not an SDK feature.
- Store both the separate streams and the merged file so we can re-process later if the SDK adds multi-stream support.

---

### 6. Diarization Labels & Cross-File Speaker ID

**Speaker labels:** SpeakerKit assigns integer cluster IDs (0-based) via `SpeakerInfo.speakerId(Int)`. The `description` property renders these as "Speaker 0", "Speaker 1", etc. There are also `.noMatch` and `.multiple([Int])` cases. The labels are **per-file** -- they are assigned by clustering within a single audio file and are not consistent across files.

**Cross-file speaker identification:**
- SpeakerKit exposes `speakerCentroidEmbeddings: [Int: [Float]]` on `DiarizationResult` -- these are the centroid embedding vectors for each speaker cluster.
- `DiarizationResult.centroidCosineDistance(between:and:)` computes distance between two embedding vectors (range 0.0-2.0).
- `DiarizationResult.nearestSpeakerCentroid(to:)` finds the closest speaker to a given embedding.
- **Speaker identification (voiceprint extraction + recognition across files):** The [SpeakerKit blog post](https://www.argmaxinc.com/blog/speakerkit) describes "extracting voiceprints for a given speaker and identifying them in novel contexts" as a planned feature. However, this is stated in a roadmap/future-looking section of that blog post, and we have not found a shipping API or confirmed timeline. **Treat this as unverified/aspirational until confirmed with the ArgMax team.**

> **ERRATUM (verified in E3 against argmax-oss-swift v1.0.0):** `speakerCentroidEmbeddings`, `centroidCosineDistance(between:and:)`, and `nearestSpeakerCentroid(to:)` do **not** exist as public API on `DiarizationResult` in v1.0.0. The centroid embeddings are computed internally during Pyannote clustering but are not surfaced to callers. Cross-file speaker matching via centroid embeddings is therefore **not currently possible** without an SDK change or custom extraction of the internal clustering state. This is an open question for the ArgMax team (see questions section).

**Recommendation for Steak:**
- ~~Store `speakerCentroidEmbeddings` from every `DiarizationResult` in the Meeting data model.~~ **(ERRATUM: not available in v1.0.0 -- see note above.** The `TranscriptResult` data model reserves a `speakerEmbeddings` field for future use, but it will be empty until the SDK exposes centroid embeddings or we implement custom extraction.)
- Build a simple speaker-matching system: after each meeting, compare centroid embeddings against a saved "known speakers" table using cosine distance. If distance is below a threshold, map the cluster ID to a known name. **(Blocked on embedding access -- add to ArgMax team questions.)**
- The "me" speaker can be bootstrapped using the mic-stream heuristic (see section 5) and then confirmed/stored as a voiceprint for future matching.
- This is our own application-layer logic, not an SDK feature. ~~It is feasible because the SDK exposes the raw embeddings.~~ It will be feasible once the SDK exposes centroid embeddings publicly, or if we extract them from the internal clustering state.

---

### 7. Isolation & Lifecycle

#### Isolation Architecture: XPC Service (Recommended)

**Why XPC over alternatives:**

| Approach | Crash Isolation | Memory Isolation | Main Thread Safety | Complexity |
|----------|----------------|------------------|--------------------|------------|
| **XPC Service** | Full process boundary; crash kills only XPC | Separate address space; memory spike only affects XPC | Guaranteed (separate process) | Medium |
| Background actor | None; crash takes down app | Shared address space; spike affects app | Depends on discipline | Low |
| Subprocess (Process/posix_spawn) | Full | Full | Guaranteed | High (no typed IPC, manual serialization) |

**XPC is the right choice** because:
1. CoreML can throw C++ exceptions that bypass Swift `try/catch` -- in the same process, this is a hard crash. In an XPC service, `launchd` restarts the service transparently.
2. Whisper large-v3-turbo can use significant RAM during inference (estimates below -- to be measured in E3). If the system is under memory pressure, the OS can terminate the XPC service (SIGKILL from Jetsam/memory daemon) without touching the host app. The host sees an `interruptionHandler` callback and can retry.
3. XPC services live in `Contents/XPCServices/` inside the app bundle. They get their own entitlements, can be non-sandboxed even if the host is sandboxed, and are managed by `launchd` (auto-launch on first message, auto-terminate when idle).
4. `NSXPCConnection` provides typed Swift interfaces via `@objc` protocols, making the IPC nearly as clean as a direct function call.

> **WARNING: XPC + WhisperKit/CoreML is UNTESTED.** No public documentation or community reports confirm that WhisperKit and CoreML inference work correctly inside an XPC service. Potential issues include: (a) Neural Engine (ANE) access from an XPC service process -- ANE scheduling may behave differently; (b) the CoreML compiled-model cache (`mlmodelc`) uses paths tied to the calling process's container, which may differ for the XPC service; (c) entitlement requirements for CoreML/ANE from a helper process are undocumented; (d) HuggingFace Hub cache access paths may need explicit configuration. **This MUST be validated early in E3 -- build a minimal XPC + WhisperKit proof-of-concept before building the full library.** If XPC proves unworkable, the fallback is a background Swift actor in-process (loses crash isolation but retains memory isolation via unloading).

**XPC design for Steak:**

```
Steak.app
├── Contents/
│   ├── MacOS/Steak          (main app process)
│   └── XPCServices/
│       └── SteakTranscriber.xpc   (ML worker)
│           ├── Info.plist
│           └── SteakTranscriber    (executable)
```

The XPC service hosts WhisperKit + SpeakerKit. The main app sends audio file URLs and receives transcript results. The connection protocol:

```swift
@objc protocol TranscriberServiceProtocol {
    func processAudio(
        at fileURL: URL,
        modelName: String,
        customVocabulary: [String],
        reply: @escaping (Data?, Error?) -> Void  // JSON-encoded TranscriptResult
    )
    func downloadModels(
        modelName: String,
        reply: @escaping (Error?) -> Void
    )
    func unloadModels(
        reply: @escaping () -> Void
    )
    func healthCheck(
        reply: @escaping (Bool) -> Void
    )
}
```

Note: `NSXPCConnection` requires `@objc` protocols. Our `TranscriptResult` (Codable) is serialized to JSON `Data` for transport across the XPC boundary, then decoded on the app side. This is a clean separation -- the app never imports WhisperKit/SpeakerKit directly.

**Error recovery:** The host app sets an `interruptionHandler` on the `NSXPCConnection`. If the XPC service crashes:
1. The handler fires.
2. The connection remains valid -- the next message auto-relaunches the service.
3. The app retries the `processAudio` call (or shows an error to the user if it fails again).

#### Memory Lifecycle

**Can STT and diarization run one at a time?**
Yes. WhisperKit and SpeakerKit are independent frameworks with separate models:
- WhisperKit loads the Whisper encoder + decoder CoreML models.
- SpeakerKit loads the Pyannote segmenter + embedder CoreML models.

They share nothing. You can:
1. Load WhisperKit, transcribe, unload.
2. Load SpeakerKit, diarize, unload.
3. Merge results.

This is the recommended approach for memory-constrained devices (8 GB RAM Macs). On 16+ GB Macs, both can be resident simultaneously for speed.

**Peak memory estimates (ESTIMATES -- must be measured in E3):**

The numbers below are derived from public benchmarks and model parameter counts, not from our own profiling. Actual peak memory will depend on audio length, batch size, and CoreML scheduling. E3 must measure these on real hardware.

| Component | Model Params | On-Disk | Estimated Inference Peak | Notes |
|-----------|-------------|---------|-------------------------|-------|
| WhisperKit (`large-v3_turbo`, full f16) | 809M | ~3.1 GB | **~2-3 GB** (estimate) | Full-precision f16 weights; 809M params at 2 bytes/param = ~1.6 GB just for weights, plus activations/KV cache. Public benchmarks cite ~6 GB VRAM on GPU/fp16 (CUDA) but CoreML's unified memory + ANE scheduling is different; expect lower. The previous `large-v3` (1550M params, full) peaked at ~3-4 GB in PyTorch, ~1.5 GB in CoreML quantized. Turbo has ~half the params, so scaling suggests ~1-2 GB for quantized, ~2-3 GB for full f16. |
| WhisperKit (`large-v3_turbo_1307MB`, quantized) | 809M | ~1.3 GB | **~1-1.5 GB** (estimate) | Mixed-bit quantized; substantially lower than full f16. Better fit for 8 GB Macs. |
| SpeakerKit (Pyannote v4 community-1) | small | ~33 MB | **~50-150 MB** (estimate) | 33 MB on disk; embedding computation adds overhead proportional to audio length |
| **Sequential peak** (STT then diarize with unload) | - | - | **~2-3 GB** (full) / **~1-1.5 GB** (quantized) | Whichever stage has the higher peak |
| **Both resident** | - | - | **~2.5-3.5 GB** (full) / **~1.5-2 GB** (quantized) | Not recommended on 8 GB Macs |

**Model load/unload API:**
- WhisperKit: `WhisperKitConfig(load: false)` creates without loading; models load lazily on first `transcribe()`. No explicit `unload()` -- set the `WhisperKit` instance to `nil` to release.
- SpeakerKit: `PyannoteConfig(load: false)` for lazy loading. `diarizer.unloadModels()` explicitly unloads. `diarizer.loadModels()` explicitly loads.

**First-load compilation:** CoreML compiles `.mlpackage`/`.mlmodel` files on-device the first time. This takes 15-90 seconds for Whisper large-v3-turbo (less than full large-v3 due to fewer decoder layers, but the encoder is identical). The compiled `.mlmodelc` is cached by the OS and subsequent loads are near-instant.

**Minimum hardware floor:**
- 8 GB Apple Silicon Mac (M1 base): The full-precision `large-v3_turbo` (~3.1 GB) is a tight fit; public guidance says "large-v3-turbo (1.6 GB model [the original PyTorch checkpoint]) is the largest you should comfortably run" on 8 GB. **Use the quantized `_1307MB` variant on 8 GB Macs**, run STT then diarization sequentially, and unload between. Measure actual headroom in E3.
- 16 GB Apple Silicon Mac: comfortable. Full-precision turbo + SpeakerKit can both be resident simultaneously.
- Intel Macs: **not supported**. CoreML's Neural Engine acceleration requires Apple Silicon. WhisperKit targets arm64 only.
- macOS 15+ required (per our baseline; WhisperKit technically supports macOS 14+).

#### Composing with the processAudio API

Inside the XPC service (pending XPC validation in E3), the flow is:

```swift
actor TranscriberWorker {
    private var whisperKit: WhisperKit?
    private var speakerKit: SpeakerKit?

    func processAudio(fileURL: URL, modelName: String, vocabulary: [String]) async throws -> TranscriptResult {
        // 1. Load audio
        let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: fileURL.path)

        // 2. Load/reuse WhisperKit
        if whisperKit == nil {
            let config = WhisperKitConfig(model: modelName)  // e.g. "large-v3_turbo"
            whisperKit = try await WhisperKit(config)
        }

        // 3. Transcribe
        let options = DecodingOptions(
            wordTimestamps: true,
            promptTokens: formatVocabularyPrompt(vocabulary)
        )
        let transcriptionResults = try await whisperKit!.transcribe(audioArray: audioArray, decodeOptions: options)

        // 4. Load/reuse SpeakerKit (can coexist or unload WhisperKit first on 8GB)
        if speakerKit == nil {
            speakerKit = try await SpeakerKit()
        }

        // 5. Diarize
        let diarization = try await speakerKit!.diarize(audioArray: audioArray)

        // 6. Merge
        let speakerSegments = diarization.addSpeakerInfo(to: transcriptionResults)

        // 7. Package into our TranscriptResult
        return TranscriptResult(from: speakerSegments, diarization: diarization)
    }

    func unloadModels() async {
        whisperKit = nil
        await speakerKit?.unloadModels()
        speakerKit = nil
    }
}
```

The actor runs inside the XPC service process. The main app never loads WhisperKit or SpeakerKit. The XPC service can be idle-terminated by `launchd` when not in use, freeing all model memory.

---

### 8. WhisperKit Live Audio Input (Addendum)

**Does WhisperKit support direct/live audio-buffer input?**

Yes, partially:
- **File-based:** `transcribe(audioPath:)` -- loads and processes a complete file.
- **Float-array-based:** `transcribe(audioArray: [Float])` -- accepts pre-loaded 16 kHz PCM float arrays. This is the primary API for custom audio pipelines.
- **Streaming/live:** The CLI supports `--stream` for microphone input. Programmatically, WhisperKit accepts a `SegmentDiscoveryCallback` to receive incremental results during transcription. The Pro SDK's local server provides a WebSocket-based real-time streaming API.

**Tradeoffs for Steak:**

| Approach | Pros | Cons |
|----------|------|------|
| **Capture to file, process after** (current plan) | Lightweight recorder; can re-transcribe with better models; no ML memory during meeting; rock-solid recording | No live transcript; delay after meeting ends |
| **Feed live audio buffers to WhisperKit** | Near-real-time transcript during meeting | ~2-3 GB RAM during entire meeting (full turbo); NPU/GPU load during meeting may cause thermal throttling; model crash takes down recorder; can't easily re-transcribe; diarization doesn't support streaming in free SDK |

**Recommendation:** Stick with the capture-to-file approach. The "lightweight, never-crashing recorder" goal conflicts directly with keeping a multi-GB ML model resident and running inference during the meeting. The WhisperKit streaming capability is documented here for future reference -- if Steak ever wants a "live captions" feature (P2+), it could run WhisperKit streaming in a separate XPC service that is independent of the recorder, but this is not V1.

---

## Recommendation

### Models
- **STT (V1):** `openai_whisper-large-v3_turbo` via WhisperKit (free SDK). Full-precision f16, ~3.1 GB on disk, 809M parameters, ~4-8x faster than full large-v3 with competitive WER (2.41% on LibriSpeech per Argmax benchmarks). Pin this exact variant in code. For 8 GB Macs, offer the quantized `openai_whisper-large-v3_turbo_1307MB` (~1.3 GB, 2.6% WER) as an alternative.
- **Diarization (V1):** Pyannote v4 (community-1) via SpeakerKit (free SDK). ~33 MB model, ~1 second for 4 minutes of audio. Fully on-device, CC-BY-4.0 licensed. Matches SotA error rates per Argmax's Interspeech 2025 benchmarks across 13 datasets.

**Future upgrade paths** (not V1):
- **Diarization -- Precision-2:** pyannoteAI's commercial [Precision-2](https://huggingface.co/pyannote/speaker-diarization-precision-2) model claims ~37% better accuracy than community-1. It is available on-device through the [Argmax Marketplace](https://www.argmaxinc.com/blog/pyannote-argmax) as a SpeakerKit-compatible drop-in ("same familiar APIs, no code changes required"). However, it is paid (pricing not public; contact Argmax) and its default cloud API path sends audio to pyannoteAI servers, which conflicts with Steak's privacy goals. The on-device Marketplace variant is the only privacy-compatible option. Rejected for V1 due to cost and licensing complexity; revisit post-V1 if community-1 accuracy proves insufficient.
- **Diarization -- Sortformer:** nvidia/sortformer-v2-1 via Argmax Pro SDK. "Generational accuracy leap" per Argmax. Pro-only.
- **STT -- Parakeet V3:** Via Argmax Pro SDK. 9x faster than Whisper, competitive accuracy. Swap requires only a config change in `ArgMaxProcessor`.

### Isolation Architecture
- **XPC service** (`SteakTranscriber.xpc`) bundled in `Contents/XPCServices/` -- **pending validation in E3** (see warning in section 7).
- `NSXPCConnection` with `@objc` protocol for typed IPC.
- `interruptionHandler` for crash recovery.
- The main app imports only `ArgMaxKit` (our wrapper library), never WhisperKit/SpeakerKit directly.
- **Fallback if XPC proves unworkable:** background Swift actor in-process (loses crash isolation, retains thread safety).

### Refined API Design

**Public API (ArgMaxKit library, used by main app):**

```swift
/// Configuration for the processor
public struct ProcessorConfig: Sendable, Codable {
    public let sttModel: String          // e.g. "large-v3_turbo" or "large-v3_turbo_1307MB"
    public let sttModelRepo: String      // e.g. "argmaxinc/whisperkit-coreml"
    public let enableWordTimestamps: Bool // default true
    public let diarizationStrategy: DiarizationStrategy // .subsegment (default) or .segment

    public static let `default` = ProcessorConfig(
        sttModel: "large-v3_turbo",
        sttModelRepo: "argmaxinc/whisperkit-coreml",
        enableWordTimestamps: true,
        diarizationStrategy: .subsegment
    )
}

public enum DiarizationStrategy: String, Sendable, Codable {
    case subsegment  // split at word gaps, assign speakers
    case segment     // one speaker per transcription segment
}

/// The main entry point. Manages XPC connection to the ML worker.
public actor ArgMaxProcessor {
    public init(config: ProcessorConfig = .default) throws

    /// Download models if not already cached. Call on first launch.
    /// Reports progress via the callback.
    public func ensureModelsDownloaded(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws

    /// Process an audio file and return a rich transcript.
    public func processAudio(
        _ file: URL,
        customVocabulary: [String] = []
    ) async throws -> TranscriptResult

    /// Explicitly unload models from memory (XPC service stays alive but idle).
    public func unloadModels() async throws

    /// Check if the XPC service is responsive.
    public func isAvailable() async -> Bool
}
```

**TranscriptResult (rich, Codable, stored in Meeting data model):**

```swift
public struct TranscriptResult: Sendable, Codable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let modelVersion: String              // e.g. "large-v3_turbo"
    public let language: String                   // detected language code
    public let speakerCount: Int
    public let segments: [TranscriptSegment]
    public let speakerEmbeddings: [Int: [Float]]  // speaker ID -> centroid embedding (reserved; empty in v1.0.0 — see section 6 erratum)
    public let processingDuration: TimeInterval   // how long transcription took
}

public struct TranscriptSegment: Sendable, Codable, Identifiable {
    public let id: UUID
    public let speakerID: Int?                   // nil if .noMatch
    public let speakerLabel: String              // "Speaker 0", "Unknown", etc.
    public let startTime: TimeInterval           // seconds from audio start
    public let endTime: TimeInterval
    public let text: String
    public let confidence: Float                 // avgLogprob from Whisper
    public let noSpeechProbability: Float
    public let words: [TranscriptWord]?          // word-level detail if enabled
}

public struct TranscriptWord: Sendable, Codable {
    public let word: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let probability: Float
    public let speakerID: Int?                   // from SpeakerWordTiming
}
```

This captures everything the SDK provides in a clean Codable shape suitable for SwiftData storage. The `speakerEmbeddings` field is reserved for cross-file speaker matching described in section 6, but will be empty in v1.0.0 since centroid embeddings are not exposed by the free SDK (see section 6 erratum). The `modelVersion` field supports the re-transcription use case (re-process with a newer model and compare).

---

## Risks & Gotchas

1. **CoreML first-compilation delay.** The first time a model loads on a device, CoreML compiles it on-device (15-90 seconds for large-v3-turbo). This happens once and is cached, but users will see a significant wait on first use. Mitigate with a clear "Preparing speech models..." UI and background pre-compilation during onboarding.

2. **Memory pressure on 8 GB Macs.** The full-precision `large-v3_turbo` has 809M parameters and ~3.1 GB on disk; inference peak memory is estimated at ~2-3 GB (to be measured in E3). On an 8 GB Mac with a browser and Zoom open, this will likely cause memory pressure. The XPC service may be killed by the system. Mitigate: (a) default to the quantized `_1307MB` variant on 8 GB Macs; (b) run STT and diarization sequentially, not simultaneously; (c) unload models immediately after processing. All peak-memory figures in this doc are estimates -- **E3 must measure actual usage on 8 GB and 16 GB hardware.**

3. **XPC + CoreML is UNTESTED.** This is the recommended isolation architecture, but no public reports confirm WhisperKit / CoreML inference works inside an XPC service. ANE access, model cache paths, and entitlements from a helper process are all unverified. E3 must validate this early with a minimal proof-of-concept. Fallback: in-process background actor.

4. **XPC protocol limitations.** `NSXPCConnection` requires `@objc` protocols with Foundation types. Our `TranscriptResult` must be serialized to `Data` (JSON) for transport. This adds some overhead but is negligible for transcript-sized payloads. Swift Distributed Actors are an alternative but are less battle-tested for XPC.

5. **No custom vocabulary on free SDK.** The `promptTokens` workaround helps but is limited to ~224 tokens and is a soft bias. If custom vocabulary accuracy is critical for Steak's value proposition, the Pro SDK may be necessary. Cost/licensing for Pro should be evaluated.

6. **Word timestamps are approximate.** The free SDK's word timestamps come from Whisper's built-in mechanism, not forced alignment. They are adequate for diarization matching and UI highlighting, but not sample-accurate. The Pro SDK offers forced alignment.

7. **Speaker labels are per-file.** "Speaker 0" in meeting A is not the same as "Speaker 0" in meeting B. Our planned cross-file matching via centroid embeddings is custom application logic, but depends on the SDK exposing centroid embeddings publicly (not the case in v1.0.0 -- see section 6 erratum). The cosine-distance threshold will need tuning once access is available.

8. **No offline model bundling (easily).** Models are downloaded from HuggingFace on first use. If the user is offline during first launch, transcription will not work. We should detect this and prompt the user to connect. Bundling the SpeakerKit model (~33 MB) in the app is feasible; the STT model (1.3-3.1 GB) is too large to bundle.

9. **Mixed licensing.** The `argmax-oss-swift` package itself is MIT-licensed, but it vendors HuggingFace Hub Swift and Tokenizers sources under their original Apache-2.0 license inside ArgmaxCore. The free SpeakerKit community model is CC-BY-4.0 (attribution required). Pyannote Precision-2 (if pursued) has commercial licensing via Argmax Marketplace or pyannoteAI. Parakeet Pro models use `argmax-fmod-license`.

10. **SDK is rapidly evolving.** v1.0.0 shipped May 2026 with significant API changes (WhisperKit renamed, TranscriptionResult became a class, deprecated overloads). Pin to a specific version and expect to manage SDK updates carefully.

11. **Full-precision turbo download size.** The full `large-v3_turbo` is ~3.1 GB -- a non-trivial first-run download. The quantized `_1307MB` variant cuts this to ~1.3 GB with only a minor accuracy trade (2.6% vs 2.41% WER). Consider defaulting to the quantized variant and offering the full-precision model as an opt-in "high quality" mode in settings.

12. **Precision-2 upgrade requires commercial license.** If V1 diarization accuracy proves insufficient, upgrading to pyannote Precision-2 via Argmax Marketplace is the privacy-compatible path but requires paid licensing (pricing not public). The cloud API path sends audio off-device and is incompatible with Steak's privacy goals.

---

## Open Questions for the Team

### For the ArgMax Team

We have been building Steak, a macOS meeting recorder that uses the free `argmax-oss-swift` SDK for post-meeting transcription with WhisperKit + SpeakerKit. Before we finalize the implementation, we would appreciate confirmation on a few points:

**Confirm this approach sounds good:**
> We plan to use `openai_whisper-large-v3_turbo` for STT and Pyannote v4 (community-1) via SpeakerKit for diarization, processing audio files after meetings end (not real-time). We want to run both in an XPC service for crash isolation (has anyone tested WhisperKit/CoreML inside an XPC service?). We capture mic + system audio as separate streams, merge to mono for SDK input, and use the mic stream to heuristically identify "me." We would like to store speaker centroid embeddings and use cosine distance to match speakers across meetings, but we found that `speakerCentroidEmbeddings` is not exposed as public API in v1.0.0 (see section 6 erratum) -- is there a way to access these, or is this planned? Custom vocabulary is passed via `promptTokens`. Does this approach sound reasonable, and are there any pitfalls you would flag?

**Specific questions:**

1. **Sequential vs. parallel model loading:** Is there a recommended order for running WhisperKit then SpeakerKit on the same audio? Any benefit to loading both simultaneously versus sequentially? Does unloading WhisperKit before loading SpeakerKit cause any issues with the audio processor?

2. **Centroid embedding access and stability:** We could not find `speakerCentroidEmbeddings` as public API on `DiarizationResult` in v1.0.0 (see section 6 erratum). Is there a supported way to access per-speaker centroid embeddings for cross-file matching? If so: how stable are they across different audio conditions (different microphones, noise levels, recording quality)? Is cosine distance the right metric, and what threshold would you suggest for "same speaker" matching?

3. **promptTokens for vocabulary:** Are there best practices for formatting the `promptTokens` to maximize recognition of specific terms (company names, people's names)? Any gotchas with the token limit?

4. **XPC compatibility (critical):** Has WhisperKit / SpeakerKit been tested inside an XPC service? Any known issues with CoreML inference (especially ANE scheduling, model cache paths) from a helper process? We plan to run non-sandboxed for now but want to confirm this is a viable isolation strategy before building on it.

5. **Model update strategy:** When a new/better Whisper model appears in `argmaxinc/whisperkit-coreml`, what is the recommended update path? Can we safely download a new model variant alongside the old one, or should we delete old models first?

6. **8 GB Mac guidance:** What is your recommended model for an 8 GB M1 MacBook Air? Is the full-precision `large-v3_turbo` (~3.1 GB) realistic, or should we default to `large-v3_turbo_1307MB` (quantized) on those machines?

7. **Pro SDK migration path:** If we later move to Pro for Parakeet + Sortformer + custom vocabulary, how much of our WhisperKit/SpeakerKit integration code can we reuse? Is the Pro API a superset of the free API?

8. **pyannote Precision-2 (future interest):** We are shipping V1 with the free community-1 model but may want to upgrade to Precision-2 via Argmax Marketplace post-launch. For planning purposes: what is the pricing/licensing model for the on-device Marketplace version? Does the "no code changes required" claim mean we literally just change a config line, or are there additional setup steps?

### For the Steak Team

1. **Diarization accuracy bar:** V1 ships with Pyannote v4 community-1. If real-world testing reveals insufficient speaker separation (e.g., frequent misattribution in 3+ speaker meetings), Precision-2 via Argmax Marketplace is the upgrade path -- but requires commercial licensing. Monitor diarization quality in V1 to decide if/when to pursue this.

2. **Pro SDK budget (custom vocabulary + Parakeet):** Custom vocabulary is Pro-only. If vocab accuracy is critical for user value (e.g., correctly spelling "Acme Corp" in every transcript), we should evaluate Pro licensing cost vs. the `promptTokens` workaround.

3. **Full-precision turbo vs quantized as default:** The team chose `large-v3_turbo` (full, ~3.1 GB). On 8 GB Macs this is a tight fit. Should we: (a) always use full-precision and accept that 8 GB Macs may struggle, (b) auto-detect available RAM and select quantized `_1307MB` on 8 GB machines, or (c) default to quantized everywhere and offer full-precision as an opt-in? E3 memory measurements will inform this.

4. **Cross-file speaker matching UX:** The embedding-based matching is feasible but imperfect. How do we handle mismatches? Suggest a "Speaker Management" UI where users can review and correct assignments, or keep it fully automatic with LLM-based name-matching as the primary approach (P2)?

5. **First-launch model download:** Should we download models during onboarding (explicit step with progress bar), or lazily on first transcription attempt? Onboarding is better UX but delays first use. The 3.1 GB download for full-precision turbo makes this more important than it was for the 626 MB model.

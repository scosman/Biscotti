# FluidAudio: STT Models, Runtime, Punctuation, Licenses

Pinned version: **FluidAudio v0.17.7** (tag commit `503b4bd1`, 2026-10-07). This is the latest tag as of 2026-10-21; `main` is 10+ commits ahead (unreleased). All source references below are to v0.17.7 unless marked "main".

Source repo: <https://github.com/FluidInference/FluidAudio>. I cloned the repo and read the source directly. The docs lag the source (see [batch-api-and-output.md](./batch-api-and-output.md#docs-vs-source)).

---

## 1. Which STT models FluidAudio runs

FluidAudio has many ASR back-ends. Only the Parakeet batch ones are relevant to Biscotti (batch, English-first, possibly multilingual).

### The Parakeet TDT family (`AsrManager` + `AsrModels`, enum `AsrModelVersion`)

From `Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift` (verbatim enum, comments shortened):

```swift
public enum AsrModelVersion: Sendable {
    case v2
    case v3
    case redux     // moondream ternary re-training of v3
    case ultra     // moondream full-precision post-training of v3; int8 encoder
    case phonon2   // Fermion Research QAT re-training of v3, English only (iOS 18+/macOS 15+)
    case tdtCtc110m
    case tdtJa
}
```

| Version | HF repo (from `ModelNames.swift` `Repo`) | Languages | Notes |
|---|---|---|---|
| `.v2` | `FluidInference/parakeet-tdt-0.6b-v2-coreml` | English | "Use v2 if you only need English, it is a bit more accurate" ([Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/Benchmarks.md)) |
| `.v3` | `FluidInference/parakeet-tdt-0.6b-v3-coreml` | 25 European | **Library default** (`version: AsrModelVersion = .v3` on every `AsrModels` API). ~480 MB download. |
| `.ultra` | `FluidInference/parakeet-ultra-coreml` (base `moondream/parakeet-ultra`) | 25 European | Docs now call it "**Recommended** for new integrations" ([Models.md](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/Models.md)). Same API as v3 (`isV3Family`). 595 MB int8 encoder. Added in v0.17.3 (2026-09-24). |
| `.redux` | `FluidInference/parakeet-redux-coreml` | 25 European | 2-bit encoder (~220 MB dir). Worse English. "several-minute first compile". macOS 15+. |
| `.phonon2` | `FluidInference/phonon-2-coreml` | English | Fastest on ANE; slightly worse WER than v3. macOS 15+. Added v0.17.5 (2026-10-01). |
| `.tdtCtc110m` | `FluidInference/parakeet-tdt-ctc-110m-coreml` | English | 110M params, 3.01% WER test-clean. |
| `.tdtJa` | `FluidInference/parakeet-0.6b-ja-coreml` | Japanese | Not relevant. |

### Parakeet Unified EN 0.6B (`UnifiedAsrManager`)

- Separate manager and separate API (not `AsrManager`): `Sources/FluidAudio/ASR/Parakeet/Unified/UnifiedAsrManager.swift`.
- HF repo `FluidInference/parakeet-unified-en-0.6b-coreml`, base model `nvidia/parakeet-unified-en-0.6b` (released 2026-04-07).
- FastConformer-**RNNT** (not TDT), so no per-token duration head. English only. Punctuation + capitalization (all sources agree; see §3).
- Batch path uses a full-attention 15 s offline encoder and 2 s window overlap. int8 encoder default (~565 MB per encoder, from the `UnifiedEncoderPrecision` doc comment); fp16 available.

### Other ASR back-ends in v0.17.7 (not relevant, listed for completeness)

Cohere Transcribe (14 langs, 35 s per-call cap), SenseVoiceSmall, Paraformer (zh), Canary, Nemotron streaming (en + multilingual), Parakeet EOU streaming. The repo also had an experimental Qwen3 ASR back-end that was **removed** in commit `17081252` ("chore(asr): remove experimental Qwen3 ASR backend (#676)"). This is a signal of churn: back-ends come and go.

---

## 2. Runtime (Core ML / ANE / GPU)

- Everything runs as **Core ML** models downloaded as pre-compiled `.mlmodelc` bundles from Hugging Face. No ONNX, no Metal kernels, no MLX.
- Default compute units: `MLModelConfigurationUtils.defaultConfiguration(computeUnits: .cpuAndNeuralEngine)`.
- TDT family placement (from `AsrModels.swift`):
  - Preprocessor: **`.cpuOnly`** ("100% of the the operations map to the CPU anyways").
  - Encoder: config default (`.cpuAndNeuralEngine`), overridable via `encoderComputeUnits:`. Verbatim comment: "It can be overridden to `.cpuAndGPU`, which is ~24% faster on Apple Silicon GPUs (17.8ms vs 23.5ms per 15s window, M-series) for ~+8% end-to-end RTFx, WER-neutral. ANE remains the default because it is far more power-efficient on iOS".
  - Decoder + joint: `.cpuAndNeuralEngine`.
- Unified: encoder on ANE (int8 is coerced away from GPU because "under `.all` CoreML sends the quantized ops to MPSGraph, which fails its MLIR pass and aborts"); decoder + joint are **`.cpuOnly`**; mel spectrogram is computed in Swift (no Core ML preprocessor).
- Apple Silicon is required: `AsrModels.isModelValid` throws `ASRError.unsupportedPlatform("Parakeet models require Apple Silicon")` on non-Apple-Silicon.
- Package minimum: `.macOS(.v14)`. Redux and Phonon-2 need macOS 15 (iOS 18 Core ML ops). Biscotti is macOS 15+, so all variants are available.
- First-load cost: Core ML compiles the model for the ANE on first load. FluidAudio's own numbers are for iPhones only (encoder cold 3.4 s on iPhone 16 Pro Max, 4.4 s on iPhone 13). I found no Mac first-load number. Redux has a "several-minute first compile".

### Performance (FluidAudio's own measurements; no independent Mac benchmark found)

| Source | Model | Set | RTFx | WER |
|---|---|---|---|---|
| [Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/Benchmarks.md) (M4 Pro, macOS 26.0) | v3 | LibriSpeech test-clean | 155.6x overall | 2.5% avg |
| same | v2 | test-clean | 145.8x | 2.1% avg |
| same (M5 Pro, macOS 27, ANE) | v3 | **60-min Earnings-22 concat** | **335x** | **16.5%** |
| same | ultra | 60-min Earnings-22 concat | 457x | 13.5% |
| same | phonon2 | 60-min Earnings-22 concat | 480x | 17.2% |
| same (M5 Pro, macOS 26) | Unified batch | test-clean | 123.3x | 2.15% avg / 1.68% aggregate |
| [Unified/benchmark.md](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Sources/FluidAudio/ASR/Parakeet/Unified/benchmark.md) | v3 vs Unified (same harness) | test-clean | 110x vs 144x | 2.6% vs 2.16% |

What this means for Biscotti:
- At 335x, a 1-hour meeting is about **11 s** of STT on an M5 Pro. Even at 100x it is 36 s. Speed is not a concern.
- **The long-form WER is the number that matters, and it is much worse than the short-clip WER.** 16.5% on the 1-hour Earnings-22 file (v3) versus NVIDIA's own 11.42% on Earnings-22 for the PyTorch model ([nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)). The references differ (FluidAudio uses "the chunk transcripts" of a 4-call concatenation), so this is not apples-to-apples. But it agrees with FluidAudio's own [LongTranscription.md](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/ASR/LongTranscription.md): "Most long-transcription regressions happen at chunk seams". I found no measured FluidAudio WER on AMI or other meeting audio for ASR (AMI is used only for the diarizer).
- Ultra is about 3 WER points better than v3 on the 1-hour file at the same speed.
- Memory: I found **no published peak-RAM figure** for FluidAudio ASR. Inference from the code: the model-weight footprint is about the size of the download (~480–630 MB). The URL path above `streamingThreshold` (480,000 samples, ~30 s) is disk-backed ("constant memory usage (~1.2MB)" for audio). The `[Float]` path keeps the whole clip in memory (1 h at 16 kHz ≈ 230 MB, which Biscotti already holds today). `parallelChunkConcurrency` defaults to **4** cloned `AsrManager` workers. The clones share the same `MLModel` instances (`makeWorkerClone()` passes the same `AsrModels`), so they should not multiply weight memory. This is unverified on hardware.
- Energy: ANE by default. FluidAudio publishes no Mac energy numbers.

---

## 3. Punctuation and capitalization per model: the doc contradiction is resolved

**Claim to test:** FluidAudio's [Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/Benchmarks.md) says verbatim: "Parakeet TDT v3 = 2.6% Avg WER / 110x RTFx (multilingual, no punctuation). For English files, Unified batch wins on WER, throughput, and punctuation". The table in `Sources/FluidAudio/ASR/Parakeet/Unified/benchmark.md` has a "Punctuation/caps" column that says "no" for TDT v3.

**Verdict: TDT v3 (and v2, ultra) DOES emit punctuation and capitalization through FluidAudio. The "no punctuation" claim in Benchmarks.md and Unified/benchmark.md is wrong.** Confidence is high, based on four independent lines of evidence:

1. **NVIDIA model card** ([nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), fetched 2026-10-21): the output includes "Automatic punctuation and capitalization" along with "Accurate word-level and segment-level timestamps."
2. **The vocabulary FluidAudio actually downloads.** I downloaded `parakeet_vocab.json` from `FluidInference/parakeet-tdt-0.6b-v3-coreml` (the file `AsrModels.load` uses; 8,192 entries). It contains `','` (id 7877), `'.'` (7883), `'?'` (7956), `'!'` (8020), and **740** pieces whose first letter is upper-case (for example `' The'` id 1502, `' For'` id 3108, `' I'` id 380). A model with no PnC would not need case-twinned word pieces.
3. **FluidAudio's own v3 code handles punctuation and case.** `ASRConstants.punctuationTokens` = `[7883, 7956, 8020]`. Its doc comment says: "Sentence-final punctuation token IDs (`.` `?` `!`) in the parakeet-tdt-0.6b-v3 vocabulary" (fixed for the v3 vocabulary in #905). LongTranscription.md lists v3 seam failure modes: "mid-word punctuation like `"ye,ah"`", "sentence breaks or punctuation that move", and "A window that begins mid-sentence biases the decoder to capitalize its first word as a false sentence start … `…the meeting Meeting was…` (issue #706)". The fix is `caseVariantCanonicalIds` (case-folded seam matching), which only makes sense if the output is cased.
4. **Downstream apps.** LocalFlow (a FluidAudio-based macOS app) describes v3 output as "punctuation and capitalization included" (via [search summary](https://github.com/gdrmedia/localflow)). MacParakeet ([repo](https://github.com/moona3k/macparakeet)) ships v3 as its default. It labels Unified as "English-only punctuated opt-in", which repeats the same ambiguous framing.

**Probable source of the error (inference):** the benchmark harness scores with `TextNormalizer`, which strips case and punctuation before WER. The "Punctuation/caps" column was probably copied from a model-card comparison and not measured. Another possibility is that Unified's punctuation is denser or better than v3's (for example, more commas). This is plausible, but **I found no measurement of punctuation quality for either model**. The remaining risk is *quality* of punctuation (density, sentence-boundary accuracy at seams), not *presence*. That still needs eyes on a real meeting.

Per model:

| Model | Punctuation + caps | Source |
|---|---|---|
| TDT v2 | Yes | NVIDIA v2 card (v2 vocab punctuation ids 841/854/885 per `ASRConstants` comment) |
| TDT v3 / ultra / redux | Yes (ultra and redux use the v3 vocabulary and tokenizer) | as above; [ParakeetUltra.md](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/ASR/ParakeetUltra.md) "same architecture, 25 languages, tokenizer" |
| Phonon-2 | Presumably yes (v3 contract, English) | not verified |
| Unified EN 0.6B | Yes | NVIDIA card + FluidAudio Models.md |
| Parakeet EOU 120M (streaming) | **No** | search summary of FluidAudio docs; not relevant (streaming) |

Inverse text normalization (digits versus spelled-out numbers): v3 vocabulary has `<|itn|>`/`<|noitn|>` control tokens, but the TDT decode path does not prompt them, so I could not determine whether v3 output writes numbers as digits. The source comment on `UnifiedAsrManager.configureVocabularyBoosting` refers to "this engine's ITN output", which suggests Unified emits ITN-style text. This is unverified.

---

## 4. Licenses

### Library

- FluidAudio code: **Apache-2.0** (`LICENSE`; GitHub API `license.spdx_id = Apache-2.0`).
- Bundled third-party code (`ThirdPartyLicenses/`): fastcluster (BSD-style, for the diarizer's C++ clustering), VBx (Apache-2.0), NemoTextProcessing / text-processing-rs (Apache-2.0, with NVIDIA NeMo Text Processing FST grammars, Apache-2.0, plus MIT/Apache Rust crates), plus TTS-related G2P data (Japanese G2P, Kokoro). All are listed as permissive. I did not audit each Rust crate.

### Models (HF metadata fetched 2026-10-21 via `huggingface.co/api/models/...`)

| Model repo | License (metadata) | Notes |
|---|---|---|
| `nvidia/parakeet-tdt-0.6b-v2` | cc-by-4.0 | |
| `nvidia/parakeet-tdt-0.6b-v3` | cc-by-4.0 | |
| `FluidInference/parakeet-tdt-0.6b-v2-coreml` | cc-by-4.0 | |
| `FluidInference/parakeet-tdt-0.6b-v3-coreml` | cc-by-4.0 (metadata) | The README body says "Apache 2.0. See the FluidAudio repository", which conflicts with the metadata. The base model is CC-BY-4.0, so CC-BY-4.0 (attribution required) is the safe reading. |
| `moondream/parakeet-ultra` | cc-by-4.0 | |
| `FluidInference/parakeet-ultra-coreml` | cc-by-4.0 | |
| `nvidia/parakeet-unified-en-0.6b` | **other: `nvidia-open-model-license`** | **Changed on release day.** The first commit `1a86871e` (2026-04-07 09:31 UTC) said `cc-by-4.0`. Every revision from `f7b1fed9` (12:54 UTC the same day) onward says NVIDIA Open Model License. |
| `FluidInference/parakeet-unified-en-0.6b-coreml` | cc-by-4.0 (metadata) | Created 2026-06-12, two months **after** upstream moved to the NVIDIA Open Model License, but still labelled CC-BY-4.0. This is very likely a mislabel. |

What this means (for the user to decide; legal calls are not mine):
- v2 / v3 / ultra: CC-BY-4.0 allows free redistribution and use in a free app, with attribution.
- Unified: treat it as **NVIDIA Open Model License** (commercial use and redistribution are allowed, with attribution and NVIDIA's terms; the STT model-landscape subtopic owns the details). The FluidInference CC-BY label should not be relied on.

---

## 5. Can the ASR be used without FluidAudio's diarizer?

**Yes, fully.** `AsrManager` / `AsrModels` (and `UnifiedAsrManager`) have no dependency on the diarizer types. `AsrModels.download` fetches only `version.repo` (the ASR repo). Diarizer models (`FluidInference/speaker-diarization-coreml`, the only repo FluidAudio pins to a commit) download only when you call diarizer APIs. FluidAudio's diarizers (offline pyannote community-1 + VBx `OfflineDiarizerManager`, Sortformer, LS-EEND, Nemotron 3) exist, but they are out of scope here.

The cost of not using the diarizer: in v0.17.7, the diarizer *code* (including the C++ `FastClusterWrapper` target) and all TTS code still compile into the binary. You cannot exclude them in this release. On `main` (unreleased) there are new opt-out traits `TTS` and `Diarizer` (#990). See [integration-and-packaging.md](./integration-and-packaging.md).

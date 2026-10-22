# FluidAudio Deep Dive

## Bottom Line

FluidAudio (Apache-2.0 Swift package, pinned here to **v0.17.7**, 2026-10-07) runs NVIDIA Parakeet models as Core ML on the ANE. It is a workable WhisperKit STT replacement next to SpeakerKit. Its batch ASR (`AsrManager`) is fully independent of its own diarizer.

Output is one punctuated, cased string plus a flat list of **sub-word** `TokenTiming`s. Each token has a start/end quantized to 80 ms and a linear 0–1 softmax confidence. There are **no segments, no detected language, no no-speech probability, and no word-level struct with confidence**, so we write about 100–200 lines of pure glue. The lowest-change path is to build WhisperKit `TranscriptionResult`/`WordTiming` values (public inits) and keep calling SpeakerKit's `addSpeakerInfo`.

The doc claim that TDT v3 has "no punctuation" is **wrong**: v3, v2 and ultra all emit punctuation and capitalization. A 1-hour file transcribes in roughly 10–40 s. The real risk is **long-form quality at the 15 s chunk seams**: FluidAudio's own 1-hour Earnings-22 WER is 16.5% for v3 and 13.5% for ultra, versus about 2% on short clips. A secondary risk is library churn (0.x, weekly releases, bus factor about 2).

## Key Findings

- **Models:** the TDT family is `AsrModelVersion` `.v2` (English), `.v3` (25 European languages, **library default**), `.ultra` (moondream post-train of v3; docs now say "**Recommended** for new integrations": better WER, same speed), `.redux` and `.phonon2`. Parakeet **Unified EN 0.6B** (RNNT, English) has a separate `UnifiedAsrManager` API. All run Core ML: encoder on ANE by default (GPU optional, about +8% RTFx), preprocessor on CPU. Apple Silicon only; macOS 14+ (redux and phonon2 need 15+). [models-and-runtime.md](./models-and-runtime.md)
- **Punctuation conflict resolved:** v3 **does** punctuate and capitalize. Evidence: NVIDIA's card ("Automatic punctuation and capitalization"); the `parakeet_vocab.json` FluidAudio downloads has `, . ? !` plus 740 capitalized pieces; FluidAudio's own v3 code handles sentence-final punctuation ids and case-folded seam merging (#706, #905). The "no punctuation" row in `Benchmarks.md` and `Unified/benchmark.md` is a doc error. Punctuation *quality* vs Unified is not measured. [models-and-runtime.md §3](./models-and-runtime.md#3-punctuation-and-capitalization-per-model-the-doc-contradiction-is-resolved)
- **Exact output (verbatim from source):** `ASRResult { text, confidence, duration, processingTime, tokenTimings: [TokenTiming]?, performanceMetrics?, ctcDetectedTerms?, ctcAppliedTerms? }` and `TokenTiming { token, tokenId, startTime, endTime, confidence }`.
  - `TokenTiming.confidence` is the full-vocab softmax probability in [0, 1], not a log-probability.
  - `ASRResult.confidence` is the mean token probability, clamped to [0.1, 1].
  - Token text has `▁` turned into a leading space. Punctuation pieces attach to the previous word.
  - TDT end times come from the duration head (≤ 0.32 s per token), with a −1 frame emission correction. Unified's are emission-only (start + 1 frame).
  - `language:` is a script-filter **hint**, not detection. [batch-api-and-output.md](./batch-api-and-output.md)
- **Docs lag source (confirmed):** GettingStarted.md shows `asrManager.configure(models:)` and `transcribe(samples, source: .system)`; the README shows `transcribe(samples)`. **None compile on v0.17.7.** The real call is `transcribe(_:decoderState: inout TdtDecoderState, language:)`. The API broke between v0.13.0 and v0.14.0. [batch-api-and-output.md](./batch-api-and-output.md#docs-vs-source)
- **Long audio:** fixed 15 s Core ML window with 2 s overlap. TDT uses 4 parallel workers, silence-aligned chunk starts for v3, a seam-gap repair pass, and disk-backed URL input above 30 s ("constant memory ~1.2MB"). Unified decodes one window at a time and takes `[Float]` input only. FluidAudio's speed numbers: 1-hour Earnings-22 concat on M5 Pro = **335x (v3) / 457x (ultra)**. Its own docs list many seam failure modes (dropped clauses at low-SNR/crosstalk seams #758, all-blank final window #747, glued words #683). Most are fixed, but seams are still the active bug area. [batch-api-and-output.md §3](./batch-api-and-output.md#3-long-audio-1-hour-meetings)
- **SPM cost:**
  - No package dependencies.
  - Two small C/C++ targets (`FastClusterWrapper`, diarizer-only, plus `MachTaskSelfWrapper`), with `cxxLanguageStandard: .cxx17`.
  - One **binary target**: `NemoTextProcessing.xcframework`, an unsigned **static** Rust lib (87 MB zip, about 8 MB per slice linked). ASR does not use it.
  - Static linking means **no new nested dylib/framework to sign** in the XPC service. The only addition is a ~1 MB SwiftPM resource bundle (TTS lexicon). No `unsafeFlags`.
  - Opting out of the Rust lib (trait `NemoTextProcessing`), and on unreleased `main` also TTS/Diarizer, needs the consuming manifest at tools-version 6.1/6.2. `Packages/Transcription` is at **6.0**, so today we would link everything. [integration-and-packaging.md](./integration-and-packaging.md)
- **Model download:**
  - Custom directory supported (`AsrModels.download(to:)`/`load(from:)`/`modelsExist(at:version:)`), **but FluidAudio replaces the last path component with the repo folder name** (`…/parakeet-tdt-0.6b-v3-coreml`). The draft spec's planned path is wrong.
  - Byte-weighted `DownloadProgress.fractionCompleted` plus a phase, but it resets per model file.
  - Retry, resume, `ModelHub.offlineMode` and mirror overrides available.
  - **ASR models are fetched from HF `main` (not pinned)** — pin with `ModelRegistry.revisionOverrides`.
  - Sizes: v3 ~480 MB, ultra ~630 MB. [integration-and-packaging.md §2](./integration-and-packaging.md#2-model-download-location-progress-offline)
- **Licenses:** library Apache-2.0. v2, v3 and ultra (base and Core ML conversions) are **CC-BY-4.0** (attribution required). **Unified's upstream (`nvidia/parakeet-unified-en-0.6b`) switched to the NVIDIA Open Model License on release day (2026-04-07)**; FluidInference's Core ML conversion (created 2026-06-12) still says CC-BY-4.0, likely a mislabel. User's decision. [models-and-runtime.md §4](./models-and-runtime.md#4-licenses)
- **ASR without FluidAudio's diarizer:** yes. `AsrManager`/`AsrModels` do not touch diarizer types or models. In v0.17.7 the diarizer and TTS *code* is still compiled in.
- **Maturity:** created 2025-06; 3.2k stars; 74 tags in ~16 months (up to 9/month); still 0.x; two maintainers wrote ~90% of commits; a whole ASR back-end (Qwen3) was added then removed. Many shipping Mac apps use it, including MacParakeet (a meeting app with word timestamps and speaker labels). Pin an exact version. [integration-and-packaging.md §3](./integration-and-packaging.md#3-maturity-and-release-cadence)
- **Mapping to `TranscriptResult`:**
  - Words: start/end/probability map directly after token→word grouping. FluidAudio's `buildWordTimings` discards confidence, so we write our own.
  - `speakerID`/`speakerLabel`/`speakerCount`: from SpeakerKit, as today.
  - Segment `confidence`: none (0 as today, or mean word probability). `noSpeechProbability`: none (0).
  - `language`: hard-code `"en"` for English models, or `NLLanguageRecognizer` for v3/ultra.
  - Two problems when reusing `addSpeakerInfo`: (1) SpeakerKit joins words with `""`, so words need a leading space; (2) the `.subsegment` 0.15 s gap rule maps 1:1 to `TranscriptSegment`s, so segment size will change, especially with Unified's early word end times. [contract-mapping.md](./contract-mapping.md)

### Draft-spec (`specs/projects/fluid_audio_engine/functional_spec.md`) claims checked

| Claim | Status |
|---|---|
| Output is one string + sub-word `[TokenTiming]` with `confidence`; no segments, language or noSpeechProb | Confirmed |
| `language:` is a decode hint, not detection | Confirmed (script filter, v3 only) |
| README quick start does not compile; source requires `decoderState: inout` | Confirmed. GettingStarted.md also shows `configure(models:)` and `source:`, which do not exist |
| `buildWordTimings` discards confidence | Confirmed (`WordTiming` has no confidence) |
| Confidence range unknown (0–1 vs log-prob)? | **Resolved:** linear softmax in [0, 1] |
| v3 punctuation unresolved | **Resolved:** v3 punctuates and capitalizes |
| Binary xcframework + two C targets + cxx17 | Confirmed. The xcframework is a static Rust lib, unsigned, not used by ASR; opt-out needs tools ≥ 6.1/6.2 |
| Models can go under `models/fluidaudio/parakeet-tdt-0.6b-v3/` | **Wrong:** last component becomes `parakeet-tdt-0.6b-v3-coreml` |
| CTC vocab boosting only on the streaming manager | **Partly wrong:** `UnifiedAsrManager` (batch) also has `configureVocabularyBoosting`; TDT `AsrManager` does not |
| Unified fallback: "2.15% avg WER, 123x RTFx, same `[TokenTiming]` shape" | Numbers confirmed. Same type, but timings are emission-only (weaker end times), no `ASRResult`/confidence/progress, and **license is NVIDIA Open Model License, not CC-BY** |
| v3 is the right default | Docs now recommend **ultra** (same API, better WER incl. the 1-hour file: 13.5% vs 16.5%) |

## Details

- [models-and-runtime.md](./models-and-runtime.md): model list, Core ML/ANE placement, performance table (incl. 1-hour numbers), punctuation evidence, licenses, diarizer independence. Read to pick a model or check licensing.
- [batch-api-and-output.md](./batch-api-and-output.md): verbatim signatures for `AsrManager`/`AsrModels`/`UnifiedAsrManager`, `ASRResult`/`TokenTiming` semantics traced to code, docs-vs-source gaps, chunking/seam details, progress, custom vocab, errors. Read before writing code.
- [integration-and-packaging.md](./integration-and-packaging.md): both manifests, binary/C targets, traits vs our tools-version, XPC signing surface, download directory quirk, progress, HF pinning, release cadence and maintainers. Read for build, CI and notarization planning.
- [contract-mapping.md](./contract-mapping.md): field-by-field mapping to `TranscriptResult`, Path A (build WhisperKit types for `addSpeakerInfo`) vs Path B (own aligner), token→word grouping rules, glue checklist. Read to scope the engine work.

## Open Questions / Gaps

- **Long-form quality on meeting audio:** no FluidAudio ASR WER on AMI or real meetings. The only long-form number is the 1-hour Earnings-22 concatenation (16.5% v3 / 13.5% ultra) with a non-standard reference. Needs a hardware A/B on Biscotti's own recordings vs WhisperKit.
- **Punctuation quality** (density, sentence boundaries at seams) for v3/ultra vs Unified is not measured; presence is settled.
- **Peak RAM** for ASR: not published. Inference: roughly model size plus small working buffers. Measure it.
- **Mac first-load (ANE compile) time:** only iPhone numbers published (encoder ~3.4–4.4 s cold).
- **Confidence calibration:** scale matches (0–1), but untested whether `TranscriptSanitizer`'s 0.3 threshold behaves the same with Parakeet probabilities.
- **Segment size under SpeakerKit `.subsegment`** with FluidAudio timings (especially Unified) is inferred from code. Verify on hardware.
- **ITN** (digits vs words) for v3: not determined.
- Whether `Packages/Transcription` can move to tools-version 6.2 (for traits) given the argmax dependency — not checked.
- **FluidAudio was not built or linked.** Signing and binary-size claims come from the manifest and the downloaded artifact, not a `make build-app` run.

## Sources

- [FluidAudio repo @ v0.17.7](https://github.com/FluidInference/FluidAudio/tree/v0.17.7): primary source. Cloned; read `Package.swift`, `Package@swift-6.2.swift`, `ASR/Parakeet/AsrTypes.swift`, `SlidingWindow/TDT/AsrManager*.swift`, `AsrModels.swift`, `ChunkProcessor.swift`, `Decoder/TdtJointDecision.swift`, `Unified/UnifiedAsrManager.swift`, `Shared/ASRConstants.swift`, `Shared/Download/*`, `ModelNames.swift`, `ModelRegistry.swift`. Tag dated 2026-10-07.
- [FluidAudio Documentation/](https://github.com/FluidInference/FluidAudio/tree/v0.17.7/Documentation): Benchmarks.md, Models.md, ASR/GettingStarted.md, ASR/LongTranscription.md, ASR/ParakeetUltra.md, ASR/ManualModelLoading.md (v0.17.7). Known to lag source.
- [FluidAudio releases](https://github.com/FluidInference/FluidAudio/releases) and GitHub API (stars, contributors), fetched 2026-10-21.
- [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3): PnC, timestamps, CC-BY-4.0, AMI 11.31% / Earnings-22 11.42%, released 2025-08-14.
- [nvidia/parakeet-tdt-0.6b-v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2): PnC, word timestamps, CC-BY-4.0, AMI 11.16% / Earnings-22 11.15%.
- [nvidia/parakeet-unified-en-0.6b](https://huggingface.co/nvidia/parakeet-unified-en-0.6b) and README revisions: NVIDIA Open Model License since 2026-04-07 12:54 UTC (CC-BY only in first commit `1a86871e`). PnC. AMI 10.14% / Earnings-22 11.16%.
- [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml): Core ML conversion; metadata cc-by-4.0 (README body says Apache 2.0). `parakeet_vocab.json` downloaded and inspected.
- [FluidInference/parakeet-unified-en-0.6b-coreml](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml): labelled CC-BY-4.0, created 2026-06-12.
- [FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml) / [moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra): CC-BY-4.0.
- [text-processing-rs v0.3.1 NemoTextProcessing.xcframework.zip](https://github.com/FluidInference/text-processing-rs/releases/tag/v0.3.1): downloaded and inspected (static `.a`, unsigned, 87 MB zip).
- [MacParakeet](https://github.com/moona3k/macparakeet): third-party FluidAudio meeting app (v3 default, word timestamps + speaker labels). [LocalFlow](https://github.com/gdrmedia/localflow): third-party report that v3 output is punctuated.
- argmax-oss-swift **v1.1.0** (local checkout in `Packages/Transcription/.build/checkouts`): `SpeakerKit/DiarizationResult.swift` (`addSpeakerInfo`, `.subsegment` 0.15 s), `SpeakerKit/SpeakerSegment.swift` (`text` joins with `""`), `WhisperKit/Core/Models.swift` (public inits).
- Repo: `Packages/Transcription/Sources/Transcription/{TranscriptResult,InProcessTranscriptionEngine,SegmentBuilder,TranscriptSanitizer}.swift`, `Packages/Transcription/Package.swift` (tools 6.0).

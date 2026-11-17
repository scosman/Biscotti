# Other libraries (whisper.cpp, NeMo-Speech.cpp, parakeet.cpp, sherpa-onnx, MLX ports, other Swift ports)

## Bottom Line

The landscape changed in mid-2026. **whisper.cpp now runs NVIDIA Parakeet TDT** (v1.9.0, June 2026; use **≥ v1.9.4**, because earlier builds had badly wrong TDT word timings). It ships Parakeet in the same prebuilt xcframework that Biscotti can add the same way `LocalLLM` already adds llama.cpp's. That makes it the cheapest non-FluidAudio option to integrate. It gives sub-word token timestamps plus per-token probability on Metal, but no ANE, no language ID and one segment for the whole file.

**NVIDIA's own NeMo-Speech.cpp** (July 2026, Apache-2.0) and **mudler/parakeet.cpp** (May 2026, MIT) give the best-shaped output: ready **word-level** start/end plus per-word confidence. They cover more models (Parakeet v2/v3, Nemotron 3.5 with language detection, CTC 1.1B, Moondream Ultra). But both ship only C headers plus macOS dylibs, so we must wrap them into an XCFramework ourselves, and both are young.

**sherpa-onnx** has the cleanest packaging (official SwiftPM since July 2026). But on Mac it is effectively CPU-only, needs VAD chunking for long files, keeps confidence behind the C struct, and fixed Parakeet-v3 frontend parity only on 2026-10-20 (unreleased).

**MLX options fit poorly.** The Python packages cannot run in our XPC service, and lightning-whisper-mlx is dead. The Swift mlx-audio-swift hides word timestamps, is consumed from a branch, and cannot build its Metal shaders under `swift build`/`swift test`.

**NVIDIA Riva is not an option**: Linux/Jetson only, NVIDIA AI Enterprise license.

## Key Findings

- **whisper.cpp runs Parakeet TDT.** "parakeet : add support for NVIDIA Parakeet (#3735)" shipped in v1.9.0 (2026-06-17). The xcframework includes `parakeet.h` since v1.9.2. Models are TDT only: ggml-org publishes v3 (f16 about 1.26 GB, q8_0, q4_k), and v2 converts. ([v1.9.0](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.0), [parakeet.h](https://github.com/ggml-org/whisper.cpp/blob/master/include/parakeet.h), [ggml-org/parakeet-GGUF](https://huggingface.co/ggml-org/parakeet-GGUF))
- **Pin whisper.cpp ≥ v1.9.4 for Parakeet.** Before PR #4017, 41% of tokens got duration 0 and word ends were off by a mean of 89 ms (36% of words >100 ms). After the fix the mean error is 2 ms. A hallucination bug was also fixed after v1.9.2. ([#4017](https://github.com/ggml-org/whisper.cpp/pull/4017), [#4088](https://github.com/ggml-org/whisper.cpp/issues/4088))
- **whisper.cpp Parakeet output:**
  - Per sub-word token: `t0/t1` (10 ms units), `p`, `plog`, `is_word_start`. Punctuation gets zero-duration timestamps.
  - One segment for the whole file. No language.
  - Long files run as one dynamic encoder pass, with local attention above 10.9 min. Memory for a 1-hour file is unmeasured.
  - Metal only; the Core ML/ANE path is Whisper-only. ([parakeet.cpp source](https://github.com/ggml-org/whisper.cpp/blob/master/src/parakeet.cpp))
- **We already use this integration pattern.** `Packages/LocalLLM` → `mattt/llama.swift` → `binaryTarget(url: llama.cpp xcframework)`, running inside `BiscottiLLM.xpc` (hardened runtime, no JIT entitlement). The same approach works for `whisper.framework`. Since v1.9.3 the xcframework is attached to the paired `bNNNN` nightly tag, not the `vX.Y.Z` tag. ([b5454](https://github.com/ggml-org/whisper.cpp/releases/tag/b5454))
- **whisper.cpp's Whisper path is no model upgrade.** It runs the same Whisper family we already get free in WhisperKit. DTW word timestamps are marked "[EXPERIMENTAL]" and turn off automatically because flash-attn is on by default. ([whisper.h](https://github.com/ggml-org/whisper.cpp/blob/master/include/whisper.h))
- **NeMo-Speech.cpp is NVIDIA's official local runtime** ("NVIDIA's official solution for local speech inference"):
  - Stable C ABI that mirrors Riva. Gives **word** start/end (ms), per-word confidence and language codes.
  - Runs Parakeet TDT v3, Nemotron 3.5 (40+ locales, automatic language ID) and Parakeet CTC 1.1B.
  - Splits long audio "at quiet points" internally.
  - The macOS arm64 Metal archive holds about 12 `@rpath` dylibs (min macOS 13.3). No Swift package.
  - v0.2.0 (2026-10-02). No Apple benchmarks. ([README](https://github.com/NVIDIA/NeMo-Speech.cpp), [asr.h](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/include/nemo_speech/asr.h))
- **parakeet.cpp (mudler/LocalAI)** has the broadest Parakeet coverage and claims "WER 0" parity with NeMo:
  - Returns JSON `words[{w,start,end,conf}]`, where conf is the minimum token softmax, in (0,1].
  - On an M4 with Metal, tdt-0.6b-v3 runs at 54× real time on a 7.4 s clip.
  - "GPU backends are not exercised in CI."
  - About one release per month, one main maintainer. ([README](https://github.com/mudler/parakeet.cpp), [capi.md](https://github.com/mudler/parakeet.cpp/blob/master/docs/capi.md))
- **sherpa-onnx has official SwiftPM but is CPU-bound on Mac:**
  - `Package.swift` added 2026-07-29 (static/shared xcframework plus onnxruntime 1.28.2).
  - Parakeet output: token timestamps plus durations (seconds). `ys_log_probs` is reachable only through the C struct.
  - Long files need Silero VAD chunking.
  - One community comment says ONNX Runtime's CoreML provider is no faster than CPU.
  - The fix that matches NeMo's v3 audio preprocessing was merged 2026-10-20, after v1.13.8. ([Package.swift](https://github.com/k2-fsa/sherpa-onnx/blob/master/Package.swift), [c-api.h](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/c-api/c-api.h), [#4024](https://github.com/k2-fsa/sherpa-onnx/pull/4024))
- **MLX fits poorly:**
  - mlx-swift: "SwiftPM (command line) cannot build the Metal shaders".
  - mlx-audio-swift's Parakeet returns only sentence `[[String: Any]]` (text/start/end). Its token decode is `private`, and it is consumed by `branch: main`.
  - lightning-whisper-mlx: last commit 2024-05. FluidInference/swift-parakeet-mlx is archived. ([mlx-swift](https://github.com/ml-explore/mlx-swift), [NemoAlignment.swift](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Nemo/NemoAlignment.swift))
- **Other Core ML Swift ports:**
  - soniqo/speech-swift `ParakeetASR` runs on the ANE (RTF 0.005 on M5 Pro) and gives word times. But they are "emission-aligned" and ignore TDT durations for word ends. It is a branch-only dependency with a very heavy manifest.
  - mweinbach/parakeet-coreml-swift is fast (claims 402× on ANE) but gives raw token frames only, and it was abandoned after one day. ([speech-swift Parakeet doc](https://github.com/soniqo/speech-swift/blob/main/docs/inference/parakeet-asr-inference.md), [parakeet-coreml-swift](https://github.com/mweinbach/parakeet-coreml-swift))
- **Riva is out.** The support matrix lists only Linux data-center GPUs and Jetson. Self-hosting needs NVIDIA AI Enterprise. ([Riva support matrix](https://docs.nvidia.com/deeplearning/riva/user-guide/docs/support-matrix/support-matrix.html))
- **No Parakeet runtime gives language (except Nemotron 3.5), segment confidence or no-speech probability.** We must derive or zero these contract fields whichever library wins. ([contract-mapping.md](./contract-mapping.md))

## Details

- [whisper-cpp.md](./whisper-cpp.md) — whisper.cpp Parakeet and Whisper paths: API structs, timestamp units, long-audio behaviour, bug history, xcframework packaging, the precedent already in this repo.
- [nvidia-nemo-speech-cpp-and-riva.md](./nvidia-nemo-speech-cpp-and-riva.md) — NeMo-Speech.cpp C ABI, models, long-audio splitting, macOS archive contents. Why Riva and NeMo (Python) are out.
- [parakeet-cpp.md](./parakeet-cpp.md) — mudler/parakeet.cpp models, JSON word output, Metal benchmarks, maturity.
- [sherpa-onnx.md](./sherpa-onnx.md) — SwiftPM packaging, result struct, VAD requirement, how the CoreML provider performs in practice, the fresh v3 accuracy fix.
- [mlx-ports.md](./mlx-ports.md) — parakeet-mlx, mlx-whisper and lightning-whisper-mlx (Python), and mlx-audio-swift. The Metal shader build problem.
- [other-swift-ports.md](./other-swift-ports.md) — speech-swift, parakeet-coreml-swift, Moonshine, and Moondream Parakeet Ultra (as a drop-in model).
- [contract-mapping.md](./contract-mapping.md) — comparison table and field-by-field mapping to `TranscriptResult`, with an estimate of the glue code per library.

## Open Questions / Gaps

- **No 1-hour measurements anywhere** (peak RAM, wall time, timestamp drift) for whisper.cpp Parakeet, NeMo-Speech.cpp or parakeet.cpp on M-series. Only short clips or decode-only numbers exist. Needs a hands-on test.
- **No energy data** for any library here.
- NeMo-Speech.cpp: not verified from source what scale its confidence uses, or whether Parakeet TDT results carry a language code. Apple Metal performance is unpublished.
- parakeet.cpp: not verified whether the detected language (`--lang auto`) is returned in the JSON.
- Hardened-runtime and notarization behaviour is inferred from the llama.cpp precedent. Biscotti's signing and notarization are deferred (Project 9), so this is not yet proven even for llama.cpp.
- The claim that sherpa-onnx's CoreML provider is no faster than CPU rests on one community comment; not benchmarked.
- speech-swift: the exact per-word value in `WordConfidence` not checked in source.

## Sources

- [whisper.cpp releases API](https://api.github.com/repos/ggml-org/whisper.cpp/releases) — release dates and assets, v1.8.6–v1.9.5 (2026-06 → 2026-10-06)
- [whisper.cpp v1.9.0 release](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.0) — Parakeet support added (2026-06-17)
- [whisper.cpp include/parakeet.h](https://github.com/ggml-org/whisper.cpp/blob/master/include/parakeet.h) and [src/parakeet.cpp](https://github.com/ggml-org/whisper.cpp/blob/master/src/parakeet.cpp) — Parakeet API, timestamp units, segmenting, long-audio logic (master, Oct 2026)
- [whisper.cpp include/whisper.h](https://github.com/ggml-org/whisper.cpp/blob/master/include/whisper.h) — Whisper token data, DTW, VAD, language
- [whisper.cpp build-xcframework.sh](https://github.com/ggml-org/whisper.cpp/blob/master/build-xcframework.sh) — xcframework contents (parakeet.h, embedded Metal library, Core ML, macOS 13.3)
- [whisper.cpp PR #4017](https://github.com/ggml-org/whisper.cpp/pull/4017) — TDT timestamp fix with measured before/after (merged 2026-08-29, v1.9.4)
- [whisper.cpp issue #4088](https://github.com/ggml-org/whisper.cpp/issues/4088) — Parakeet hallucination, fixed after v1.9.2
- [ggml-org/parakeet-GGUF](https://huggingface.co/ggml-org/parakeet-GGUF) — published ggml Parakeet weights (2026-06-16)
- [mattt/llama.swift](https://github.com/mattt/llama.swift) — the binaryTarget-over-xcframework pattern Biscotti already uses
- [NVIDIA/NeMo-Speech.cpp README](https://github.com/NVIDIA/NeMo-Speech.cpp), [asr.h](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/include/nemo_speech/asr.h), [docs/sdk.md](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/sdk.md), [docs/asr/models.md](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/asr/models.md), [recognizer.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/src/asr/recognizer.cpp) — v0.2.0 (2026-10-02)
- [mudler/parakeet.cpp README](https://github.com/mudler/parakeet.cpp), [docs/capi.md](https://github.com/mudler/parakeet.cpp/blob/master/docs/capi.md), [BENCHMARK.md](https://github.com/mudler/parakeet.cpp/blob/master/benchmarks/BENCHMARK.md), [parity.md](https://github.com/mudler/parakeet.cpp/blob/master/docs/parity.md) — v0.6.1 (2026-10-07)
- [sherpa-onnx Package.swift](https://github.com/k2-fsa/sherpa-onnx/blob/master/Package.swift), [c-api.h](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/c-api/c-api.h), [SherpaOnnx.swift](https://github.com/k2-fsa/sherpa-onnx/blob/master/swift-api-examples/SherpaOnnx.swift), [NeMo transducer models doc](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/nemo-transducer-models.html), [PR #4024](https://github.com/k2-fsa/sherpa-onnx/pull/4024), [issue #2282](https://github.com/k2-fsa/sherpa-onnx/issues/2282) — v1.13.8 (2026-09-10) plus master
- [ml-explore/mlx-swift README](https://github.com/ml-explore/mlx-swift) — SwiftPM cannot build Metal shaders (0.32.3, 2026-09-30)
- [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) — Parakeet support and output types (v0.1.6, 2026-10-20)
- [senstella/parakeet-mlx](https://github.com/senstella/parakeet-mlx) — Python reference implementation (PyPI 0.5.3, 2026-10-01)
- [soniqo/speech-swift](https://github.com/soniqo/speech-swift) and its [Parakeet inference doc](https://github.com/soniqo/speech-swift/blob/main/docs/inference/parakeet-asr-inference.md) — v0.0.28 (2026-09-24)
- [mweinbach/parakeet-coreml-swift](https://github.com/mweinbach/parakeet-coreml-swift) — Core ML port (2026-04-22)
- [NVIDIA Riva support matrix](https://docs.nvidia.com/deeplearning/riva/user-guide/docs/support-matrix/support-matrix.html) — supported platforms (2.26.0)
- [Moondream Parakeet Ultra/Redux blog](https://moondream.ai/blog/introducing-parakeet-redux-and-ultra) — drop-in Parakeet-v3 derivative, CC-BY-4.0 (2026-09-22)

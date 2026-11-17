# Other 2026 Swift entrants (Core ML Parakeet ports, toolkits) and minor libraries

Researched 2026-10-21. FluidAudio is excluded (own subtopic). These are other Swift packages that run Parakeet through Core ML.

## soniqo/speech-swift: large Apple-Silicon speech toolkit (Core ML + MLX)

- [soniqo/speech-swift](https://github.com/soniqo/speech-swift), Apache-2.0, 1,244 stars, created 2026-02-04, releases about every 2–3 weeks (v0.0.25 2026-08-16 … **v0.0.28 2026-09-24**). macOS 15+ / iOS 18+ ("comes from MLState"). Used by several apps listed in its README (AnythingLLM, Anarlog, and others).
- Products include `ParakeetASR` (Core ML, batch), `ParakeetStreamingASR`, `NemotronStreamingASR`, `WhisperASR` (Core ML large-v3-turbo), `Qwen3ASR` (MLX), `MossTranscribe`, `SpeechVAD`, and more. The `ParakeetASR` target depends only on `AudioCommon` (which depends on swift-transformers `Hub`) ([Package.swift](https://github.com/soniqo/speech-swift/blob/main/Package.swift)). But the package manifest also pulls in mlx-swift, mlx-swift-lm, hummingbird, MCP swift-sdk, xgrammar and even `argmaxinc/WhisperKit` at resolution time. That is a heavy dependency graph to resolve, even if only `ParakeetASR` gets built.
- Consumed with `branch: "main"` per README.
- **Parakeet details** ([docs/models/parakeet-asr.md](https://github.com/soniqo/speech-swift/blob/main/docs/models/parakeet-asr.md), [docs/inference/parakeet-asr-inference.md](https://github.com/soniqo/speech-swift/blob/main/docs/inference/parakeet-asr-inference.md)):
  - Model: Parakeet-TDT 0.6B **v3**, INT8-palettized Core ML encoder, fixed 30 s window (`aufklarer/Parakeet-TDT-v3-CoreML-INT8-30s`). "Audio longer than 30s is window-chunked in `transcribeAudio`."
  - Compute: macOS defaults to `.cpuAndNeuralEngine` with `.cpuAndGPU` fallback.
  - Output: `TranscriptionResult.words`, where each `WordConfidence` has `startTime`/`endTime` in seconds. Plus "an overall confidence score (0.0 to 1.0) computed as the sigmoid-scaled mean of token logits".
  - Timestamp caveats, stated honestly by the doc: "The times are emission-aligned, not forced-aligned ... the first word of an utterance starts about 0.3 s before the acoustic onset and the last word ends about 0.2 s after the acoustic end. `endTime` is one frame after the last token's start rather than the start plus the predicted TDT duration". So it **ignores TDT durations for word end times**, which is worse for SpeakerKit word↔speaker alignment than libraries that use the duration.
  - Performance (M5 Pro, macOS 26.5): "warm transcribe 0.10 s (RTF 0.005), peak memory footprint 857 MB" on a 20 s fixture. "Cold start ... BNNS graph compile on ANE — 5 s for the 5s variant, ~11 s for 30s. CoreML caches the compile to disk".
  - Cache: `~/Library/Caches/qwen3-speech/` by default, overridable with `cacheDir:`. `offlineMode: true` skips the network.
  - Thread safety: "`ParakeetASRModel` — NOT thread-safe".
- The MLX products carry the metallib build issue described in [mlx-ports.md](./mlx-ports.md). The Core ML Parakeet product should not.

## mweinbach/parakeet-coreml-swift: small, fast, but raw output

- [mweinbach/parakeet-coreml-swift](https://github.com/mweinbach/parakeet-coreml-swift), Apache-2.0, 23 stars. **Created 2026-04-22, last push 2026-04-22** (one day of activity). macOS 14+.
- Claims "1145× real-time on GPU / 402× on ANE / 163× on CPU (M5 Max, 17.5-min audio, 3-run median)". About 450 MB, 4-bit palettized encoder. Auto-downloads from `mweinbach1/parakeet-tdt-0.6b-v3-coreml` to `~/Library/Caches/com.parakeet-tdt/hf-models/`, or `ParakeetTranscriber(modelsRoot:)` for local models, with a download progress callback ([README](https://github.com/mweinbach/parakeet-coreml-swift)).
- Output `Transcription`: `text`, `tokenIds`, `frameIndices` ("× 8 × hop for sample-level timestamps"), `durations` (0–4 frames), timing. **No words, no confidence.** You would build words from token IDs plus the tokenizer yourself.
- Effectively a one-off. Useful as a reference for Core ML speed tricks, not as a dependency.

## Moonshine Voice

[moonshine-ai/moonshine](https://github.com/moonshine-ai/moonshine), 11k stars, MIT code. Models are "MIT by default ... the only exceptions are the legacy non-streaming models for languages other than English" (Moonshine Community License, non-commercial). Positioned for "live streaming, with low latency" voice interfaces, with one library across iOS/macOS and others. It is a streaming-first, small-model library. I did not research its batch output shape. Model comparisons belong to the model-landscape subtopic.

## Moondream Parakeet Ultra / Redux (model, not library)

Released 2026-09-22. "Weights are available under the CC-BY-4.0 license, same as NVIDIA's original model" ([Moondream blog](https://moondream.ai/blog/introducing-parakeet-redux-and-ultra)). The blog says only "based on NVIDIA's Parakeet". That it keeps the v3 architecture and tokenizer is inferred from the runtimes loading it through their v3 code paths (parakeet.cpp: "Moondream, from parakeet-tdt-0.6b-v3"). Relevant here only because it is a drop-in for any Parakeet-v3 runtime. parakeet.cpp ships it, and sherpa-onnx recognizes it ([#4024](https://github.com/k2-fsa/sherpa-onnx/pull/4024)). Quality claims belong to the model-landscape subtopic.

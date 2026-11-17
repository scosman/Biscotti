# MLX ports: parakeet-mlx, mlx-whisper, lightning-whisper-mlx, and the Swift side (mlx-audio-swift)

Researched 2026-10-21.

## Python MLX packages: not usable in our XPC service

All three are Python. Using them from a hardened-runtime Swift XPC service would mean embedding a Python interpreter plus MLX wheels. Not a realistic path.

| Package | Status | Notes |
|---|---|---|
| [senstella/parakeet-mlx](https://github.com/senstella/parakeet-mlx) | Apache-2.0, 988 stars, PyPI 0.5.3 (2026-10-01) | TDT/RNNT/CTC/TDT-CTC. `AlignedResult → AlignedSentence(text,start,end,tokens) → AlignedToken(text,start,end,duration)`. Chunking default `--chunk-duration` 120 s with overlap ([README](https://github.com/senstella/parakeet-mlx)). The reference implementation the Swift ports copy. |
| mlx-whisper ([ml-explore/mlx-examples/whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper)) | MIT, last whisper commit 2025-12-15 | Whisper only. Gives no model upgrade over our free WhisperKit. |
| [mustafaaljadery/lightning-whisper-mlx](https://github.com/mustafaaljadery/lightning-whisper-mlx) | last commit **2024-05-08**, no license on the repo metadata | **Dead.** Whisper only. |

## Swift-native MLX options

### mlx-audio-swift (Blaizzy): the live one

- [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift), MIT, 802 stars, releases v0.1.4–v0.1.6 in Oct 2026 (v0.1.6 on 2026-10-20). macOS 14+ / iOS 17+. Depends on `mlx-swift` ≥ 0.32.3, `swift-transformers`, `swift-huggingface` ([Package.swift](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Package.swift)).
- `MLXAudioSTT` runs Parakeet ([Parakeet README](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/README.md): tdt-0.6b-v2, tdt-0.6b-v3, tdt-1.1b, tdt_ctc-1.1b/110m, ctc-0.6b/1.1b, rnnt-0.6b/1.1b from `mlx-community`). It also runs Whisper, Canary, Nemotron ASR, Qwen3-ASR, Voxtral, Cohere Transcribe, Granite Speech, Moonshine, GLM-ASR and more ([README](https://github.com/Blaizzy/mlx-audio-swift)).
- **Output shape:** `STTOutput { text: String; segments: [[String: Any]]?; language: String?; ...stats }` ([STTOutput.swift](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/GLMASR/STTOutput.swift)). For Parakeet, `segments` are **sentence-level dictionaries with only `"text"`, `"start"`, `"end"`** (`NemoAlignedResult.segments` in [NemoAlignment.swift](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Nemo/NemoAlignment.swift)). Token-level `NemoAlignedToken(id, text, start, duration)` exists, but `ParakeetModel.decodeChunk` and `flattenTokens` are `private` ([ParakeetModel.swift](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift)). So **the public API gives no word timestamps and no confidence**. We would need a fork or an upstream PR. `language` just echoes the requested parameter for Parakeet.
- Long audio: `generate` chunks at `chunkDuration` (default 1200 s = 20 min) with a 2 s overlap, merged by `mergeTokenSequences`.
- Model download: `fromPretrained(repo, cache: HubCache)` via swift-huggingface. A custom cache dir is possible.
- Packaging cautions:
  - The README recommends `branch: "main"`.
  - The `MLXAudioCore` target uses `.unsafeFlags(["-Xfrontend", "-warn-concurrency"], .when(configuration: .debug))`. SwiftPM refuses `unsafeFlags` in version-pinned remote dependencies, which is probably why it is consumed by branch (my inference).
  - It pulls the whole MLX stack plus swift-transformers.

### Archived / thin ports

- [FluidInference/swift-parakeet-mlx](https://github.com/FluidInference/swift-parakeet-mlx): **archived**, MIT, last push 2025-07. Tested only v2.
- `seamlesscompute/parakeet-mlx-swift` (referenced in that README): 404 / gone.
- soniqo/speech-swift's MLX side (Qwen3-ASR and others) is covered in [other-swift-ports.md](./other-swift-ports.md). Its Parakeet path is Core ML, not MLX.

## The MLX build problem (applies to every mlx-swift option)

From the [mlx-swift README](https://github.com/ml-explore/mlx-swift): "**SwiftPM (command line) cannot build the Metal shaders so the ultimate build has to be done via Xcode.**" `xcodebuild` can. speech-swift spells out the effect: "If you see `Failed to load the default metallib` at runtime, the Metal shader library is missing. Run `make build` or `./scripts/build_mlx_metallib.sh release` after a manual `swift build`" ([speech-swift README](https://github.com/soniqo/speech-swift)).

This collides with Biscotti's package-first rule: `make test` = `swift test` per package via hooks-mcp. MLX-backed inference would not run under `swift test` without an extra metallib build step. The app build (`xcodebuild`) would be fine. Per [mlx-swift](https://github.com/ml-explore/mlx-swift), MLX is also built as a static library by default, with a warning about two copies if linked from both an app and a framework.

## Performance (reference only)

The parakeet-mlx Python package is commonly quoted at tens of × real time on M-series GPUs, but I did not find a first-party benchmark page for the Swift port. No energy data. MLX runs on the GPU, not the ANE.

## Assessment

There is no production-ready Swift MLX Parakeet engine that gives word timestamps plus confidence out of the box. mlx-audio-swift is active and broad but exposes only sentence segments, consumes MLX by branch, and adds the metallib build step. Low fit for Biscotti.

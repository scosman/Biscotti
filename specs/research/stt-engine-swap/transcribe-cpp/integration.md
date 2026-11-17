# transcribe.cpp — Swift Integration, XPC / Hardened Runtime, Model Download

Research date: 2026-10-21. Pinned to **v0.4.0**.

## 1. Integration options

### Option A — official Swift wrapper + release xcframework (recommended path)

- The repo ships Swift bindings at [`bindings/swift`](https://github.com/handy-computer/transcribe.cpp/tree/main/bindings/swift): product `TranscribeCpp` (idiomatic wrapper) over a `binaryTarget` named `CTranscribe` (raw C module). `Package.swift`: `swift-tools-version: 5.9`, platforms `.macOS(.v13)`, `.iOS(.v16)`; links `c++`, `z`, Accelerate, Foundation, Metal, MetalKit.
- **No official SwiftPM URL yet.** The README says: "The standalone SwiftPM mirror is planned but not published yet: `.package(url: "https://github.com/handy-computer/transcribe-cpp-swift.git", from: "0.3.0")`". That repo returns 404 (checked 2026-10-21). The in-repo package resolves the binary from a **local path** (`TRANSCRIBE_XCFRAMEWORK_PATH` or `build-apple/TranscribeCpp.xcframework`), so it cannot be used as a remote dependency directly.
- Documented interim: use the release asset as a remote binary target:
  ```swift
  .binaryTarget(
      name: "CTranscribe",
      url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.3.0/TranscribeCpp.xcframework.zip",
      checksum: "<published with the release>"
  )
  ```
  That gives only `import CTranscribe` (the C API). To get the Swift wrapper we would **vendor the MIT wrapper sources** (`bindings/swift/Sources/TranscribeCpp/*.swift`, ~16 files) into our own package next to the binaryTarget. Three third-party repos do exactly this: [`Beingpax/Transcribe-cpp-swift`](https://github.com/Beingpax/Transcribe-cpp-swift) (VoiceInk's author; self-hosted 0.2.0-dev build), [`altic-dev/transcribe-cpp-swift`](https://github.com/altic-dev/transcribe-cpp-swift) (points at official v0.1.2 asset), [`n0an/transcribe-cpp-swift`](https://github.com/n0an/transcribe-cpp-swift) (self-hosted 0.2.1). All are stale relative to v0.4.0; we would maintain our own thin package.
- Note: the wrapper and the xcframework must match exactly. The bindings validate the native version ("A binding validates `version` (pre-1.0: exact base…" — [docs/bindings.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/bindings.md)); there is an `ABIHash.swift` in the wrapper.

### What the release xcframework actually contains (verified by unpacking v0.4.0)

- `TranscribeCpp.xcframework.zip` = 10.2 MB. Slices: `macos-arm64_x86_64`, `ios-arm64`, `ios-arm64_x86_64-simulator`.
- macOS slice: `CTranscribe.framework`, a **dynamic** library (Mach-O universal x86_64 + arm64, 13.6 MB), `minos 13.0`, install name `@rpath/CTranscribe.framework/Versions/Current/CTranscribe`.
- Depends only on system frameworks: Foundation, Metal, MetalKit, Accelerate, CoreFoundation, libc++, libobjc, libSystem.
- **Ad-hoc signed** (`Signature=adhoc`, `TeamIdentifier=not set`). We must re-sign it with our Developer ID (Xcode "Embed & Sign" does this).
- Doc drift: `bindings/swift/Package.swift` comments say "a merged static `libtranscribe`", but `scripts/ci/build_xcframework.sh` says "We ship a DYNAMIC `.framework` per slice (the same posture as llama.cpp/whisper.cpp), NOT a bare static `.a`", because a static ggml-metal (Objective-C) archive aborts at launch without `-ObjC`/`-force_load`. The binary confirms dynamic.
- Metal shaders: built with `GGML_METAL_EMBED_LIBRARY=ON`; `ggml-metal-device.m` compiles the embedded source at runtime with `newLibraryWithSource:`. No separate `.metallib` resource to bundle.

### Option B — build from source

`cmake -B build && cmake --build build` (C++17, vendored ggml; Metal on by default on Apple Silicon). SwiftPM cannot run CMake, so this means our own script that runs `scripts/ci/build_xcframework.sh` (needs CMake, optional Ninja) and checks in or hosts the result. More control (e.g. pick a main commit with the long-form memory fix before it is released), more build surface. Inference: only worth it if we need an unreleased fix.

### Option C — raw C API only

Use `import CTranscribe` and write our own ~200-line Swift wrapper over `transcribe_model_load_file`, `transcribe_session_init`, `transcribe_run`, `transcribe_get_word/_token`. Avoids tracking the upstream Swift wrapper. The C header is large (2,834 lines) but the offline path we need is small.

## 2. Fit with the repo's build model

- Our convention is "Swift-package-first … runs via `swift build`/`swift test` with no `xcodebuild`" (repo `CLAUDE.md`). A remote `binaryTarget` xcframework works with plain `swift build`/`swift test` on macOS. **Precedent in this repo:** `Packages/LocalLLM` depends on `mattt/llama.swift`, whose `Package.swift` uses `.binaryTarget(url: "https://github.com/ggml-org/llama.cpp/releases/download/b10549/llama-b10549-xcframework.zip")` — the same packaging pattern (ggml + Metal dynamic xcframework) that already ships in `BiscottiLLM.xpc`.
- Two ggml copies (llama.cpp's and transcribe.cpp's) would live in two different XPC processes, so no clash at run time. Inference: if both were ever loaded into one process (CLI harness, ManualTestApp), they are separate dynamic images with two-level namespaces, so symbol clashes are unlikely, but this is untested.

## 3. Inside a hardened-runtime XPC service

Our `BiscottiTranscriber.xpc` is non-sandboxed (`com.apple.security.app-sandbox = false`), hardened runtime, Developer ID (repo `specs/research/permissions/README.md`).

Assessment (inference from the binary and source; not tested on hardware):

- **Library validation:** a hardened-runtime process loads only libraries signed by Apple or by the same Team ID. The framework is ad-hoc signed upstream, so it **must be re-signed** with our team ID during embed. Standard; same as llama.cpp today.
- **Placement / rpath:** the framework must be found via `@rpath` from the XPC executable. Either embed it in the XPC bundle's `Contents/Frameworks`, or embed it once in the app's `Contents/Frameworks` and add an rpath such as `@executable_path/../../../../Frameworks` to the XPC target. XcodeGen `embed: true` on the package dependency handles the common case.
- **Runtime Metal compile:** `newLibraryWithSource:` compiles Metal shader source at run time. This does not need the `allow-jit` or `allow-unsigned-executable-memory` entitlements (Metal compilation happens in Apple's compiler service). whisper.cpp and llama.cpp use the same mechanism in notarized apps; our BiscottiLLM.xpc already does this via llama.cpp.
- **No network, no TCC:** the library has no download code (a grep of `src/`, `include/`, and the Swift sources for curl / NSURLSession / huggingface finds nothing), and it needs no microphone or speech-recognition permission. It only reads a GGUF path we give it.
- **Memory-mapped weights:** on main (not v0.4.0), weights are mmapped ([#195](https://github.com/handy-computer/transcribe.cpp/pull/195)). README: "Don't truncate or rewrite a model file in place while a program has it loaded; write a new file and rename it over the old one." Our downloader must write to a temp file and rename.
- **Concurrency/lifetime (Swift README):** "`Model` is shareable. In 0.x, compute is serialized per model"; "`Session` is single-threaded"; "On Metal, do not keep models in globals in short-lived programs. Scope models so ARC releases GPU resources before process exit." GPU scratch is a grow-only high-water mark while a model is loaded ([Handy #2000](https://github.com/cjpais/Handy/issues/2000)) — unload the model (or let the XPC process exit) after each job, as we do for WhisperKit today (`sequentialLoading`).
- **Cancellation:** `CancellationToken` / `transcribe_set_abort_callback`; aborted runs keep the partial transcript. Async `run` bridges Swift task cancellation.
- **Threads:** set `SessionOptions(nThreads:)` near the performance-core count; the default "every logical CPU was 5x slower" ([ADE PR #1522](https://github.com/arul28/ADE/pull/1522)).
- **Backend selection:** `transcribe_init_backends_default()` is a no-op in the static-backend Apple build; `TRANSCRIBE_BACKENDS` env var can narrow; `ModelOptions(backend: .auto)` picks Metal.

## 4. Model download and caching control

- **Fully app-controlled.** transcribe.cpp never downloads. We choose the URL, directory, progress UI, checksum and retry. `Model(path:)` takes any file path.
- **Sources:** `https://huggingface.co/handy-computer/<variant>-gguf/resolve/main/<variant>-<QUANT>.gguf`, e.g. `parakeet-tdt-0.6b-v2-Q8_0.gguf` (730 MB) or `-Q4_K_M` (475 MB) ([parakeet-tdt-0.6b-v2.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet-tdt-0.6b-v2.md)). Pin to a commit-specific `resolve/<sha>/` URL and a SHA-256 (ADE does this: "downloads from a commit-pinned Hugging Face URL with a pinned sha256").
- **Single file per model.** No tokenizer/config side files; GGUF carries everything (tokenizer, hparams, segmenter thresholds for ultra).
- Each release also publishes `catalog.db` (+ SHA-256) with model metadata, sizes and benchmarks; usable to drive a model picker.
- Compatibility risk: GGUF metadata evolves with the engine (e.g. "GGUFs predating stt.translation.target_languages report 0" — header). Pin model file + engine version together.

## 5. Effort estimate (inference)

| Task | Size |
|---|---|
| Thin SPM package: binaryTarget (pinned URL + checksum) + vendored Swift wrapper or own C shim | S |
| XcodeGen: embed & sign framework in BiscottiTranscriber.xpc, rpath | S |
| `TranscriptionEngine` impl: load model, run, map tokens→words→`TranscriptWord` | M |
| Long-audio strategy (ultra built-in, or own chunking + progress, or wait for #199 release) | M |
| SpeakerKit glue (see [contract-mapping.md](./contract-mapping.md)) | M |
| GGUF downloader with progress, checksum, atomic rename | S–M (reuse existing `ModelStorage` patterns) |
| Re-tune `TranscriptSanitizer` confidence threshold, update manual tests | S |

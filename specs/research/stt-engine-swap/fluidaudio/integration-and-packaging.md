# FluidAudio: SPM Integration, XPC/Signing Surface, Model Download, Maturity

Pinned: **FluidAudio v0.17.7** (`503b4bd1`, 2026-10-07).

---

## 1. SPM manifest facts

FluidAudio ships **two manifests**. SwiftPM picks one by the *toolchain* version that runs it:
- `Package.swift`: `swift-tools-version: 6.0`, used by toolchains < 6.2.
- `Package@swift-6.2.swift`: used by Swift 6.2+ toolchains. Biscotti CI pins Xcode 26.3, so CI uses this manifest.

Both manifests declare (verbatim excerpts, v0.17.7):

```swift
platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v2) /* + .tvOS(.v17) in Package.swift */],
dependencies: [],                                   // no transitive package deps
targets: [
  .target(name: "FluidAudio",
          dependencies: ["FastClusterWrapper", "MachTaskSelfWrapper",
                         .target(name: "NemoTextProcessing", condition: .when(platforms: [.macOS, .iOS, .macCatalyst] /* , traits: ["NemoTextProcessing"] in 6.2 */))],
          resources: [.process("TTS/LuxTts/G2p/Resources")]),
  .binaryTarget(name: "NemoTextProcessing",
      url: "https://github.com/FluidInference/text-processing-rs/releases/download/v0.3.1/NemoTextProcessing.xcframework.zip",
      checksum: "5fa8c10d4ec26c1bb2413125f351a7222a4c68a23b74476680fbada7e26fc6aa"),
  .target(name: "FastClusterWrapper", path: "Sources/FastClusterWrapper", publicHeadersPath: "include"),   // C++
  .target(name: "MachTaskSelfWrapper", path: "Sources/MachTaskSelfWrapper", publicHeadersPath: "include"), // C
  ...
],
cxxLanguageStandard: .cxx17
```

What each piece costs:

| Piece | What it is | Used by ASR? | Cost / risk |
|---|---|---|---|
| `NemoTextProcessing` binary target | Prebuilt xcframework of a **Rust static library** (`libtext_processing_rs.a`). The macOS slice is fat `x86_64 arm64`, 59.5 MB on disk. The zip download is **87 MB**. The xcframework is **unsigned** (`codesign -dv`: "code object is not signed at all"). I downloaded and inspected it. | **No.** It is referenced only by `ITN/TextNormalizer.swift` and the TTS normalizers. | Static, so it links into our XPC binary. **No extra dylib to sign or notarize.** The binary size grows: the FluidAudio manifest comment says "~8 MB per slice". SwiftPM links all object files of the `FluidAudio` target, so `TextNormalizer` and its Rust references are probably linked even if we never call them (inference). There is also an 87 MB fetch on every clean CI checkout. |
| `FastClusterWrapper` | C++ (`fastcluster`, BSD-style) hierarchical clustering | No (diarizer `AHCClustering.swift` only) | Compiles as C++17. No unsafe flags. |
| `MachTaskSelfWrapper` | 5-line C shim exposing `mach_task_self_` | Memory reporting (`SystemInfo`) | Trivial. |
| `cxxLanguageStandard: .cxx17` | Package-level setting | — | Applies to FluidAudio's own C++ targets only, not to our packages. |
| Resources (`LuxTts` G2P lexicon, ~1 MB) | SwiftPM resource bundle `FluidAudio_FluidAudio.bundle` | No (TTS) | Xcode copies the bundle into the product that links FluidAudio (our XPC service) and signs it with the host. This is one extra nested bundle in the `.xpc`. On `main`, it has moved to its own target behind the `TTS` trait. |

I checked for `unsafeFlags`, `linkerSettings`, `dlopen`, and `Process`/`posix_spawn`: **none found**. This matters, because `unsafeFlags` would block FluidAudio as a dependency.

### Traits (opt-outs) and Biscotti's tools-version

- v0.17.7's 6.2 manifest has **one** trait: `NemoTextProcessing` (default on). The comment says: "Opt out of the NeMo text-normalization engine (~8 MB per slice, a prebuilt Rust staticlib) for ASR/VAD/diarization-only apps … `.package(url: ..., traits: [])`".
- `main` (unreleased) adds the traits `TTS` and `Diarizer` (#990): "`.package(url: ..., traits: [])` // ASR/VAD only". This would drop the TTS code, the G2P resources, and the diarizer code from an ASR-only build. It is not yet in a tagged release.
- **Catch:** to pass `traits:` on a dependency, the *consuming* manifest must use a tools-version that supports package traits (SwiftPM 6.1+, SE-0450). FluidAudio itself notes that 6.1 "still links a trait-conditioned binary target", so in practice you need 6.2. `Packages/Transcription/Package.swift` is `swift-tools-version: 6.0`. Its comment says: "Using 6.0 (not 6.2) because argmax-oss-swift v1.0.0 requires swift-tools-version 6.0". As long as that stays, Biscotti would get **all default traits** (Rust ITN lib, and on the next release also TTS and diarizer code). Whether a 6.2 root can depend on argmax's 6.0 package is outside this subtopic. Normally a newer root can depend on an older-tools dependency.

### Signing / notarization surface inside `XPCServices/BiscottiTranscriber`

Inference from the manifest and the inspected artifact. Not proven by a build:
- Everything is **statically linked** into the XPC executable: Swift code, two small C/C++ targets, and the Rust `.a`. There is **no embedded framework or dylib**, so there is no new nested code to sign, beyond the SwiftPM resource bundle (a data bundle, signed as part of the host).
- Hardened runtime: there is no JIT or dynamic loading. Core ML and ANE already work in this XPC service with WhisperKit.
- Network: FluidAudio downloads from `huggingface.co` with `URLSession` from inside the process. This is the same as WhisperKit today.
- Env vars the library reads at runtime: `HF_TOKEN` / `HUGGING_FACE_HUB_TOKEN` / `HUGGINGFACEHUB_API_TOKEN` (adds an auth header), `REGISTRY_URL` / `MODEL_REGISTRY_URL` (changes the download host), and `TDT_EMISSION_DELAY_FRAMES` (changes timestamps). These are harmless in an XPC service (it does not inherit a user shell environment), but worth knowing.
- Recommended check (from the draft spec, still valid): prove `make build-app` plus an ad-hoc-signed launch early, before Project 9 (signing/notarization).

---

## 2. Model download, location, progress, offline

### Location: custom directory supported, with a layout quirk

- Default: `~/Library/Application Support/FluidAudio/Models/<repo folderName>/` (`MLModelConfigurationUtils.defaultModelsDirectory`).
- `AsrModels.download(to:)`, `load(from:)`, and `modelsExist(at:version:)` all accept a directory. `UnifiedAsrManager.loadModels(to:)` accepts a *base* directory.
- **Quirk (verified in `AsrModels.swift`):** for the TDT path, the URL you pass is treated as `<parent>/<anything>`. FluidAudio uses `directory.deletingLastPathComponent()` as the parent and writes to `<parent>/<repo.folderName>` (for example `parakeet-tdt-0.6b-v3-coreml`). The last path component you pass is **silently replaced**:
  ```swift
  private static func repoPath(from modelsDirectory: URL, version: AsrModelVersion = .v3) -> URL {
      return modelsDirectory.deletingLastPathComponent()
          .appendingPathComponent(version.repo.folderName)
  }
  ```
  The draft spec's planned layout `models/fluidaudio/parakeet-tdt-0.6b-v3/` would really land at `models/fluidaudio/parakeet-tdt-0.6b-v3-coreml/`. Download, load, and exists all apply the same rewrite, so they stay consistent. But any Biscotti code that probes or deletes paths directly (disk accounting, `modelsPresent()` probes) must use the real folder name. [ManualModelLoading.md](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/ASR/ManualModelLoading.md) agrees: "`AsrModels.load(from:)` expects the directory you pass to be the staged HuggingFace repo folder itself".
- `ModelStorage.clearCache()` removing Biscotti's `models/` root would still cover these files.

### Progress

```swift
public struct DownloadProgress: Sendable { public let fractionCompleted: Double; public let phase: DownloadPhase }
public enum DownloadPhase: Sendable { case listing; case downloading(completedFiles: Int, totalFiles: Int); case compiling(modelName: String) }
public typealias ProgressHandler = @Sendable (DownloadProgress) -> Void   // "Called on an unspecified queue"
```

- The fraction is **byte-weighted** when sizes are known (`ProgressReporter.downloadFraction`) and monotonic *within one operation*. Repo loads give the download phase 50% weight and compile the rest.
- **Caveat (inference from code):** `AsrModels.download` calls `ModelHub.loadModels` **once per model file** (preprocessor, encoder, decoder, joint) with the same handler. So the fraction runs 0→1 four times instead of once across the whole download. Biscotti would need to rescale it per stage. This is still better than WhisperKit's file-count weighting.
- `download` also **loads** each model once (it calls `ModelHub.loadModels(...)` and discards the result). The first download therefore also pays the Core ML compile cost.

### Robustness and pinning

- The downloader has retries, byte-range resume, and a stall watchdog (`DownloadError.stalled`, "byte-range resume continues from the bytes already on disk"), plus completeness checks (#748, #819).
- Offline switch: `ModelHub.offlineMode` (a global static; throws `DownloadError.networkDisabled`). `AsrModels.loadLocal` never touches the network.
- Mirrors: `ModelRegistry.baseURL`, `repoOverrides`, `revisionOverrides`.
- **ASR models download from HF `main`, not a pinned commit.** `Repo.revision` returns a fixed SHA only for `.diarizer`. For everything else it returns `"main"`. A FluidInference push to `parakeet-tdt-0.6b-v3-coreml` therefore changes what new installs get, with no FluidAudio version bump. The repo is mutable: its `main` tree has `Encoder.mlmodelc`, `Encoder_v2.mlmodelc`, `EncoderInt4.mlmodelc`, `JointDecisionv2/v3`, and others, and was last modified 2026-08-19. Biscotti can pin it with `ModelRegistry.revisionOverrides = ["FluidInference/parakeet-tdt-0.6b-v3-coreml": "<sha>"]`.

### Sizes (FluidAudio docs)

v3 ~480 MB · ultra ~630 MB · redux ~220 MB · phonon2 ~360 MB · Unified int8 encoder ~565 MB plus decoder and joint. WhisperKit large-v3 is 626 MB today.

---

## 3. Maturity and release cadence

- Repo created 2025-06-21. 3,158 stars, 480 forks, 25 open issues, last push 2026-10-21 (GitHub API, fetched 2026-10-21).
- **74 tags in ~16 months.** Monthly tag counts for 2026: Jan 4, Feb 2, Mar 9, Apr 7, May 5, Jun 5, Jul 1, Aug 1, Sep 8, Oct 3. That is roughly one release a week in busy months.
- Still **0.x** (semver allows breaking changes). Known batch-ASR break: `transcribe(_:source:)` (≤ v0.13.0) became `transcribe(_:decoderState:)` (v0.14.0). A whole ASR back-end (Qwen3) was added and later removed.
- Concentration: top contributors are `Alex-Wengg` (397 commits) and `BrandonWeng` (198). The next one has 18. **The bus factor is about 2.**
- Scope keeps growing (TTS back-ends, AEC, multiple diarizers). Most recent releases are TTS-focused. ASR changes are mostly long-form seam fixes and new model variants.
- Adoption: the README and `Documentation/Showcase.md` list many shipping apps (VoiceInk, Spokenly, Fluid Voice, Hex, Meetly, and others). Outside that list, MacParakeet is a GPL-3.0 meeting and dictation app that uses FluidAudio with v3 as its default and shows word timestamps plus speaker labels ([repo](https://github.com/moona3k/macparakeet)). That is a close functional precedent for Biscotti.
- Docs lag the source (see [batch-api-and-output.md](./batch-api-and-output.md#docs-vs-source)). Benchmarks.md contains at least one wrong claim (v3 "no punctuation").

What this means: pin an **exact** version, read signatures from source, and treat upgrades as reviewed changes. The draft spec's mitigation still holds. Also pin the HF model revision.

# transcribe.cpp Deep Dive

## Bottom Line

transcribe.cpp is one project: [`handy-computer/transcribe.cpp`](https://github.com/handy-computer/transcribe.cpp) by CJ Pais (the Handy dictation app). It is an MIT-licensed C/C++ engine on vendored ggml, not a whisper.cpp fork. It runs 20+ STT families from its own GGUF files. On Apple Silicon it uses Metal (GPU) and CPU only; it has no Core ML and no Neural Engine path. For our use, only its **Parakeet** family fits (TDT 0.6B v2 for English, `parakeet-ultra` for multilingual). Parakeet gives token and word timestamps at 80 ms resolution, native punctuation, and CC-BY-4.0 weights. Its Whisper port gives segment timestamps only, which is worse than WhisperKit today. The output maps well to our contract with a small glue layer, and we can feed SpeakerKit by building WhisperKit `TranscriptionResult`/`WordTiming` values (public initializers). The main risks are maturity, not output shape: the project is 6.5 months old and pre-1.0, has one maintainer (97.7% of commits), and the v0.4.0 release still runs full attention on long v2/v3 files (the fix is merged to main but not released). There are no published energy or head-to-head numbers against FluidAudio (ANE) on M-series Macs.

## Key Findings

- **Identity is clear.** One real repo, MIT code, 2,073 stars, 24 releases from 2026-06-18 to v0.4.0 (2026-10-12). Forks, Swift re-packagings and one suspicious `.exe` copy (`Bestmed5455`) share the name; "parakeet.cpp" is a different engine. ([identity-and-maturity.md](./identity-and-maturity.md))
- **Only Parakeet (and Nemotron) give word timing.** Whisper in transcribe.cpp is `max_timestamp_kind = segment`; Canary, Cohere, Qwen3, Voxtral give no timestamps. ([whisper.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/whisper.md), `catalog/*.json`)
- **Output shape:** int64 ms timestamps; segment / word / token rows. **Words have no probability**; tokens have `p`. For TDT/RNN-T, `p` is entropy-based confidence `1 − H/Hmax`, not a softmax probability (the header comment says otherwise). No segment confidence, no no-speech probability. ([`include/transcribe.h`](https://github.com/handy-computer/transcribe.cpp/blob/v0.4.0/include/transcribe.h), `src/arch/parakeet/decoder.cpp`)
- **Parakeet returns one segment for the whole clip** (except `parakeet-ultra` on audio > 30 s, which returns one per pause-cut piece). Words are split on SentencePiece `▁` markers and have their leading space trimmed. (`src/arch/parakeet/model.cpp`)
- **No language code from Parakeet.** `transcribe_detected_language()` returns `""` for v2, v3 and ultra. A separate VoxLingua107 LANGID model is available if needed.
- **Word end-time defect:** punctuation tokens keep their TDT duration, so word ends can drift up to 560 ms. The fix ([PR #93](https://github.com/handy-computer/transcribe.cpp/pull/93)) has been open since 2026-07-19. We can apply the same fix in our glue because token rows carry text and times. This matters for SpeakerKit's 0.15 s word-gap splitting.
- **Long audio:** in v0.4.0, v2/v3 run full self-attention over the whole file (estimate: about 32 GB of attention mask for 1 hour, so it cannot ship). [PR #199](https://github.com/handy-computer/transcribe.cpp/pull/199) (merged 2026-10-16, **unreleased**) adds NVIDIA's `[256,256]` local attention, so memory grows linearly and "multi-hour recordings fit". `parakeet-ultra` already cuts audio into ≤30 s pieces at pauses with its own VAD head in v0.4.0. There is no progress callback.
- **Known model-level risk:** TDT v3 can silently drop 5–15 s of clear speech in some windows ([#71](https://github.com/handy-computer/transcribe.cpp/issues/71), open). No status flag reports it.
- **Performance (project data only):** M4 Max Metal, tdt-0.6b-v2 Q8_0: 35 s clip in 142 ms (248× real time); CPU about 36×. A third party measured parakeet-ultra on a 2-minute clip at 1.15 s on M4 Max ([ADE PR #1522](https://github.com/arul28/ADE/pull/1522)). Set the thread count near the number of performance cores; the default was 5× slower. No M1–M3 numbers, no 1-hour numbers and no energy data found.
- **Swift integration:** the release ships `TranscribeCpp.xcframework.zip` (10 MB). It holds a **dynamic**, ad-hoc-signed `CTranscribe.framework` (macOS 13+, system frameworks only, Metal shaders embedded and compiled at run time). The official SwiftPM mirror is "planned but not published" (404). The approach is a remote `binaryTarget` plus vendored MIT wrapper sources — the same pattern this repo already ships for llama.cpp in `BiscottiLLM.xpc`. We must re-sign the framework, set the rpath for the XPC service, and use one `Model` and `Session` per job (unload after the job). The library does no networking and needs no TCC permission. ([integration.md](./integration.md))
- **Model download is fully ours:** one GGUF file per model from `huggingface.co/handy-computer/<variant>-gguf`. Pin a commit URL and a SHA-256, and write the file atomically (weights are mmapped on main). v2 Q8_0 is 730 MB; Q4_K_M is 475 MB with almost no WER loss (1.69% → 1.72%).
- **Licenses:** code is MIT. Parakeet v2, v3 and ultra are CC-BY-4.0 (attribution required). Avoid `canary-1b` (CC-BY-NC) and `granite-5.0-…-nc`. ([catalog](https://github.com/handy-computer/transcribe.cpp/tree/main/catalog))

## Details

- [identity-and-maturity.md](./identity-and-maturity.md): what the project is, other projects with the same name, licenses per model, release history, bus factor, and open defects. Read this to judge whether we can depend on it.
- [models-and-output.md](./models-and-output.md): models and timestamp capability per family, Parakeet variants table, exact C result structs, how token and word times and confidence are computed (with source), language and punctuation behaviour, long-audio analysis (v0.4.0 vs main), Metal-only acceleration, and performance data.
- [integration.md](./integration.md): SwiftPM options, xcframework contents (as verified), hardened-runtime XPC concerns, model download control, and an effort estimate.
- [contract-mapping.md](./contract-mapping.md): field-by-field mapping to `TranscriptResult`/`TranscriptSegment`/`TranscriptWord`, a sketch of the SpeakerKit glue (synthesize WhisperKit types and call `addSpeakerInfo`), and long-audio glue choices.

## Open Questions / Gaps

- **No energy, M1–M3, or 1-hour measurements anywhere.** No head-to-head against FluidAudio (Core ML/ANE), WhisperKit or parakeet-mlx on the same audio. A local benchmark is needed (the [mac-whisper-speedtest](https://github.com/anvanvan/mac-whisper-speedtest) harness could be extended). Inference: because it runs on the GPU, expect more power draw than an ANE engine.
- **The 1-hour peak memory on v0.4.0 is an estimate from source**, not a measurement. 1-hour memory with PR #199 is also unmeasured on a Mac.
- **Release timing of PR #199 is unknown.** Not in any tag as of 2026-10-21.
- **Hardened-runtime XPC behaviour is not tested on hardware.** The assessment comes from the binary and the llama.cpp precedent.
- **Meeting-domain WER** (AMI, Earnings-22) for Parakeet v2 and ultra through transcribe.cpp was not found. The STT model landscape subtopic covers this.
- **Root cause of #71 (dropped spans)** is unresolved: model or port. The maintainer leans toward the model.
- Whether SpeakerKit can be used without the WhisperKit module belongs to the decoupling subtopic.

## Sources

- [handy-computer/transcribe.cpp README](https://github.com/handy-computer/transcribe.cpp/blob/main/README.md): scope, build, bindings, license (main, 2026-10-20)
- [`include/transcribe.h` @ v0.4.0](https://github.com/handy-computer/transcribe.cpp/blob/v0.4.0/include/transcribe.h): authoritative C API, result structs, timestamp and language semantics
- [`src/arch/parakeet/model.cpp`, `decoder.cpp`, `src/conformer/conformer.cpp` @ v0.4.0](https://github.com/handy-computer/transcribe.cpp/tree/v0.4.0/src): how words, times, confidence and attention are computed
- [docs/models/parakeet.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet.md), [parakeet-tdt-0.6b-v2.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet-tdt-0.6b-v2.md), [parakeet-ultra.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet-ultra.md), [whisper.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/whisper.md): variants, WER, M4 Max speed, long-form behaviour
- [docs/input-limits.md @ v0.4.0](https://github.com/handy-computer/transcribe.cpp/blob/v0.4.0/docs/input-limits.md): length contract
- [bindings/swift README and Package.swift @ v0.4.0](https://github.com/handy-computer/transcribe.cpp/tree/v0.4.0/bindings/swift), `scripts/ci/build_xcframework.sh`: Swift packaging
- [v0.4.0 release assets](https://github.com/handy-computer/transcribe.cpp/releases/tag/v0.4.0): xcframework unpacked and inspected (2026-10-21)
- `catalog/*.json` (main): license, languages, timestamp granularity, and benchmark records per model
- [PR #199 Parakeet longform memory](https://github.com/handy-computer/transcribe.cpp/pull/199) (merged 2026-10-16), [PR #93 word timestamps / punctuation duration](https://github.com/handy-computer/transcribe.cpp/pull/93) (open), [Issue #71 dropped span](https://github.com/handy-computer/transcribe.cpp/issues/71) (open), [Issue #221 Parakeet vocabulary](https://github.com/handy-computer/transcribe.cpp/issues/221) (open)
- [Handy issue #2000](https://github.com/cjpais/Handy/issues/2000): long-audio memory and grow-only scratch (2026-08-29 to 2026-10-15)
- [Mozilla.ai: Announcing transcribe.cpp](https://blog.mozilla.ai/announcing-transcribe-cpp/): origin and positioning (2026-06-30)
- [ADE PR #1522](https://github.com/arul28/ADE/pull/1522): third-party Mac and Windows timing, WER and thread tip (2026-10-08)
- [NVIDIA parakeet-tdt-0.6b-v2 model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2): punctuation and casing, 24-minute full-attention limit, CC-BY-4.0
- [argmax-oss-swift v1.0.0](https://github.com/argmaxinc/argmax-oss-swift/tree/v1.0.0): `DiarizationResult.addSpeakerInfo`, `SpeakerInfoStrategy` (0.15 s), WhisperKit type initializers
- GitHub REST API (2026-10-21): repo stats, release list, issue and PR states, repository-name search

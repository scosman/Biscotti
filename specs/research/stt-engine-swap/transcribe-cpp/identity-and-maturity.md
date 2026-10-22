# transcribe.cpp — Identity, License, Maturity

Research date: 2026-10-21. Pinned to release **v0.4.0** (tag date 2026-10-12) unless a line says "main" (main = commit `db678a0`, 2026-10-20, 14 commits after v0.4.0).

## What "transcribe.cpp" is

- **The project:** [`handy-computer/transcribe.cpp`](https://github.com/handy-computer/transcribe.cpp). README: "C/C++ speech-to-text inference library. Runs diverse STT model families via GGUF models on the ggml runtime, with Metal, Vulkan, and CUDA backends for fast GPU inference plus a tinyBLAS-accelerated CPU path." It claims "16 model families and 60+ variants, streaming and batch."
- **Author:** CJ Pais, who also makes the [Handy](https://github.com/cjpais/Handy) dictation app. transcribe.cpp is Handy's engine. The work was supported by the Mozilla.ai Builders-in-Residence program ([Mozilla.ai announcement, 2026-06-30](https://blog.mozilla.ai/announcing-transcribe-cpp/), which calls it "llama.cpp for STT models").
- **Relationship to whisper.cpp / ggml:** It is **not** a fork of whisper.cpp. It is a separate engine that **vendors ggml** (`ggml/UPSTREAM`: upstream `ggml-org/ggml` at sha `d7cb5741…` plus 2 downstream patches). It has its own Whisper port (one of its 20+ families). It uses GGUF model files that it converts and hosts itself under [`huggingface.co/handy-computer`](https://huggingface.co/handy-computer). Before this project, Pais had integrated whisper.cpp into llamafile ("whisperfile") ([Mozilla.ai](https://blog.mozilla.ai/announcing-transcribe-cpp/)).
- **Which models:** Parakeet (14 variants incl. TDT 0.6B v2/v3, "parakeet-ultra", unified-en), Canary, Canary-Qwen, Whisper (all sizes incl. large-v3-turbo), Nemotron streaming, Granite Speech, Cohere Transcribe, Qwen3-ASR, Voxtral, Moonshine, SenseVoice, GigaAM, MedASR, MOSS, Fun-ASR, plus non-ASR roles: Sortformer diarizer, VoxLingua107 language ID, Silero VAD ([README model table](https://github.com/handy-computer/transcribe.cpp/blob/main/README.md)). Details in [models-and-output.md](./models-and-output.md).

## Other projects with the same or a similar name

GitHub repository search for "transcribe.cpp" (2026-10-21) returned 21 repos. Only one is the real engine. The others:

| Repo | What it is |
|---|---|
| `glimpse-hq`, `feiyunwill`, `WhaleChao`, `luantak`, `montvid`, `boxwrench`, `arnoldwender` /transcribe.cpp | Forks of the handy-computer repo (same description). |
| [`Bestmed5455/transcribe.cpp`](https://github.com/Bestmed5455/transcribe.cpp) | Created 2026-07-21, 0 stars, README tells Windows users to download and run an `.exe`. Treat as a **suspicious copy** (possible malware lure). Do not use. |
| [`localai-org/moss-transcribe.cpp`](https://github.com/localai-org/moss-transcribe.cpp) | Different project: a C++ port of one model (MOSS-Transcribe-Diarize). |
| [`NairoDorian/speech.cpp`](https://github.com/NairoDorian/speech.cpp) | Combines "audio.cpp + transcribe.cpp". Derivative. |
| `Beingpax/Transcribe-cpp-swift`, `altic-dev/transcribe-cpp-swift`, `n0an/transcribe-cpp-swift` | Third-party SwiftPM re-packagings of the official Swift binding (see [integration.md](./integration.md)). |
| "parakeet.cpp" ([LocalAI blog](https://localai.io/blog/parakeet-cpp-asr-on-cpu/), [HN](https://news.ycombinator.com/item?id=47176239)) | A **different** ggml Parakeet engine. Not transcribe.cpp. Out of scope here. |
| `vivekuppal/transcribe` | Unrelated Python app. |

Conclusion: there is one transcribe.cpp. All references below are to `handy-computer/transcribe.cpp`.

## License

- **Code:** MIT ([LICENSE](https://github.com/handy-computer/transcribe.cpp/blob/main/LICENSE); GitHub API reports `spdx_id: MIT`). Vendored ggml and miniz are MIT ([THIRD-PARTY-LICENSES.md](https://github.com/handy-computer/transcribe.cpp/blob/main/THIRD-PARTY-LICENSES.md)). The release xcframework ships `LICENSE`, `LICENSE.ggml`, `LICENSE.miniz`, `LICENSE.silero_vad` (all MIT; verified by unpacking the v0.4.0 asset).
- **Models:** each model keeps its upstream license. The GGUF re-packaging does not change it. Per the repo's own catalog records (`catalog/<variant>.json`, field `license`):

| Variant | License (catalog) |
|---|---|
| parakeet-tdt-0.6b-v2, -v3, parakeet-ultra, phonon-2, parakeet-primeline, tdt-1.1b, rnnt/ctc variants | CC-BY-4.0 |
| orukeet | CC-BY-SA-4.0 |
| parakeet-unified-en-0.6b, nemotron-speech-streaming-en-0.6b, multitalker-parakeet | NVIDIA Open Model License (unified-en corrected to this on main in [#214](https://github.com/handy-computer/transcribe.cpp/pull/214)) |
| nemotron-3.5-asr-streaming-0.6b | OpenMDW-1.1 |
| whisper-large-v3 | Apache-2.0 |
| whisper-large-v3-turbo | MIT |
| canary-1b | **CC-BY-NC-4.0** (non-commercial) |
| granite-speech-5.0-470m-turboctc-nc | **CC-BY-NC-SA-4.0** |

  CC-BY-4.0 needs attribution only. That is compatible with a free app. The deeper license review belongs to the "STT model landscape" subtopic.

## Maturity, maintenance, community

Measured from a full clone on 2026-10-21 and the GitHub API.

- **Age:** first commit 2026-04-07 ("first commit"; "working parakeet impl" 2026-04-09). About 6.5 months old.
- **Releases:** 24 tags from v0.0.1 (2026-06-18) to v0.4.0 (2026-10-12). Cadence: almost daily in June; then v0.1.x (Jun 30 – Jul 11), v0.2.0 (Aug 17) – v0.2.4 (Sep 25), v0.3.0/0.3.1 (Oct 3–4), v0.4.0 (Oct 12). Each release ships prebuilt artifacts: `TranscribeCpp.xcframework.zip`, `transcribe-native-*-macos-arm64-metal.tar.gz`, Python wheels, `catalog.db` ([releases API](https://api.github.com/repos/handy-computer/transcribe.cpp/releases)).
- **API stability:** pre-1.0. The header says ABI breaks "are allowed in 0.x without a deprecation cycle" (`include/transcribe.h`). There are migration guides for 0.2 and 0.4 ([migrating-to-0.4.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/migrating-to-0.4.md): roles, diarizers moved to a new session type, NaN audio now rejected). Expect breaking changes on minor bumps.
- **Community:** 2,073 stars, 127 forks, 12 watchers, 45 open issues (GitHub API, 2026-10-21). Last push 2026-10-21.
- **Bus factor: 1.** 555 of 568 commits (97.7%) are by CJ Pais; the next 13 authors have 1 commit each. The maintainer has said he is time-limited and prioritises Handy ([PR #93 comment, 2026-08-15](https://github.com/handy-computer/transcribe.cpp/pull/93)). A useful community PR (Parakeet word-timestamp fix) has been open since 2026-07-19.
- **Engineering quality signals (positive):** every published model is numerically validated tensor-by-tensor against the reference (NeMo, transformers) and WER-tested; the catalog is machine-generated; CI covers native, Swift, Rust, Python, TS ([README](https://github.com/handy-computer/transcribe.cpp/blob/main/README.md), `.github/workflows/`). Sponsors: Mozilla.ai, Hugging Face (storage), Modal (GPU), Blacksmith (CI).
- **Adopters seen:** Handy (moving fully to it; VAD moved in [Handy PR #2267](https://github.com/cjpais/Handy/pull/2267), 2026-10-12); ADE ([PR #1522](https://github.com/arul28/ADE/pull/1522), 2026-10-08); Mac dictation developers re-packaging the Swift binding (VoiceInk author `Beingpax`, `altic-dev`, `n0an`).

## Known open defects relevant to us (as of 2026-10-21)

| Issue | State | Impact |
|---|---|---|
| [#71](https://github.com/handy-computer/transcribe.cpp/issues/71) Parakeet TDT v3: multi-second span silently dropped | Open | Deterministic loss of 5–15 s of speech in some windows; changes with a 10 ms shift. Maintainer suspects the model, not the port (he saw the same in the reference). Two independent reproductions. |
| [#93](https://github.com/handy-computer/transcribe.cpp/pull/93) PR: zero duration for punctuation tokens | Open, unmerged | Without it, TDT word end times can drift "up to 560 ms past the speech" because punctuation tokens keep predicted durations. We can fix this in our glue (see [contract-mapping.md](./contract-mapping.md)). |
| [#199](https://github.com/handy-computer/transcribe.cpp/pull/199) Parakeet long-form memory | **Merged to main 2026-10-16, not in any release** | v0.4.0 runs full attention over the whole file for v2/v3 (quadratic memory). See [models-and-output.md](./models-and-output.md#long-audio). |
| [#221](https://github.com/handy-computer/transcribe.cpp/issues/221) Parakeet: honor `vocabulary` with phrase boosting | Open | No custom vocabulary for Parakeet today. |
| [#162](https://github.com/handy-computer/transcribe.cpp/issues/162) reduce memory across models | Open | General. |
| [Handy #2000](https://github.com/cjpais/Handy/issues/2000) scratch memory is a grow-only high-water mark | Open | GPU scratch is not released while a model stays loaded. Not a problem if the XPC process exits or unloads after each job. |

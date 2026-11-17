# parakeet.cpp (mudler / LocalAI) — ggml Parakeet port, 2026 entrant

Researched 2026-10-21. This project is distinct from `handy-computer/transcribe.cpp`, which another subtopic covers, and from the stale `jason-ni/parakeet.cpp` (21 stars, last push 2025-08).

## Status

- Repo: [mudler/parakeet.cpp](https://github.com/mudler/parakeet.cpp), MIT, created 2026-05-28, 854 stars, last push 2026-10-14. Releases v0.3.1 (2026-06-17) → v0.4.0 (07-01) → v0.5.0 (08-01) → v0.6.0 (10-05) → **v0.6.1 (2026-10-07)**. Each ships `parakeet-vX-lib-macos-metal-arm64.tar.gz` and `-bin-` ([releases API](https://api.github.com/repos/mudler/parakeet.cpp/releases)). It is LocalAI's `parakeet-cpp` backend.
- Claim: "A C++17/ggml port of NVIDIA's NeMo Parakeet speech recognition models ... Transcripts match NeMo (WER 0 on every published NeMo checkpoint)" ([README](https://github.com/mudler/parakeet.cpp)).

## Models

From the README models table, all published as GGUF in [mudler/parakeet-cpp-gguf](https://huggingface.co/mudler/parakeet-cpp-gguf) (f16/q8_0/q6_k/q5_k/q4_k):
parakeet-tdt_ctc-110m, ctc-0.6b/1.1b, rnnt-0.6b/1.1b, **tdt-0.6b-v2**, tdt-1.1b, **tdt-0.6b-v3**, tdt_ctc-1.1b, realtime_eou_120m, **nemotron-3.5-asr-streaming-0.6b** (40+ locales, `--lang auto`), Nemotron-3-Diarization, **moondream parakeet-ultra / parakeet-redux** ("Not NeMo-validated"), Silero VAD. This is the broadest Parakeet coverage of any C/C++ runtime I found.

## Output shape (C API, [docs/capi.md](https://github.com/mudler/parakeet.cpp/blob/master/docs/capi.md))

`include/parakeet_capi.h`: "a flat, exception-free C API for dlopen, FFI and LocalAI", ABI version 10. The offline call `parakeet_capi_transcribe_pcm(ctx, samples, n, sample_rate, 0)` returns text. `parakeet_capi_transcribe_path_json` returns:

```
{"text":"...",
 "frame_sec":0.080000,
 "words":[{"w":"Well,","start":0.480,"end":0.640,"conf":0.7859}, ...],
 "tokens":[{"id":639,"t":0.480,"conf":0.9969}, ...]}
```
"`start`/`end`/`t` are in seconds; `conf` is the rescaled softmax probability of the emitted token in `(0,1]` (a word's `conf` is the `min` over its tokens)". The format "matches NeMo `timestamps=True` + `max_prob`".

- **Word-level and token-level timestamps plus confidence, ready-made.** This is the closest match to our `TranscriptWord` of any library here.
- I found no segment/sentence structure in the JSON. `frame_sec` is given so callers can apply NeMo's `segment_gap_threshold`.
- In-memory PCM with JSON: the [header](https://github.com/mudler/parakeet.cpp/blob/master/include/parakeet_capi.h) has `parakeet_capi_transcribe_pcm_batch_json(_lang)` and `parakeet_capi_transcribe_pcm_nbest_json`. The single-clip JSON calls are path-based (`_path_json`, `_path_json_with`, `_path_json_vad`). So per-word JSON from a PCM buffer goes through the batch call with one item, or we write a temporary WAV file. This is a small wart.
- Language: Nemotron 3.5 supports `--lang auto`. I did not check whether the JSON returns the detected language.

## Long audio

- A plain single pass works past the local-attention threshold. Parity docs report "TED-LIUM long-form, 11 talks, plain single pass" WER, and mention a fixed bug: "Packed Redux single-pass used to segfault above 8192 encoder frames (about 11 minutes ...); fixed" ([docs/parity.md](https://github.com/mudler/parakeet.cpp/blob/master/docs/parity.md)).
- Optional `transcribe --vad` cuts at pauses ("offline, greedy only").
- 1-hour files are not explicitly measured.

## Performance (Apple)

[benchmarks/BENCHMARK.md "Apple Metal (M4)"](https://github.com/mudler/parakeet.cpp/blob/master/benchmarks/BENCHMARK.md): "Apple M4, macOS 26.5. q4_k weights, one 7.4 s clip, best-of-6". tdt-0.6b-v3: **Metal 54.3× RTFx, CPU 19.8×**. tdt-0.6b-v2: 57.1× / 20.1×. "The encoder runs on the GPU; ops without a Metal kernel fall back to CPU automatically". The README limits section adds: "GPU backends are not exercised in CI." A short clip understates long-file throughput. No energy data.

## Swift / XPC integration

- No Swift package or xcframework. Library tarballs for macOS arm64 Metal exist. The README points to a community iOS SwiftUI demo over the streaming C API ([Kashif-E/parakeet-ios-demo](https://github.com/Kashif-E/parakeet-ios-demo)). Integration is the same as for NeMo-Speech.cpp: wrap the dylibs into an XCFramework plus a Swift C shim.
- Models load from a path (`parakeet_capi_load("model.gguf")`), so the app controls download and caching.
- Maturity: one primary maintainer (mudler, of LocalAI), fast cadence, many features added in Sept–Oct 2026 (diarization, speaker ID, bundles). Good momentum but bus-factor and churn risk.

## Note on features we do not need

It now also ships Nemotron-3 diarization, speaker embeddings and a speaker registry ("Speaker embeddings from the C API (2026-10-05)"). This is out of scope (SpeakerKit stays). It does show the project is drifting toward a full pipeline.

# whisper.cpp (ggml-org) — Whisper and, since June 2026, Parakeet

Researched 2026-10-21. Pinned to whisper.cpp **v1.9.5** (2026-10-06) and `master` source.

## Status and maintenance

- Repo: [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp), MIT. Very active: v1.8.6 (2026-06-02) → v1.9.0 (06-17) → v1.9.1 (06-19) → v1.9.2 (08-04) → v1.9.3 (08-20) → v1.9.4 (09-11) → v1.9.5 (10-06), from the [GitHub releases API](https://api.github.com/repos/ggml-org/whisper.cpp/releases).
- Since v1.9.3 the tagged `vX.Y.Z` releases carry **no binary assets**. The xcframework is on the paired nightly build tag (for example [b5454](https://github.com/ggml-org/whisper.cpp/releases/tag/b5454) → `whisper-b5454-xcframework.zip`, 65 MB). v1.9.2 and older carry `whisper-vX.Y.Z-xcframework.zip` on the tag directly. The v1.9.5 notes say: "Maintenance release. Updates to ggml v0.26.0. **Nightly build:** b5454" ([v1.9.5](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.5)).

## Big change: whisper.cpp runs NVIDIA Parakeet TDT

- v1.9.0 (2026-06-17): "parakeet : add support for NVIDIA Parakeet by @danbev in #3735" ([v1.9.0 notes](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.0), [PR #3735](https://github.com/ggml-org/whisper.cpp/pull/3735)). It is a separate library (`libparakeet`, `include/parakeet.h`, `src/parakeet.cpp`) in the same repo, on the same ggml.
- v1.9.2: "include parakeet in build-xcframework.sh" (#3899). The xcframework module map now exports `parakeet.h` next to `whisper.h` ([build-xcframework.sh](https://github.com/ggml-org/whisper.cpp/blob/master/build-xcframework.sh): `framework module whisper { ... header "parakeet.h" ...}`).
- **Models:** the converter is TDT-only: "Convert Parakeet TDT model from NeMo format to ggml format" ([convert-parakeet-to-ggml.py](https://github.com/ggml-org/whisper.cpp/blob/master/models/convert-parakeet-to-ggml.py)). Published conversions: [ggml-org/parakeet-GGUF](https://huggingface.co/ggml-org/parakeet-GGUF) has only `ggml-parakeet-tdt-0.6b-v3` in f32/f16/q8_0/q4_0/q4_k (last modified 2026-06-16). PR #4017 tested `parakeet-tdt-0.6b-v2 f16`, so v2 converts and runs. No CTC, RNNT, 1.1B or Canary path. (The HF card for the ggml repo says `mit`. The upstream weights are CC-BY-4.0 ([nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)). Treat the weights as CC-BY-4.0.)
- **Acceleration:** Parakeet runs on ggml (CPU/NEON + **Metal**; `parakeet_context_params.use_gpu`). The **Core ML/ANE encoder path is Whisper-only** (`src/coreml/whisper-*`). There is also a new `src/aneforge/whisper-aneforge.*`. It "runs the audio encoder directly on the Apple Neural Engine via ANEForge's e5rt dispatch shim", turned on with the env var `ANEFORGE_ENCODER`. It is Whisper-only and is built on a private-framework shim (e5rt), so do not ship it in a notarized app (my inference from the header comment).

### Parakeet correctness history (important: pin ≥ v1.9.4)

- [#4017](https://github.com/ggml-org/whisper.cpp/pull/4017) "parakeet : fix TDT decode by outputting raw logits from the joint graph" (merged 2026-08-29, in **v1.9.4**). Before the fix, on a 27:50 file with v2 f16: "tokens decoded with duration 0: 3,144 / 7,762 (41%)" and "word-end error vs NeMo: mean 89 ms, 1,294 words (36%) > 100 ms". After the fix: "mean 2 ms, 13 words > 100 ms". Decode time on "M-series, Metal" went from 6,532 ms to 2,196 ms. **So word timestamps from v1.9.0–v1.9.3 are wrong. Use v1.9.4 or newer.**
- [#4088](https://github.com/ggml-org/whisper.cpp/issues/4088) "Hallucination with parakeet" (Sept 2026): "Reproduceable with 1.9.2 but no more with master. Closing."
- Security hardening on the Parakeet loader in Jul–Sep 2026 (#3933, #3950, #3957, #4013).
- Open: [#3904](https://github.com/ggml-org/whisper.cpp/pull/3904) parakeet-server, [#4095](https://github.com/ggml-org/whisper.cpp/pull/4095) "diar : add Nemotron 3 Diarization support" (WIP; not relevant because we keep SpeakerKit).

### Parakeet C API output shape (from [`include/parakeet.h`](https://github.com/ggml-org/whisper.cpp/blob/master/include/parakeet.h))

```c
typedef struct parakeet_token_data {
    parakeet_token id;  // the BPE subword ID (0-8191)
    int duration_idx;   // index into the models durations array
    int duration_value; // actual duration value
    int frame_index;
    float p;
    float plog;
    int64_t t0;
    int64_t t1;
    bool is_word_start;
} parakeet_token_data;
```

Accessors: `parakeet_full(ctx, params, samples, n)`, `parakeet_full_n_segments`, `parakeet_full_get_segment_t0/t1/text`, `parakeet_full_n_tokens`, `parakeet_full_get_token_data`, `parakeet_full_get_token_p`, `parakeet_token_to_str`. There are callbacks for new segment, new token, progress, encoder-begin and abort. The only sampling strategy is `PARAKEET_SAMPLING_GREEDY`.

What the source shows ([`src/parakeet.cpp`](https://github.com/ggml-org/whisper.cpp/blob/master/src/parakeet.cpp)):
- **Timestamps are sub-word token level, in 10 ms units (mel frames).** `token_data.t0 = frame_index * subsampling_factor; token_data.t1 = (frame_index + duration_value) * subsampling_factor;` (subsampling factor 8, encoder frame = 80 ms). In the CLI sample, "▁And" has `t0=24 t1=56`, which is 0.24–0.56 s. Words are rebuilt by joining tokens up to the next `is_word_start=true`.
- Punctuation tokens get zero duration and are pinned to the previous token's end: "Collapse punctuation timestamps to match the original Parakeet model" (`refine_timestamps_tdt`).
- **Confidence:** `p` (probability of the emitted token) and `plog` per token. In the CLI sample `p` is about 0.81–1.0. There is no segment-level confidence and no no-speech probability.
- **Segments:** `parakeet_full` produces **one segment for the whole input** (`seg.t0 = 0; seg.t1 = state->n_frames;`). No sentence segmentation, so the app must build segments from tokens.
- **Language:** none. Parakeet v3 auto-handles 25 languages but emits no language ID. The API has no language accessor.
- **Punctuation/casing:** the CLI output is cased and punctuated ("And so, my fellow Americans, ...") ([parakeet-cli README](https://github.com/ggml-org/whisper.cpp/blob/master/examples/parakeet-cli/README.md)).
- **Long audio:** if mel length > `n_audio_ctx` (5000 encoder frames for v3, per the model-load log in #4088), `parakeet_full` builds a **dynamic encoder graph over the whole file** ("audio too long ... using dynamic encoder graph"). Above 8192 encoder frames it switches to local attention: "8192 frames x 80ms = 655 s (about 10.9 mins)" threshold, "128 frames * 80ms = 10.24 s" window each way. So a 1-hour file is one encoder pass with local attention, with no chunk stitching. **Peak memory for a 60-minute file is not documented or measured anywhere I found. This needs a spike.**

## Whisper path (for completeness)

From [`include/whisper.h`](https://github.com/ggml-org/whisper.cpp/blob/master/include/whisper.h):
- `whisper_token_data` has `p`, `plog`, `pt`, `ptsum`, `t0`, `t1` (token-level timestamps from timestamp-token heuristics, enabled by `token_timestamps`), `t_dtw` ("[EXPERIMENTAL] Token-level timestamps with DTW ... Roughly corresponds to the moment in audio in which the token was output") and `vlen`.
- Word-level segments come from `max_len` + `split_on_word`. Each segment has `whisper_full_get_segment_no_speech_prob`. Language comes from `whisper_full_lang_id` / `detect_language`. Built-in Silero VAD (`params.vad`, `vad_model_path`). v1.9.2 adds "map token timestamps to original time when VAD is enabled".
- **DTW conflicts with flash attention, and flash attention is on by default** (`/*.flash_attn =*/ true`). In `whisper_init_with_params_no_state`: "dtw_token_timestamps is not supported with flash_attn - disabling".
- Core ML encoder (ANE) for Whisper is built into the macOS xcframework (`-DWHISPER_COREML="ON" -DWHISPER_COREML_ALLOW_FALLBACK="ON"`), but it needs a separately generated `-encoder.mlmodelc` per model ([README](https://github.com/ggml-org/whisper.cpp#core-ml-support)).
- Models: OpenAI Whisper family in ggml format ([ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp)). This gives the same model family we have free in WhisperKit today, so the Whisper path of whisper.cpp brings **no model upgrade** over the status quo.

## Swift integration

- No `Package.swift` in the repo root (tree listing of `master`). The supported Apple path is the **prebuilt xcframework** consumed as a SwiftPM `binaryTarget(url:checksum:)` ([README "XCFramework"](https://github.com/ggml-org/whisper.cpp#xcframework)). The macOS slice is a dynamic `whisper.framework` (min macOS 13.3, `GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON`, Core ML on) that bundles whisper + parakeet + ggml (from [build-xcframework.sh](https://github.com/ggml-org/whisper.cpp/blob/master/build-xcframework.sh)).
- **This is the same pattern Biscotti already ships.** `Packages/LocalLLM` depends on [mattt/llama.swift](https://github.com/mattt/llama.swift), which is a thin Swift target over `binaryTarget(url: ".../llama.cpp/releases/download/b10549/llama-b10549-xcframework.zip")`, and it runs inside `BiscottiLLM.xpc`. That XPC's entitlements hold only `com.apple.security.app-sandbox = false` (no JIT entitlement), and the app sets `ENABLE_HARDENED_RUNTIME: YES` (`App/project.yml`). A whisper.cpp xcframework inside `BiscottiTranscriber.xpc` would need the same treatment. Caveat: per `CLAUDE.md`, signing/notarization is deferred to Project 9, so "notarizes cleanly" is precedent-by-analogy, not yet proven.
- Community Swift wrappers exist but are all tiny and stale (for example `hedyos/whisper-spm`, `andrii-rubtsov/whisper-cpp-swift`, `Justmalhar/WhisperCppKit`, 0–2 stars, from a [GitHub search](https://api.github.com/search/repositories?q=whisper.cpp+swift+package+xcframework)). Writing our own ~30-line `Package.swift` with a `binaryTarget` is cleaner.
- Risk: two ggml copies (llama.cpp's and whisper.cpp's) must never load in the **same process**. Today they live in separate XPC processes, so this is fine. It only matters if one test target or CLI ever links both `LocalLLM` and the new engine (my inference, not tested).
- Swift strict-concurrency glue: an opaque C context pointer, not thread-safe per context ("Not thread safe for same context"). Wrap it in an actor.

## Model download / caching

None built in for library users. `parakeet_init_from_file_with_params(path, params)` takes a path, and buffer/loader variants exist. The app owns download (URLSession from HF `ggml-org/parakeet-GGUF`), location and integrity checks. q8_0 v3 is about 0.65 GB and f16 about 1.26 GB (the model-load log in #4088 says "model size = 1255.64 MB" for f16).

## Performance on M-series

- No published `parakeet-cli` Metal RTF number. The only first-party timing is #4017's **decode-only** 2.2 s for a 27:50 file on an M3 Max with Metal (encoder time not given).
- The closest proxy is the separate ggml-based [mudler/parakeet.cpp](./parakeet-cpp.md): tdt-0.6b-v3 q4_k on M4 Metal reaches 54.3× real time on a 7.4 s clip (short clip, so fixed overhead dominates).
- No energy data.

## Mapping to the app contract

See [contract-mapping.md](./contract-mapping.md#whispercpp-parakeet-path).

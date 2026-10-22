# transcribe.cpp — Models, Output Shape, Long Audio

Research date: 2026-10-21. Source pinned to tag **v0.4.0** unless marked "main". Source paths are in the [handy-computer/transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) repo.

## 1. Model format and which models matter to us

- **Format:** GGUF only, converted by the project's own Python converters from upstream NeMo / transformers checkpoints. Pre-built files for every variant and quant are on Hugging Face under `handy-computer/<variant>-gguf` ([README "Models"](https://github.com/handy-computer/transcribe.cpp/blob/main/README.md)). Quant presets: F32, F16, Q8_0, Q6_K, Q5_K_M, Q4_K_M.
- **Input:** "v1 accepts only 16 kHz mono float32 PCM. There is no caller-supplied sample rate; the library does not link a resampler" (`include/transcribe.h`, run-params comment). Our `AudioMerger` already produces mono 16 kHz `[Float]`, so this fits without extra work.

### Timestamp capability per family (the deciding factor for SpeakerKit alignment)

From the README family table and `catalog/*.json` (`capabilities.timestamps.granularities`):

| Family | Finest timestamps | Notes |
|---|---|---|
| **Parakeet** (all 14 variants) | **token** (words derived) | The only mainstream English family with sub-segment timing. |
| Nemotron 3.5 ASR streaming 0.6B / Nemotron speech streaming EN | token | Also has an offline path. |
| GigaAM v3, MedASR | token | Russian / medical. Not relevant. |
| Granite Speech 4.1 2B **plus** | word | Hard context cap; 2B params. |
| **Whisper** (all, incl. large-v3, large-v3-turbo) | **segment only** | `docs/models/whisper.md`: "Segment timestamps — the finest granularity the library emits for Whisper (`max_timestamp_kind = segment`). Word-level timestamps are not…" — no DTW / token timestamps. |
| Canary, Canary-Qwen, Cohere, Qwen3-ASR, Voxtral, Granite (non-plus), Moonshine, SenseVoice | none | Text only. |

**Consequence:** for our word↔speaker alignment, only the **Parakeet** family (and Nemotron 3.5) is usable through transcribe.cpp. Whisper through transcribe.cpp is worse than what WhisperKit gives us today (no word timings).

### Parakeet variants worth considering

From [`docs/models/parakeet.md`](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet.md) (WER on LibriSpeech test-clean, Q8_0, measured by transcribe.cpp):

| Variant | Params | Lang | Q8_0 size | WER | PnC | License | Long-audio behaviour |
|---|---|---|---|---|---|---|---|
| `parakeet-tdt-0.6b-v2` | 618M | en | 730 MB | 1.69% | yes ([NVIDIA card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2): "Automatic punctuation and capitalization") | CC-BY-4.0 | single pass (see §5) |
| `parakeet-ultra` | 627M | 25 EU + auto | 740 MB | 1.80% | yes ("punctuated, cased transcript") | CC-BY-4.0 | built-in VAD-head segmentation, ≤30 s segments |
| `parakeet-tdt-0.6b-v3` | 627M | 25 EU + auto | 740 MB | 1.94% | yes | CC-BY-4.0 | single pass |
| `phonon-2` (main only) | 627M | en | 740 MB | 2.15% | — | CC-BY-4.0 | single pass |
| `parakeet-tdt-1.1b` | 1.1B | en | 1.27 GB | 1.38% | **no** ("lowercase, no punctuation") | CC-BY-4.0 | single pass |
| `parakeet-tdt_ctc-110m` | 114M | en | 135 MB | 2.43% | yes | CC-BY-4.0 | single pass |
| `parakeet-unified-en-0.6b` | 618M | en | 731 MB | 1.60% | yes | NVIDIA Open Model License | single pass / streaming |
| `parakeet-rnnt-*`, `parakeet-ctc-*` | 0.6/1.1B | en | — | 1.46–1.87% | **no** (lowercase, no punctuation) | CC-BY-4.0 | single pass |

Project's own guidance: "English transcription → `parakeet-tdt-0.6b-v2`. The default pick" and "Multilingual (25 European languages) → `parakeet-ultra` … A drop-in replacement for `parakeet-tdt-0.6b-v3`" ([parakeet.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet.md)).

`parakeet-ultra` = Moondream's post-trained v3 ([`moondream/parakeet-ultra`](https://huggingface.co/moondream/parakeet-ultra)); long-form TED-LIUM 3 (11 full talks) WER 2.22% at F32 ([parakeet-ultra.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet-ultra.md)). FLEURS-en WER 4.26% (ultra) vs 4.11% (v2) at Q8_0. Quantization costs almost nothing: v2 F32 1.68% → Q4_K_M 1.72%.

Meeting-domain WER (AMI, Earnings) for these models is the "STT model landscape" subtopic's job. One third-party data point: ADE measured parakeet-ultra Q4_K_M at **13.0% vs 16.9%** (whisper.cpp base.en) on a 2-minute earnings-call clip ([ADE PR #1522](https://github.com/arul28/ADE/pull/1522), 2026-10-08).

## 2. Result object (C API)

All from `include/transcribe.h` at v0.4.0.

- "All timestamps are int64_t milliseconds, relative to the original input audio (never to internally padded audio)."
- Results are session-owned and read with accessors: `transcribe_full_text`, `transcribe_raw_text`, `transcribe_detected_language`, `transcribe_returned_timestamp_kind`, `transcribe_n_segments/_words/_tokens`, `transcribe_get_segment/_word/_token`, `transcribe_was_truncated`, `transcribe_was_aborted`, `transcribe_get_timings`.

Exact row structs:

```c
struct transcribe_segment {
    uint64_t     struct_size;
    int64_t      t0_ms;
    int64_t      t1_ms;
    int          first_word;
    int          n_words;
    int          first_token;
    int          n_tokens;
    const char * text;       /* session-owned; see lifetime note above */
    int32_t      speaker_id; /* 1-based; 0 = no speaker attribution */
};

struct transcribe_word {
    uint64_t     struct_size;
    int64_t      t0_ms;
    int64_t      t1_ms;
    int          seg_index;
    int          first_token;
    int          n_tokens;
    const char * text;
};

struct transcribe_token {
    uint64_t     struct_size;
    int          id;
    float        p;
    int64_t      t0_ms;
    int64_t      t1_ms;
    int          seg_index;
    int          word_index;
    const char * text;
};
```

Key observations:

- **Words have no probability field.** Only tokens carry `p`. Word confidence must be aggregated from the word's tokens (`first_token`, `n_tokens`).
- **No segment confidence, no avg-logprob, no no-speech probability, no temperature/compression-ratio.** These Whisper-specific fields do not exist.
- Header on `p`: "the per-token probability when the architecture produces one, or NaN when it does not. The semantic of 'token probability' varies by family (joint softmax for transducer, per-step softmax for autoregressive, per-frame argmax probability for CTC) and callers should treat it as a confidence hint, not a calibrated probability."
- Timestamp request: `transcribe_run_params.timestamps` ∈ {NONE, AUTO, SEGMENT, WORD, TOKEN}. AUTO (default) "resolves it to the finest granularity the model can actually produce". Request **TOKEN** (or AUTO) for Parakeet so token rows (and their `p`) are kept; WORD drops the token table.

### Swift wrapper shape (`bindings/swift/Sources/TranscribeCpp/Transcript.swift`, v0.4.0)

`Transcript { text, rawText, language: String?, timestampKind, segments: [Segment], speakerSegments, words: [Word], tokens: [Token], timings }`; `Word { t0Ms, t1Ms, segIndex, firstToken, nTokens, text }`; `Token { id, p: Float, t0Ms, t1Ms, segIndex, wordIndex, text }`. Same shape as C.

## 3. How Parakeet timestamps, words and confidence are derived (source)

From `src/arch/parakeet/model.cpp` `build_result_from_raw_tokens` and `src/arch/parakeet/decoder.cpp`:

- **Token times:** `t0_ms = round(frame_to_ms * step_at_emit)`; `t1_ms = round(frame_to_ms * (step_at_emit + duration_frames))`. `frame_to_ms` = one encoder frame = "80 ms on v2/v3" (8× subsampling of a 10 ms mel hop). So **timestamp resolution is 80 ms**. For TDT, `duration_frames` is the TDT duration head's prediction; for RNN-T it is 1; CTC uses per-frame argmax.
- **Words:** "words split on SentencePiece marker boundaries" — a token whose raw piece starts with `▁` (U+2581) opens a new word. `word.t0 = first token t0`, `word.t1 = last token t1`. So a word that ends with a punctuation token ("so,") takes the punctuation token's end.
- **Punctuation-duration defect:** TDT gives punctuation tokens a predicted duration. Community PR [#93](https://github.com/handy-computer/transcribe.cpp/pull/93) (open, unmerged at 2026-10-21) found word ends "drifting up to 560 ms past the speech on the validation clip"; NeMo gives punctuation zero duration. After its fix, v2 word times deviate from NeMo by "80 ms max and 3.6 ms mean"; v3 matched exactly. Until it merges, released builds have the drift. We can apply the same rule in our glue because we get token rows with text.
- **Token `p` for TDT/RNN-T is entropy-based confidence, not a softmax probability** (contradicts the header's "joint softmax" wording). `token_confidence()`:

  ```
  token_probs = softmax(token_logits)
  entropy     = -sum(p * log(p + 1e-10))
  max_entropy = log(vocab_size + 1)
  confidence  = 1 - entropy / max_entropy
  ```
  Range [0, 1]. CTC uses `exp(log_softmax[label])` (a real per-frame probability). Inference: the entropy measure is compressed toward 1 for confident tokens and is not on the same scale as Whisper's word probability. Our `TranscriptSanitizer` threshold (0.3 average word probability) must be re-tuned.
- **Segments:** "v1 produces a single segment over the whole clip" for Parakeet. Exception: `parakeet-ultra` on audio > 30 s returns one segment per VAD-cut piece (results are concatenated with `base_word` / `first_word` offsets; `model.cpp` ~L1675–1722). So for v2/v3 we must build our own segments (or let SpeakerKit's subsegment strategy do it).
- **Special tokens:** language tags `<ll-RR>` and `<unk>` are stripped by default (`keep_special_tags = false`).

## 4. Language and punctuation

- **Language detection output:** `transcribe_detected_language()` "Returns an empty string when … the model does not support language detection … or the caller passed an explicit params->language hint". The Parakeet sources never assign `detected_language` (grep of `src/arch/parakeet/` finds no writer; only whisper, qwen3_asr, sensevoice set it). So **Parakeet v2, v3 and ultra all return `""`**, even though v3/ultra are tagged "auto-detect" (they transcribe whatever European language they hear, but do not report it). Docs: for v3 lineage "the language hint is accepted but does not change the output".
  - If we need a language code, transcribe.cpp offers a separate LANGID role model, VoxLingua107 ECAPA-TDNN (Apache-2.0, 107 languages; `LangIdSession`, [docs/langid.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/langid.md)). Or we hard-code "en" for v2.
  - Known v3 problem: "`parakeet-tdt-0.6b-v3` and its fine-tunes can drift into English on accented spontaneous speech" ([parakeet.md, main](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet.md)).
- **Punctuation/casing:** native in v2, v3, ultra, tdt_ctc-110m/1.1b, unified-en; absent in rnnt-*, ctc-*, tdt-1.1b. The runtime `pnc` toggle is ignored by Parakeet ("families that do not (whisper, parakeet, ...) ignore it"). v3 lineage writes German "ss" for "ß".
- **Custom vocabulary:** not supported for Parakeet ([#221](https://github.com/handy-computer/transcribe.cpp/issues/221) open). Our custom-vocab work is blocked anyway (see repo CLAUDE.md).

## 5. Long audio (1-hour meetings) {#long-audio}

### What the docs say

- v0.4.0 [`docs/input-limits.md`](https://github.com/handy-computer/transcribe.cpp/blob/v0.4.0/docs/input-limits.md): parakeet is "chunked / unbounded", `max_audio_ms = 0`, "the Conformer encoder's positional encoding is recomputed per call, so audio of any length is processed in a single pass — pass arbitrarily long recordings." Parakeet "never error[s] on length."

### What the v0.4.0 source actually does (important)

- For full-attention checkpoints (v2, v3, orukeet, primeline, tdt-1.1b, rnnt/ctc), v0.4.0 runs **full self-attention over the entire file**. `src/conformer/conformer.cpp` builds the relative-position bias "one head at a time so the allocator never needs the [2*T-1, T, H] F32 result at once", but it still concatenates an F16 `[T, T, H]` mask for flash attention.
- **My estimate (inference, not measured):** 1 hour = 45,000 encoder frames (80 ms). An F16 `[T, T, 8 heads]` mask = 45,000² × 8 × 2 B ≈ **32 GB**, plus a transient F32 `[2T−1, T]` per head ≈ 16 GB. That does not fit on normal Macs. NVIDIA rates full attention for "up to 24 minutes in a single pass" on an 80 GB A100 ([NVIDIA v2 card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)).
- The project admits the problem: Handy issue "[GigaAM/Parakeet Using Excessive Memory on Long Audio](https://github.com/cjpais/Handy/issues/2000)"; maintainer on 2026-10-15: "#208 will help for gigaam, parakeet is next".

### Fix on main (unreleased)

- [PR #199 "Parakeet longform memory"](https://github.com/handy-computer/transcribe.cpp/pull/199), merged 2026-10-16 (after v0.4.0): "Default `[256,256]` local attention on full-attention checkpoints (v2, v3, orukeet, primeline, 1.1B/110M TDT/RNN-T/CTC), NVIDIA's documented long-audio mode. Clips up to 20.5 s run the full-attention graph and are bit-identical to main." Main's `parakeet.md`: "encoder time and memory grow linearly with length instead of quadratically, so a 25-minute talk runs on a 16 GB laptop and multi-hour recordings fit."
- WER with the window (Q8_0, full → window): v2 TED-LIUM full talks 3.20 → 3.11; v2 LibriSpeech 1–5 min clips 1.63 → 1.74; v3 TED full talks 2.87 → 2.71. French on v3 full talks regresses 12.4 → 17.7.
- Other memory work also unreleased on main: mmap of weights ([#195](https://github.com/handy-computer/transcribe.cpp/pull/195)).

### parakeet-ultra is already bounded in v0.4.0

`parakeet-ultra` cuts audio > 30 s at pauses using its own VAD head (thresholds stored in GGUF; matches Moondream's runtime "sample for sample"), transcribes each ≤30 s piece independently with full attention, and shifts timestamps to file time ([parakeet-ultra.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet-ultra.md)). This path is in the v0.4.0 tag (`src/arch/parakeet/longform.cpp` exists there). It also returns **multiple segments** (one per piece), which gives natural pause-based segment boundaries.

### Other long-audio properties

- **No progress callback** for an offline `transcribe_run`. There is only an abort callback / `CancellationToken`. For a progress bar on a 1-hour file we must chunk ourselves.
- **Silent span drops** in TDT v3 ([#71](https://github.com/handy-computer/transcribe.cpp/issues/71), open): 5–15 s of clear speech vanish deterministically in some ~70 s windows; shifting input by 10 ms moves the hole. Not flagged by `was_truncated`. Maintainer thinks it is a model property. A word-gap check (e.g. > 5 s gap while VAD says speech) plus re-decode of an offset window is a possible mitigation (suggested in the thread; not implemented upstream).

## 6. Apple Silicon acceleration

- **Metal (GPU) + CPU only.** "Metal is enabled automatically on Apple Silicon" (README). `CMakeLists.txt`: `option(TRANSCRIBE_METAL … ${TRANSCRIBE_IS_APPLE_SILICON})`; `GGML_METAL_EMBED_LIBRARY ON`. CPU path uses Accelerate + tinyBLAS.
- **No Core ML, no Apple Neural Engine.** A grep of `CMakeLists.txt`, README and `docs/` for "coreml" / "neural engine" finds nothing. (whisper.cpp has an optional Core ML encoder; transcribe.cpp does not.)
- Handy logs show `ggml_metal_device_init: tensor API disabled for pre-M5 and pre-A19 devices` (via a search summary of Handy issues; not verified first-hand) — ggml uses the newer Metal tensor API only on M5+.

## 7. Performance numbers found

Project catalog (`catalog/parakeet-tdt-0.6b-v2.json`, measured 2026-09-14 at commit `77b0c93`, profile `asr-publication-v2`, mean of 3 after 1 warm-up). Only M4 Max is published; only short clips:

| Model | Backend | Clip | Q8_0 compute | RTFx |
|---|---|---|---|---|
| tdt-0.6b-v2 | Metal | jfk 11.0 s | 55 ms | 200× |
| tdt-0.6b-v2 | Metal | dots 35.3 s | 142 ms | 248× |
| tdt-0.6b-v2 | CPU | dots 35.3 s | 987 ms | 36× |
| tdt-0.6b-v3 | Metal | dots 35.3 s | 164 ms | 215× |
| tdt-0.6b-v3 | CPU | dots 35.3 s | 1.00 s | 35× |

Model load ≈ 150–250 ms. Encode dominates (113 ms of 142 ms for v2 Metal on 35 s).

Third party: ADE, parakeet-ultra Q4_K_M, 2-minute clip: **M4 Max Metal 1.15 s** vs 2.9 s for whisper.cpp base.en; tip: "Threads are capped near the physical core count; transcribe.cpp's default of every logical CPU was 5x slower" ([ADE PR #1522](https://github.com/arul28/ADE/pull/1522)).

**Not found:** any published head-to-head of transcribe.cpp vs FluidAudio (Core ML/ANE), parakeet-mlx or WhisperKit on the same Mac and same audio; any number on M1/M2/M3 base chips; any **energy** measurement; any 1-hour wall-clock or peak-memory figure. A search summary noted a separate benchmark ([mac-whisper-speedtest](https://github.com/anvanvan/mac-whisper-speedtest)) where FluidAudio (ANE) was 2.6× faster than parakeet-mlx (GPU) on an M4 MacBook Pro; transcribe.cpp was not in it. Inference: transcribe.cpp runs on the GPU like MLX, so expect higher power draw than an ANE engine; measure before deciding.

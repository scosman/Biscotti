# STT model landscape (October 2026) — English-first meeting transcription

Research date: 2026-10-21. Benchmarks are from the HF Open ASR Leaderboard data files at the revision the leaderboard pins for its "21-10-2026" version, plus model cards fetched this session.

## 1. Open ASR Leaderboard — open-weight models, English short-form

Source: `english_short_latest.csv` at revision `648e485…` of [hf-audio/open-asr-leaderboard-results](https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results), the revision that [the leaderboard space's `init.py`](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard) pins for version "21-10-2026" ("Add ibm-granite/granite-speech-5.0-2b. Update fast-gpu-asr results."). Evals run on H200 GPUs with an updated normalizer since 2026-06-24 (leaderboard changelog). WER ignores punctuation and casing.

"Mean8" is **my** arithmetic mean of the 8 public sets that every row has (AMI-Cleaned, Earnings22-Cleaned-AA-chunked, Gigaspeech-Cleaned, LS-clean, LS-other, SPGISpeech, Voice Arena Monsoon, VoxPopuli-AA-Cleaned). It is not the leaderboard's displayed average: that average also folds in gated private Appen/DataOcean sets, which I could not download. Proprietary APIs are omitted. Rows whose RTFx comes from the "fast-gpu-asr" runtime are omitted (same weights as the base rows).

| Model | License | Params (B) | Mean8 | **AMI-C** (meetings) | Earn22-C | LS-clean | LS-other | RTFx (GPU) |
|---|---|---|---|---|---|---|---|---|
| Qwen/Qwen3-ASR-1.7B | Apache-2.0 | 2.04 | **4.31** | 8.31 | 5.84 | 1.26 | 2.94 | 836 |
| HojoAI/Hojo-ASR-V1 | Apache-2.0 | 5.18 | 4.33 | 7.54 | 6.97 | 1.30 | 3.24 | 73 |
| bosonai/higgs-audio-v3-stt | Apache-2.0 | 2.68 | 4.39 | 7.19 | 7.04 | 1.08 | 2.61 | 110 |
| ibm-granite/granite-speech-5.0-2b | Apache-2.0 | 2 | 4.42 | **6.96** | 6.22 | 0.99 | 2.21 | 545 |
| nvidia/canary-qwen-2.5b | CC-BY-4.0 | 2.5 | 4.43 | 7.91 | 6.41 | 1.23 | 2.63 | 882 |
| Edge0/ARK-ASR-3B | Apache-2.0 | 3.75 | 4.47 | 7.89 | 8.07 | 1.04 | 2.37 | 480 |
| TheStageAI/thewhisper-large-v3-turbo | CC-BY-4.0 | 0.8 | 4.54 | 7.32 | 7.18 | 1.41 | 3.20 | 1184 |
| Edge0/ARK-ASR-0.6B | Apache-2.0 | 1.15 | 4.56 | 8.61 | 6.75 | 1.48 | 3.44 | 673 |
| ibm-granite/granite-speech-4.1-2b | Apache-2.0 | 2 | 4.62 | 7.06 | 6.69 | 1.03 | 2.19 | 547 |
| OpenMOSS-Team/MOSS-Transcribe-Diarize | Apache-2.0 | 0.91 | 4.64 | 8.33 | 6.09 | 1.66 | 4.16 | 387 |
| CohereLabs/cohere-transcribe-03-2026 | Apache-2.0 | 2 | 4.67 | 7.02 | 7.88 | 0.97 | 2.05 | 924 |
| ibm-granite/granite-speech-4.1-2b-nar | Apache-2.0 | 2 | 4.67 | 6.96 | 6.67 | 1.04 | 2.40 | 2113 |
| **nvidia/parakeet-tdt-0.6b-v2** | CC-BY-4.0 | 0.6 | **4.70** | 9.09 | 6.76 | 1.28 | 2.73 | **6148** |
| **nvidia/parakeet-tdt-0.6b-v3** | CC-BY-4.0 | 0.6 | **4.84** | 9.42 | 5.85 | 1.52 | 3.13 | **6228** |
| ibm-granite/granite-speech-5.0-470m-turboctc-**nc** | **CC-BY-NC-SA-4.0** | 0.47 | 4.84 | 7.31 | 8.23 | 1.45 | 2.67 | 20801 |
| mistralai/Voxtral-Small-24B-2507 | Apache-2.0 | 24 | 4.99 | 13.19 | 7.07 | 1.23 | 2.80 | 101 |
| microsoft/Phi-4-multimodal-instruct | MIT | 6 | 5.02 | 9.12 | 7.09 | 1.35 | 3.45 | 163 |
| ibm-granite/granite-speech-5.0-470m-turboctc | Apache-2.0 | 0.47 | 5.03 | 7.71 | 6.75 | 1.48 | 2.71 | 21134 |
| Qwen/Qwen3-ASR-0.6B | Apache-2.0 | 0.78 | 5.04 | 9.33 | 7.83 | 1.70 | 4.01 | 750 |
| ibm-granite/granite-4.0-1b-speech | Apache-2.0 | 2 | 5.09 | 7.38 | 8.53 | 1.11 | 2.50 | 667 |
| nvidia/nemotron-speech-streaming-en-0.6b | NVIDIA Open Model | 0.62 | 5.25 | 8.84 | 9.45 | 1.89 | 4.35 | 1114 |
| distil-whisper/distil-large-v3.5 | MIT | 0.8 | 5.40 | 12.09 | 7.70 | 1.94 | 4.52 | 898 |
| mistralai/Voxtral-Mini-3B-2507 | Apache-2.0 | 5 | 5.54 | 13.57 | 7.66 | 1.48 | 3.63 | 180 |
| microsoft/VibeVoice-ASR-HF | MIT | 8 | 5.58 | 12.02 | 7.97 | 1.56 | 4.95 | 218 |
| nvidia/canary-1b-v2 | CC-BY-4.0 | 1 | 5.71 | 13.03 | 7.28 | 1.76 | 3.07 | 1854 |
| openai/whisper-large-v3 | Apache-2.0* | 2* | 5.78 | 13.63 | 7.99 | 1.56 | 3.52 | 471 |
| **openai/whisper-large-v3-turbo** (≈ our free model) | MIT | 0.8 | **6.36** | **13.88** | 8.09 | 2.13 | 3.71 | 811 |
| mistralai/Voxtral-Mini-4B-Realtime-2602 | Apache-2.0 | 4 | 6.46 | 13.34 | 9.31 | 1.62 | 4.94 | 103 |
| nvidia/nemotron-3.5-asr-streaming-0.6b | OpenMDW-1.1 | 0.64 | 7.88 | 13.43 | 15.30 | 2.83 | 6.79 | 1348 |

\* The leaderboard CSV lists `openai/whisper-large-v3` as "apache-2.0", "2" B. The HF card for large-v3 also says `license: apache-2.0` (large-v3-turbo's card says MIT), and its size table gives "1550 M" params for large, so "2" B is rounding.

Not on the current leaderboard: **Kyutai STT** (the Cohere card's 2026-03-26 leaderboard snapshot shows Kyutai STT 2.6B at avg 6.40, AMI 12.17 — older dataset versions, not comparable to the table above); **Moonshine** (`moonshine-base` was removed 2026-07-31; Moonshine Streaming Medium self-reports AMI 10.68 / avg 6.65 on the old dataset versions); **parakeet-unified-en-0.6b** and **canary-1b-flash** (not listed).

## 2. Open ASR Leaderboard — long-form tab

Source: `longform_latest.csv` at revision `4f164c2…` of [hf-audio/leaderboard_longform](https://huggingface.co/datasets/hf-audio/leaderboard_longform) (TED-LIUM was removed from the main tabs on 2026-05-20 because of a license change, but this file still has a column for it).

| Model | Avg | earnings21 | earnings22 | CORAAL avg | RTFx |
|---|---|---|---|---|---|
| CohereLabs/cohere-transcribe-03-2026 | 9.73 | 8.70 | 12.66 | 15.34 | 418 |
| nvidia/parakeet-tdt-0.6b-v3 | 10.72 | 9.96 | 14.58 | 15.57 | 1003 |
| openai/whisper-large-v3-turbo | 11.01 | 9.84 | 13.10 | 17.87 | 148 |
| nvidia/parakeet-tdt-0.6b-v2 | 11.18 | 10.75 | 13.25 | 17.64 | 956 |
| nvidia/canary-qwen-2.5b | 11.20 | 9.60 | 13.59 | 19.05 | 16 |
| openai/whisper-large-v3 | 11.23 | 9.71 | 13.16 | 18.89 | 69 |
| distil-whisper/distil-large-v3.5 | 11.69 | 10.60 | 14.03 | 17.61 | 156 |

**Reading:** on long-form *earnings-call* audio (single dominant speaker, studio-ish), Whisper turbo and Parakeet are about equal, and Whisper is slightly better on earnings22. Parakeet's clear win is on **AMI** (multi-speaker meeting audio: 9.1–9.4 vs 13.9) and on speed. Qwen3-ASR, Granite and Cohere are not on the long-form tab. Long-form numbers for them are a gap.

## 3. Per-model profiles

Feature cells: **P&C** = punctuation and capitalization. "Native" timestamps = the decoder emits them (not a separate aligner). Sizes come from model cards. Memory figures are a rough derivation (fp16 ≈ 2 bytes/param) unless a card states them.

### NVIDIA Parakeet TDT 0.6B v2 (English) — released 2025-04-15
- **Card:** [nvidia/parakeet-tdt-0.6b-v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2). "600-million-parameter … high-quality English transcription, featuring support for punctuation, capitalization, and accurate timestamp prediction." FastConformer-TDT, "trained with full attention, enabling efficient transcription of audio segments up to 24 minutes in a single pass."
- **P&C:** yes ("Punctuations and Capitalizations included").
- **Timestamps:** native char/word/segment (`timestamps=True` → `timestamp['word']`, `['segment']`, `['char']`). TDT predicts token durations jointly. See [features-matrix.md](./features-matrix.md) for measured quality.
- **Confidence:** NeMo can output per-frame/token/word confidence in [0,1] (entropy or max-prob based). This is a decoding feature, not a model output. A runtime must reimplement it.
- **Language:** English only. **Long-form:** 24 min in one pass with full attention (on GPU). Longer audio needs local attention or chunking. "At least 2GB RAM for model to load."
- **WER (card, older leaderboard):** avg 6.05, AMI 11.16, Earnings22 11.15. Current leaderboard: see table.
- **License:** CC-BY-4.0.

### NVIDIA Parakeet TDT 0.6B v3 (25 European languages) — released 2025-08-04
- **Card:** [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3). "Extends … v2 … from English to 25 European languages. The model automatically detects the language of the audio and transcribes it without requiring additional prompting."
- **P&C:** yes. The card states "Automatic **punctuation** and **capitalization**" and "Other Properties Related to Output: Punctuations and Capitalizations included." This answers the question the `fluid_audio_engine` draft raised about v3 punctuation, at least at the model level (a runtime/conversion could still drop it — FluidAudio subtopic).
- **Timestamps:** native word/segment/char, same as v2.
- **Language ID:** automatic, but the card does **not** say that the model reports a language label. Treat language output as "not provided" until a runtime shows otherwise.
- **Long-form:** "up to 24 minutes long with full attention (on A100 80GB) or up to 3 hours with local attention" (`change_attention_model("rel_pos_local_attn", [256,256])`).
- **WER:** card OpenASR avg 6.34 (AMI 11.31, Earnings22 11.42). Multilingual FLEURS avg 11.97 %, en 4.85 %. Paper: v3 averages 9.7 % across 24 languages, "edging past whisper-large-v3 (9.9%)" ([arXiv 2509.14128](https://arxiv.org/html/2509.14128v1)).
- **License:** CC-BY-4.0.
- **English-only users:** v3 is about 0.14 points worse than v2 on Mean8 and slightly worse on AMI (9.42 vs 9.09), but better on Earnings22 (5.85 vs 6.76).

### NVIDIA parakeet-unified-en-0.6b — released 2026-04-07
- **Card:** [nvidia/parakeet-unified-en-0.6b](https://huggingface.co/nvidia/parakeet-unified-en-0.6b). English, FastConformer + **RNNT** (not TDT), one model for offline + streaming. "Transcribes speech to English alphabet, spaces, and apostrophes with punctuation and capitalization support."
- **WER (card, w/o P&C, whisper-normalizer):** offline avg **5.91** vs parakeet-tdt-0.6b-v2 **6.04** on the same harness. Not on the official leaderboard.
- **Timestamps:** the card does not mention timestamps. RNNT in NeMo can produce them, but this is **unverified** for this model.
- **License:** ⚠️ **NVIDIA Open Model License**, not CC-BY. It allows commercial use and redistribution, but has a guardrail-bypass termination clause and a required NOTICE (see [licenses.md](./licenses.md)).
- Gain over v2 is small (about 0.13 WER points). The license is more restrictive.

### NVIDIA Canary family
- **canary-1b-v2** ([card](https://huggingface.co/nvidia/canary-1b-v2)): 978M params, 25 European languages, ASR + translation, P&C, "Accurate word-level and segment-level timestamps". The usage passes `source_lang='en'` (language is specified, not detected, in the example). CC-BY-4.0. Leaderboard AMI 13.03 / Mean8 5.71 — **worse than Parakeet on meetings**.
- **canary-1b-flash** ([card](https://huggingface.co/nvidia/canary-1b-flash)): 883M, 4 languages (en/de/fr/es), "experimental feature for word-level and segment-level timestamps". CC-BY-4.0. Superseded by v2.
- **canary-qwen-2.5b** ([card](https://huggingface.co/nvidia/canary-qwen-2.5b)): 2.5B speech-LLM (FastConformer + Qwen LLM), **English only**, P&C. "The maximum audio duration in training was 40s … accuracy may be degraded" for longer input → needs chunking. Card describes no timestamps. CC-BY-4.0. Strong WER (Mean8 4.43, AMI 7.91), but slow on long-form (RTFx 16 on the long-form tab) and no timestamps.

### OpenAI Whisper large-v3-turbo (the free baseline)
- **Card:** [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo). Large-v3 with decoder layers "reduced from 32 to 4". 809M params. 99 languages, language detection, translation. MIT.
- **P&C:** yes. **Timestamps:** segment timestamps are native tokens. Word timestamps are inferred after decoding from cross-attention (DTW). **Confidence:** token log-probs (WhisperKit exposes word `probability`).
- **Long-form:** "Whisper has a receptive field of 30-seconds", so it needs sequential or chunked long-form decoding. Prone to hallucinations and repetition on silence/noise (repo validation saw trailing hallucinated segments).
- **WER:** Mean8 6.36, **AMI 13.88**. Long-form avg 11.01.

### distil-whisper/distil-large-v3.5
- [Card](https://huggingface.co/distil-whisper/distil-large-v3.5): MIT, English only, "~1.5x faster than Whisper-Large-v3-Turbo while performing slightly better on short-form transcription and falling ~1% behind on long-form". Mean8 5.40, AMI 12.09. Has the same Whisper timestamp/hallucination profile. Not a meaningful upgrade for meetings.

### Qwen3-ASR 0.6B / 1.7B (Alibaba Qwen)
- **Card:** [Qwen/Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B). Apache-2.0. "Language identification and ASR for 52 languages and dialects" (30 languages + 22 Chinese dialects). Offline and streaming in one model, "support transcribe long audio" (no hard limit stated). Speech-LLM (built on Qwen3-Omni audio stack).
- **P&C:** yes (LLM output). **Timestamps:** **not native** — they come from a separate model, **Qwen3-ForcedAligner-0.6B**: "timestamp prediction for arbitrary units within up to 5 minutes of speech in 11 languages" (so long audio must be aligned in ≤5-min pieces). **Confidence:** not documented.
- **WER:** 1.7B is the **best open model on Mean8 (4.31)**, AMI 8.31, Earnings22 5.84. 0.6B: Mean8 5.04, AMI 9.33.
- Argmax chose Qwen3-ASR as its new top Pro model (SDK 3, 2026-09-23). Free use of the weights is fine. A free Apple-Silicon runtime would need the ASR model plus the aligner (other subtopics).
- Total model size for timestamps: 1.7B + 0.6B aligner ≈ 2.3B params (~4.6 GB fp16, derived).

### IBM Granite Speech (Apache-2.0 throughout, except one `-nc` variant)
- **granite-speech-5.0-2b** (released **2026-10-20**, [card](https://huggingface.co/ibm-granite/granite-speech-5.0-2b)): en/fr/de/es/pt/ja ASR + translation, keyword biasing (up to 2000 terms), P&C via prompt. "For best results, transcribe audio in segments of up to ~2 minutes; split longer recordings (e.g. with VAD)". **Best AMI of any open model (6.96)**, Mean8 4.42. Card shows no timestamps.
- **granite-speech-4.1-2b** (2026-04-29): similar. AMI 7.06.
- **granite-speech-4.1-2b-plus** ([card](https://huggingface.co/ibm-granite/granite-speech-4.1-2b-plus)): adds **speaker-attributed ASR** and **word-level timestamps** as `[T:N]` centisecond tags generated by the LLM; "works well with audio segments up to 9 minutes long for ASR and SAA, and up to 3.5 minutes for timestamps." LLM-generated timestamps can fail like any generated text.
- **granite-speech-4.1-2b-nar**: non-autoregressive (CTC encoder + LLM editor), RTFx 2113, AMI 6.96.
- **granite-speech-5.0-470m-turboctc** (multilingual update **2026-10-21**, [card](https://huggingface.co/ibm-granite/granite-speech-5.0-470m-turboctc)): 470M **CTC** conformer, 7 languages, "Native punctuation & capitalization", "well suited for deployment on laptops, smartphones and other edge devices". Card gives an `mlx-audio` path for Apple Silicon. Leaderboard row (English-only release): Mean8 5.03, AMI 7.71. CTC gives frame-level alignment in principle, but the card documents no timestamp API — **unverified**. ⚠️ A sibling `granite-speech-5.0-470m-turboctc-nc` is **CC-BY-NC-SA-4.0** — do not use.

### Cohere Transcribe (cohere-transcribe-03-2026)
- [Card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026): 2B Conformer enc-dec, 14 languages, Apache-2.0, gated (must agree to share HF contact info). P&C on by default. Long-form via automatic chunking. Best open long-form avg (9.73).
- **Limitations (verbatim):** "**Timestamps/Speaker diarization.** The model does not feature either of these." and "It does not feature explicit, automatic language detection". Recommends a VAD/noise gate to prevent hallucinations.
- **Unsuitable** for Biscotti as-is: no timestamps means no word↔speaker alignment.

### Kyutai STT
- [kyutai/stt-2.6b-en](https://huggingface.co/kyutai/stt-2.6b-en), [stt-1b-en_fr](https://huggingface.co/kyutai/stt-1b-en_fr): CC-BY-4.0. 2.6B English (2.5 s delay) and 1B en/fr (0.5 s delay, semantic VAD). Streaming "delayed streams" models. "Produces transcripts with capitalization and punctuation." "Perform[s] well with audio as long as 2 hours." Timestamps: "can be recovered by subtracting the model's text stream offset (0.5 or 2.5 seconds) from the frame's offset" (native, frame-based). Mar-2026 leaderboard snapshot: avg 6.40, AMI 12.17 — **worse than Parakeet on meetings**. Runtime: Kyutai's own Rust/PyTorch/MLX stack.

### Moonshine (Moonshine AI / Useful Sensors)
- Moonshine v2 / "Streaming" Tiny 34M, Small 123M, Medium 245M — **English only** for the large sizes ([moonshine-streaming-medium card](https://huggingface.co/moonshine-ai/moonshine-streaming-medium), [arXiv 2602.12241](https://arxiv.org/html/2602.12241)). Medium: AMI 10.68, avg 6.65 (old dataset versions). MIT for all streaming and English models. Legacy non-English non-streaming models stay under the non-commercial Moonshine Community License ([LICENSE](https://github.com/moonshine-ai/moonshine/blob/main/LICENSE)). Designed for live, low-latency captioning on CPU. The card names hallucination/repetition as a known limitation and documents no word timestamps. Not a quality upgrade over Parakeet for batch meetings.

### Mistral Voxtral
- **Voxtral Mini 3B (2507)** / **Small 24B (2507)**: Apache-2.0, speech-LLMs, "audios up to 30 minutes for transcription", automatic language detection ([card](https://huggingface.co/mistralai/Voxtral-Mini-3B-2507)). AMI 13.57 / 13.19 — **poor on meetings**. No native timestamps in the open card.
- **Voxtral Mini 4B Realtime 2602**: Apache-2.0, 4B, BF16, 13 languages, streaming (delays 240 ms–2.4 s) ([card](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602)). AMI 13.34.
- **Voxtral Mini Transcribe V2** (batch, with diarization + word timestamps, up to 3 h) is **API-only**. Only Realtime has open weights ([Mistral, 2026-02-04](https://mistral.ai/news/voxtral-transcribe-2/)).

### Others worth knowing (large or niche)
- **microsoft/VibeVoice-ASR** (MIT, ~8B on leaderboard): "60-minute long-form audio in a single pass" with speaker + timestamps + 50 languages ([card](https://huggingface.co/microsoft/VibeVoice-ASR)). AMI 12.02. Too large for an 8 GB Mac, and it does its own diarization (we keep SpeakerKit).
- **OpenMOSS MOSS-Transcribe-Diarize 0.9B** (Apache-2.0, released 2026-07-09): joint ASR + diarization + timestamps, 50+ languages, "up to 90 minutes" single pass ([card](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize)). AMI 8.33, Mean8 4.64. Interesting, but its value is joint diarization, which overlaps SpeakerKit. Timestamp granularity per word is not stated in what I read.
- **microsoft/Phi-4-multimodal-instruct** (MIT, 6B): Mean8 5.02. Too large for its benefit.
- **NVIDIA Nemotron streaming** (en-0.6b: NVIDIA Open Model License; 3.5-asr-streaming-0.6b: OpenMDW-1.1, 40 locales): built for streaming. Batch WER is worse than Parakeet TDT.
- **Edge0 ARK-ASR 0.6B/3B, HojoAI Hojo-ASR-V1, bosonai higgs-audio-v3-stt**: new 2026 Apache-2.0 entrants with good leaderboard numbers. I did not research their timestamp/confidence support (beyond scope/time). They are mostly LLM-style decoders, which suggests no native word timestamps (inference, unverified).
- **soundsgoodai Zipformer-XL-290M**: CC-BY-**NC**-4.0 — excluded.

# Argmax: free vs. paid, and what Biscotti gets free today

Research date: 2026-10-21. All sources fetched in this session.

## 1. Free tier (Argmax Open-Source SDK, `argmax-oss-swift`)

- **License:** MIT. Pricing page: "Basic Plan — Free — Open-source (MIT License) — WhisperKit, SpeakerKit, TTSKit". Pro is "$1.33/device/month" (monthly) or "$1.00/device/month" (yearly) with a "1,000 monthly licenses minimum" ([Argmax pricing](https://www.argmaxinc.com/pricing), fetched 2026-10-21). The Pro minimum makes Pro about $1,000+/month — not possible for a free app.
- **STT models in the free tier: OpenAI Whisper only.** The README says the OSS SDK is "WhisperKit for speech-to-text with OpenAI Whisper" ([argmax-oss-swift README](https://github.com/argmaxinc/argmax-oss-swift)). The model repo `argmaxinc/whisperkit-coreml` contains only Whisper and distil-whisper folders (tiny → large-v3, large-v3-turbo, distil-large-v3, each with compressed variants) — listed via the HF API this session.
- **Free features** (Argmax's own matrix, [Open-source vs Pro SDK](https://app.argmaxinc.com/docs/wiki/open-source-vs-pro-sdk)):

  | Feature | OSS | Pro |
  |---|---|---|
  | File transcription | yes | yes ("~9x faster") |
  | Language detection | yes | yes |
  | Word timestamps | yes | yes |
  | Custom vocabulary | **no** | yes ("3000 keyword allowance") |
  | Real-time transcription | **no** | yes |
  | Speaker diarization (file) | yes | yes |
  | Real-time speaker diarization | **no** | yes |
  | File transcription with speakers | yes | yes |

- **Recent free-tier releases:** v1.0.0 (2026-05-01) renamed WhisperKit → Argmax OSS; v1.1.0 (2026-08-06) added `.incremental` audio loading ("70%+ savings for 3-hour audio input") and public SpeakerKit `speakerCentroidEmbeddings`; v1.1.1 (2026-10-08) is a bug-fix release that "Test on macOS 27, drop macOS 14" ([releases](https://github.com/argmaxinc/argmax-oss-swift/releases)). SpeakerKit (pyannote 4 community-1) was open-sourced in v0.17.0 (2026-03-13) because Pro moved to Sortformer ([v0.17.0](https://github.com/argmaxinc/WhisperKit/releases/tag/v0.17.0)).

## 2. Paid tier (Argmax Pro SDK) — what is behind the paywall

| Pro-only item | Date | Source |
|---|---|---|
| **NVIDIA Parakeet v2** (English) — "significantly surpass Whisper Large V3 on speed, accuracy and compactness"; compressed 1.2 GB → 0.4 GB | 2025-06-19 | [Argmax blog](https://www.argmaxinc.com/blog/nvidia-frontier-speech-models-on-argmax-sdk) |
| **NVIDIA Parakeet v3** (multilingual) | update to same post | same |
| Parakeet weights in `argmaxinc/parakeetkit-pro`: "These models are only compatible with Argmax Pro SDK" | — | [HF parakeetkit-pro](https://huggingface.co/argmaxinc/parakeetkit-pro) |
| Real-time transcription with speakers, custom vocabulary (Pro SDK 2, Sortformer diarization) | 2026-04-07 | [Pro SDK 2](https://www.argmaxinc.com/blog/argmax-sdk-2) |
| **Qwen3-ASR** ("market-leading speech-to-text accuracy across 30 languages", with word timestamps, custom vocabulary, code-switching) and **NVIDIA Nemotron 3 Diarization** (up to 8 speakers). "NVIDIA Parakeet remains the fastest model in Argmax SDK with the second highest accuracy after Qwen3-ASR." | 2026-09-23 | [Pro SDK 3](https://www.argmaxinc.com/blog/argmax-sdk-3) |
| Forced-alignment-quality word timestamps — the repo's prior research quotes Argmax: "You lose word-level forced alignment in the open-source path." | — | `specs/research/argmax/README.md` (prior research; not re-fetched) |

**Important distinction:** what is paywalled is **Argmax's Core ML implementation** of these models, not the models themselves. Parakeet TDT 0.6B v2/v3 are CC-BY-4.0 and Qwen3-ASR is Apache-2.0 on Hugging Face (see [licenses.md](./licenses.md)). Any free library that runs them (FluidAudio, sherpa-onnx, MLX ports, etc. — other subtopics) avoids the paywall.

## 3. What Biscotti uses free today — and a naming correction

`Packages/Transcription/Sources/Transcription/MethodResolver.swift` pins `openai_whisper-large-v3-v20240930_626MB` from `argmaxinc/whisperkit-coreml`.

**This model is OpenAI Whisper large-v3-turbo, compressed — not "non-turbo large-v3".**
- The upstream README model table labels `large-v3-v20240930_626MB` as "Large v3 Turbo (compressed) — Recommended across iOS and macOS for maximum accuracy" ([README](https://github.com/argmaxinc/argmax-oss-swift)).
- The model's `config.json` in `whisperkit-coreml` has `"decoder_layers": 4`, `"encoder_layers": 32` (fetched this session). 4 decoder layers is the OpenAI large-v3-turbo architecture ("the number of decoding layers have reduced from 32 to 4" — [openai/whisper-large-v3-turbo card](https://huggingface.co/openai/whisper-large-v3-turbo)).
- Conversely, WhisperKit's `openai_whisper-large-v3_turbo` folder has `"decoder_layers": 32` and `_name_or_path: openai/whisper-large-v3` — the WhisperKit `_turbo` **suffix** is an Argmax-side optimization of full large-v3, **not** OpenAI's turbo model.

`specs/research/argmax/README.md` gets both of these wrong (it calls the V1 model "Non-turbo large-v3" and attributes "809M params" to `openai_whisper-large-v3_turbo`). That doc should be corrected.

## 4. How good is the free option?

### Argmax's own WhisperKit benchmark (Oct 2024 run, on-device Core ML)

From `dashboard_data/quality_data.json` in the [whisperkit-benchmarks space](https://huggingface.co/spaces/argmaxinc/whisperkit-benchmarks) (fetched raw this session):

| WhisperKit model | LibriSpeech WER | Earnings22 (12 h, long-form) WER | QoI |
|---|---|---|---|
| `openai/whisper-large-v3-v20240930` (turbo, full) | 1.93 | 11.55 | 0.94 |
| `openai/whisper-large-v3-v20240930/626MB` (**ours**) | 1.96 | 12.35 | 0.93 |
| `openai/whisper-large-v3-v20240930/547MB` | 2.16 | 31.49 | 0.92 |
| `openai/whisper-large-v3` (full) | 2.02 | 11.69 | 0.95 |
| `distil-whisper/distil-large-v3` | 2.38 | 12.02 | 0.90 |

So the 626 MB compression costs about +0.8 WER points on long-form earnings calls vs. the uncompressed turbo; the 547 MB variant collapses on long-form.

### Reference (PyTorch, GPU) numbers for the base model — HF Open ASR Leaderboard, 2026-10-21

`openai/whisper-large-v3-turbo` (MIT, 0.8B): AMI-Cleaned **13.88**, Earnings22-Cleaned **8.09**, Gigaspeech 8.47, LS-clean 2.13, LS-other 3.71, SPGI 2.79, Voice Arena Monsoon 4.77, VoxPopuli 7.02; mean of 8 public sets **6.36**. Long-form tab: earnings21 9.84, earnings22 13.10 (details and comparison in [model-landscape.md](./model-landscape.md)).

**Reading:** the free model is solid on clean/long-form read speech, but it is weak on **AMI (meeting audio)** — 13.9 % vs. ~7–9.4 % for current open models. AMI is the benchmark closest to Biscotti's use case. The leaderboard's WER is measured on the uncompressed model; our 626 MB Core ML variant is somewhat worse (above).

### Known free-tier behavior problems (from the repo's prior hardware validation)

- Segment-level `confidence` is unpopulated (0) in free SDK v1.0.0; word `probability` is the usable signal.
- Whisper emits trailing hallucinated segments past the end of audio.
- `promptTokens` (the free custom-vocab workaround) can blank the whole transcript ([argmax-oss-swift#489](https://github.com/argmaxinc/argmax-oss-swift/issues/489)).

Source: `specs/research/argmax/README.md` (repo, prior validation — not re-verified here).

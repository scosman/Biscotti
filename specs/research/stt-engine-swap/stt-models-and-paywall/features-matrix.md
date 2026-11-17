# Cross-cutting features: timestamps, confidence, punctuation, language, long-form

Research date: 2026-10-21. These are the properties that decide whether a model can feed SpeakerKit word↔speaker alignment and the app's transcript contract (the contract itself is the "App contract" subtopic).

## 1. Feature matrix (model level, from model cards)

| Model | P&C | Word timestamps | Confidence | Language ID | Single-pass long-form | License |
|---|---|---|---|---|---|---|
| Whisper large-v3-turbo (today) | yes | inferred after decoding (cross-attn DTW) | token log-probs | auto, 99 langs, reports label | 30 s window; needs seq/chunked decode | MIT |
| Parakeet TDT 0.6B v2 | yes | **native** (TDT durations), word/segment/char | NeMo decode-time, 0–1 | English only | 24 min full-attn; longer needs local-attn/chunks | CC-BY-4.0 |
| Parakeet TDT 0.6B v3 | yes | **native**, same as v2 | NeMo decode-time, 0–1 | auto, 25 EU langs; label output **not stated** | 24 min full-attn; 3 h local-attn | CC-BY-4.0 |
| parakeet-unified-en-0.6b | yes | not stated (RNNT) | NeMo decode-time (presumed) | English only | not stated | NVIDIA Open Model Lic. |
| Canary-1b-v2 | yes | native word/segment | not stated | language passed in (`source_lang`) | not stated | CC-BY-4.0 |
| Canary-Qwen-2.5B | yes | none documented | not stated | English only | trained ≤40 s; chunk | CC-BY-4.0 |
| Qwen3-ASR 1.7B / 0.6B | yes | **separate** Qwen3-ForcedAligner-0.6B, ≤5 min per call, 11 langs | not documented | auto, 52 langs/dialects | "supports long audio" (no limit stated) | Apache-2.0 |
| Granite Speech 5.0 2B / 4.1 2B | yes (prompted) | none (base); LLM `[T:N]` tags in 4.1-2b-**plus**, ≤3.5 min | not documented | language prompted | ~2 min segments recommended | Apache-2.0 |
| Granite 5.0 470M TurboCTC | yes (native) | not documented (CTC alignment possible) | not documented | 7 langs; ID not stated | not stated | Apache-2.0 (`-nc` sibling is NC) |
| Cohere Transcribe 03-2026 | yes | **no** ("does not feature") | not documented | **no** auto-detect | auto-chunked | Apache-2.0 (gated) |
| Kyutai STT 2.6B / 1B | yes | native (frame offset − delay) | not stated | en / en+fr | "as long as 2 hours" | CC-BY-4.0 |
| Moonshine Streaming Medium | (not stated) | not documented | not stated | English | streaming | MIT |
| Voxtral Mini 3B / Realtime 4B | yes | none open (API batch model has them) | not stated | auto (3B) | 30 min (3B) | Apache-2.0 |

Sources: model cards linked in [model-landscape.md](./model-landscape.md).

## 2. Word-timestamp quality — measured, independent sources

Word timing accuracy matters most for SpeakerKit `.subsegment` alignment, because it assigns words to speaker turns by time.

### FA-Bench (arXiv 2609.32396, 2026-10-08)
[FA-Bench](https://arxiv.org/html/2609.32396v2) Track 2 ("the ASR times its own words"), word-boundary MAE in ms (lower is better) and boundary F1 at 20 ms tolerance:

| System | TIMIT clean MAE | TIMIT noisy MAE | Buckeye (conversational) clean MAE | Buckeye noisy MAE | F1@20 (Buckeye clean) | Timestamp grid |
|---|---|---|---|---|---|---|
| Whisper large-v3 | 148.0 | 151.8 | 122.7 | 123.0 | .14 | 20 ms |
| Whisper-timestamped | 161.6 | 163.9 | 133.3 | 136.0 | .17 | 20 ms |
| **Parakeet-TDT** | **79.3** | **77.1** | **80.7** | **80.5** | .19 | 80 ms |
| Qwen3-ASR → Qwen3-ForcedAligner | 32.6 | 38.3 | 30.6 | 41.7 | .39 | 80 ms |

The abstract says: "systematic bias in how current systems time words, with Whisper about 150 ms early". Parakeet's native timestamps have about half Whisper's boundary error. A dedicated forced aligner (Qwen3-FA, or MFA/CTC aligners) is better again. Parakeet's 80 ms grid limits fine precision, but 80 ms is small compared with speaker-turn granularity. (Values from a WebFetch extraction of Table 1. Parakeet's near-zero signed bias was reported by the extractor but I did not confirm it in the paper text — treat it as unverified.)

### AMI far-field meeting onsets (TranscribeNext, measured 2026-09-24)
[TranscribeNext](https://transcribenext.com/transcription-with-timestamps): 2 AMI SDM meetings, 69 min, 1373 human-annotated utterance onsets (vendor blog, small sample):
- Parakeet-TDT-0.6b-v3 **word-level** onset: median **130 ms**, 77.6 % within 250 ms, 88.3 % within 500 ms.
- Parakeet v3 segment-level: median 250 ms. Whisper large-v3-turbo segment-level: median 460 ms (their Whisper server returned no word stamps).

### Engine disagreement (kekoso.app, 2026-09-06)
[kekoso](https://kekoso.app/blog/transcription-timestamp-accuracy/): one 26 s synthetic clip, whisper.cpp large-v3-turbo vs Parakeet TDT v3. Median word-start disagreement 130 ms. Whisper is earlier by about 110 ms systematically. "Whisper produced ten words shorter than 60 ms, including 'That' with a duration of exactly zero". Parakeet had no words under 80 ms. This is an anecdote (n = 41 words), but it agrees with FA-Bench's direction.

**Conclusion:** moving from Whisper (DTW-inferred) to Parakeet (TDT-native) should **improve** word↔speaker alignment, not degrade it. LLM-style models (Qwen3-ASR, Granite, Canary-Qwen, Cohere, Voxtral) either have no timestamps or need a second aligner model. That adds a model download, compute, and a ≤5-min (Qwen) or ≤3.5-min (Granite-plus) windowing constraint.

## 3. Confidence scores

- **Whisper/WhisperKit:** per-word `probability` (from token log-probs). Segment `confidence` came back 0 in free SDK v1.0.0 (repo validation).
- **NeMo transducers (Parakeet TDT/RNNT) and CTC:** NeMo "supports per-frame, per-token, and per-word confidence scores during decoding". Methods are `max_prob` or `entropy` (default Tsallis, α = 0.33), aggregated by mean/min/max/prod. For TDT, `tdt_include_duration_confidence` is available ([NeMo docs](https://docs.nvidia.com/nemo/speech/latest/asr/asr_language_modeling_and_customization.html)). The NeMo tutorial: "It lies in range from 0 to 1" ([tutorial](https://github.com/NVIDIA/NeMo/blob/main/tutorials/asr/ASR_Confidence_Estimation.ipynb)). Confidence comes from the **decoder implementation**, not the weights, so a non-NeMo runtime (Core ML/ONNX) exposes whatever it chooses to compute. Its range/semantics may differ from Whisper's probability (runtime subtopics own this).
- **LLM-style ASR (Qwen3-ASR, Granite, Canary-Qwen, Voxtral, Cohere):** no confidence is documented. Token log-probs are available in principle from the generation loop.

## 4. Punctuation & capitalization

All shortlisted candidates (Parakeet v2/v3/unified, Canary, Qwen3-ASR, Granite, Cohere, Kyutai, Whisper) output P&C natively. Leaderboard WERs strip P&C, so **P&C quality is not compared** by any benchmark I found except IBM's self-reported PER/Cap-F1 for Granite. This is a gap. Biscotti's LLM summarization is somewhat tolerant of P&C errors, but the transcript UI is not.

Specific point: Parakeet **v3** punctuates per its card ("Punctuations and Capitalizations included"). The `fluid_audio_engine` draft's claim that v3 is "no punctuation" (attributed to FluidAudio docs) disagrees with NVIDIA's card. Any loss would come from a conversion/runtime, not the model.

## 5. Long-form (1-hour meetings)

- **Whisper:** 30 s window. Hour-long input is handled by sequential/VAD chunking (WhisperKit `.incremental` mode in v1.1.0). Long-form hallucination is the main risk.
- **Parakeet TDT:** a 24 min single pass needs a lot of memory (NVIDIA quotes A100 80 GB). Local attention allows 3 h. On-device runtimes typically chunk with overlap (runtime subtopics).
- **Qwen3-ASR:** long audio is supported, but timestamps need ≤5-min aligner windows.
- **Granite:** about 2-min segments recommended. Cohere: auto-chunked. Kyutai: up to 2 h streaming.
- **Long-form WER evidence:** only the HF long-form tab (earnings21/22, CORAAL), where Parakeet v3 ≈ Whisper turbo. **No public long-form *meeting* (multi-speaker, far-field, 1 h) benchmark** across these models was found. AMI short-form segments are the best proxy.

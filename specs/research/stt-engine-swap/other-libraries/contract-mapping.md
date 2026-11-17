# Mapping each library's output to the app contract

The contract is [`Packages/Transcription/Sources/Transcription/TranscriptResult.swift`](../../../../Packages/Transcription/Sources/Transcription/TranscriptResult.swift):
- `TranscriptWord { word, startTime, endTime, probability (0–1), speakerID? }`
- `TranscriptSegment { speakerID?, speakerLabel, startTime, endTime, text, confidence (avg log-prob), noSpeechProbability, words? }`
- `TranscriptResult { transcriptionMethodId, language, speakerCount, segments, speakerEmbeddings, processingDuration }`

Today segments are built from SpeakerKit's `[[SpeakerSegment]]` output (`SegmentBuilder.buildSegments(from:)`), after SpeakerKit merges WhisperKit words with its speaker timeline. `speakerID`, `speakerLabel`, `speakerCount` and `speakerEmbeddings` come from SpeakerKit, not the STT engine. Whether SpeakerKit accepts non-WhisperKit words is the "App contract & SpeakerKit decoupling" subtopic. Here I only ask what each STT engine can give us to feed that step.

**What any engine must supply:** word text, word start/end (seconds), and a per-word probability. Everything else is either SpeakerKit's job or a field with no Parakeet equivalent (see the last section).

## Comparison table

| Library | Models we would use | Word timing | Granularity / source | Per-word confidence | Segments | Language out | Long audio (1 h) | Swift path | Accel on Mac |
|---|---|---|---|---|---|---|---|---|---|
| whisper.cpp **Parakeet** (≥ v1.9.4) | Parakeet TDT 0.6B v3 (v2 converts) | Yes | sub-word token `t0/t1` in 10 ms units + `is_word_start` | token `p` (min/mean over tokens) | one segment for the whole file | No | single dynamic-graph pass, local attention > 10.9 min | official xcframework → `binaryTarget` (same as our llama.swift) | Metal (no ANE) |
| whisper.cpp **Whisper** | large-v3-turbo etc. | Yes | token `t0/t1` (heuristic) or `t_dtw` (DTW, off when flash-attn on) | token `p` | yes (30 s windows; `max_len`/`split_on_word`) | Yes (`whisper_full_lang_id`) | yes (sliding windows, VAD option) | same xcframework | Metal + Core ML encoder |
| NeMo-Speech.cpp (NVIDIA) | Parakeet TDT 0.6B v3, Nemotron 3.5, Parakeet CTC 1.1B (+PnC) | Yes | **word** start/end in ms | **per word** float + per result | none in C ABI | Yes (Nemotron 3.5) | splits at quiet points internally | dylibs + C header, wrap ourselves | Metal |
| parakeet.cpp (mudler) | TDT v2/v3/1.1B, CTC/RNNT, Nemotron 3.5, Ultra | Yes | **word** start/end (s) + token `t` | **per word** (`min` over tokens, `(0,1]`) | none | Nemotron `--lang auto` (output not verified) | single pass OK past 11 min; optional VAD | dylibs + C header, wrap ourselves | Metal |
| sherpa-onnx | Parakeet TDT v2/v3 int8, unified-en, many others | Yes | sub-word token timestamp + duration (s) | token `ys_log_probs` (C struct only, not the Swift wrapper) | none for Parakeet | No (SenseVoice only) | needs VAD chunking in our glue | **official SwiftPM** (static/shared xcframework + onnxruntime) | CPU (CoreML EP weak) |
| mlx-audio-swift | Parakeet TDT v2/v3/1.1B, many others | **Not via public API** | sentence `[[String: Any]]` text/start/end only | No | sentences | echoes request | 20 min chunks, 2 s overlap | SwiftPM, `branch: main`, mlx-swift | Metal GPU (metallib build issue) |
| speech-swift `ParakeetASR` | Parakeet TDT v3 INT8 Core ML | Yes | word start/end (s), **emission-aligned, ignores TDT duration** | overall sigmoid-scaled score (per-word struct named `WordConfidence`; exact per-word value not verified) | no | No | 30 s windows | SwiftPM, `branch: main`, heavy dep graph | ANE / GPU |
| parakeet-coreml-swift | Parakeet TDT v3 Core ML | Partial | token `frameIndices` + `durations` (80 ms frames) | No | No | No | yes (17.5 min tested) | SwiftPM, tiny | ANE / GPU |

Sources: see each deep doc ([whisper-cpp.md](./whisper-cpp.md), [nvidia-nemo-speech-cpp-and-riva.md](./nvidia-nemo-speech-cpp-and-riva.md), [parakeet-cpp.md](./parakeet-cpp.md), [sherpa-onnx.md](./sherpa-onnx.md), [mlx-ports.md](./mlx-ports.md), [other-swift-ports.md](./other-swift-ports.md)).

## Per-library mapping and glue

### whisper.cpp Parakeet path

- `TranscriptWord.word`: concatenate `parakeet_token_to_str` pieces from an `is_word_start=true` token up to the next one. Strip the `▁` marker. Attach punctuation tokens (zero-duration, pinned to the previous token end) to the previous word, which is how the original token stream already reads ("Americans" then ",").
- `startTime`/`endTime`: first token `t0` and last non-punctuation token `t1`, each `× 0.01` s.
- `probability`: aggregate the tokens' `p`. Use `min` to match NeMo / parakeet.cpp semantics, or the mean. This is our choice, so document it in `transcriptionMethodId`.
- `TranscriptSegment`: built downstream (SpeakerKit plus `SegmentBuilder`). The engine returns one big segment.
- `language`: not emitted. Use the configured language or a constant `"en"`.
- Glue size: small. One C-API actor, a token→word folder, audio decode and resample to 16 kHz mono float (`PARAKEET_SAMPLE_RATE 16000`). I did not check whether our existing pipeline already produces that.

### whisper.cpp Whisper path

Maps almost 1:1 to today's fields (segment `no_speech_prob`, token `p`, `lang_id`), because the contract was shaped by Whisper. But it gives no model upgrade over free WhisperKit, so it is useful only as a fallback engine if WhisperKit itself had to go.

### NeMo-Speech.cpp

- `word`/`startTime`/`endTime`/`probability`: direct from `nemo_speech_asr_result_word_text/start_time/end_time/word_confidence` (ms → s). Confirm the confidence scale empirically.
- `language`: `nemo_speech_asr_result_language_code` with Nemotron 3.5. Parakeet TDT returns none (not verified).
- Glue: wrap ~12 dylibs into an XCFramework (or embed them), write a Swift shim over a clean C ABI. Medium.

### parakeet.cpp

- Parse the JSON `words[] {w, start, end, conf}` directly into `TranscriptWord`. `conf` is already 0–1.
- In-memory PCM JSON goes through `parakeet_capi_transcribe_pcm_batch_json` with one item, or a temp WAV file via `_path_json`.
- Glue: same packaging work as NeMo-Speech.cpp, plus JSON decoding. Medium.

### sherpa-onnx

- Build words from `tokens`/`timestamps`/`durations` like the whisper.cpp Parakeet path. Use `end = timestamp + duration` of the last token.
- `probability = exp(ys_log_probs[i])` read via `result.pointee.ys_log_probs`.
- Our own Silero-VAD segmentation loop for 1-hour files, re-offsetting timestamps by segment start.
- Glue: medium (VAD loop plus word folding). Packaging is easy (official SPM).

### mlx-audio-swift, speech-swift, parakeet-coreml-swift

- mlx-audio-swift: needs a fork to expose tokens. No confidence. Plus the metallib build step for `swift test`.
- speech-swift: words available, but word end times ignore TDT durations ("`endTime` is one frame after the last token's start"). That hurts word↔speaker alignment at turn boundaries. Branch-only dependency with a heavy manifest.
- parakeet-coreml-swift: token frames plus durations only, no confidence, abandoned after one day.

## Fields with no Parakeet equivalent (applies to all Parakeet runtimes)

- `TranscriptSegment.confidence` (Whisper avg log-prob; already noted in the source as "unreliable (often 0)"): compute from word probabilities (for example, the mean log of word `p`), or set 0. The contract subtopic decides whether anything consumes it.
- `TranscriptSegment.noSpeechProbability`: TDT has no no-speech head. Set 0, or derive it from VAD if a VAD is used. Parakeet Ultra/Redux carry a VAD head, but the parakeet.cpp docs warn it "gives false alarms on audio without speech".
- `TranscriptResult.language`: Parakeet v3 auto-handles 25 languages but reports none. Nemotron 3.5 (NeMo-Speech.cpp, parakeet.cpp) does report language.
- `transcriptionMethodId`: a new value per engine+model, so re-transcribe knows what produced old results.

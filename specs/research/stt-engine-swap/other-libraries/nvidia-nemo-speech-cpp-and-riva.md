# NVIDIA on-device options: NeMo-Speech.cpp (new, official) and Riva (not applicable)

Researched 2026-10-21.

## NeMo-Speech.cpp — NVIDIA's official ggml runtime (2026 entrant)

- Repo: [NVIDIA/NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp), Apache-2.0, created 2026-07-15, 195 stars, last push 2026-10-20. Releases: v0.1.0 (2026-08-19), **v0.2.0 (2026-10-02)**, plus a daily `nightly` ([releases API](https://api.github.com/repos/NVIDIA/NeMo-Speech.cpp/releases)).
- Self-description: "**NeMo-Speech.cpp is NVIDIA's official solution for local speech inference**, providing day-0 support for the latest models from NVIDIA NeMo Speech, with native inference powered by ggml" ([README](https://github.com/NVIDIA/NeMo-Speech.cpp)).

### Models (ASR)

From [docs/asr/models.md](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/asr/models.md):
- **Nemotron 3.5 ASR Streaming 0.6B**: "cache-aware FastConformer-RNNT with language-ID prompt conditioning across 40+ language-locales". Has `--language auto` model-based detection: "Structured results include the selected or detected language". The default model. License: OpenMDW-1.1 (HF card `license_name: openmdw-1.1`, from the [HF API](https://huggingface.co/api/models/nvidia/nemotron-3.5-asr-streaming-0.6b)). The license review belongs to the model-landscape subtopic.
- **Nemotron-Speech Streaming 0.6B (en)**: NVIDIA Open Model License.
- **Parakeet TDT 0.6B v3**: "25 European languages, self-punctuating ... The model does not support cache-aware streaming; inference is full-utterance only."
- **Parakeet CTC 1.1B**: English, lowercase/unpunctuated. Needs the optional PnC (punctuation and capitalization) companion model.
- Custom NeMo checkpoints go through `convert_model.py`, which auto-detects the CTC/RNNT/TDT head. So Parakeet TDT 0.6B v2 would likely convert. I did not verify this.
- Also bundles Sortformer diarization (Streaming Sortformer v2, Nemotron 3 Diarization), Silero VAD, ITN/TN, NMT, TTS. These are not needed (we keep SpeakerKit).

### Output shape — stable C ABI ([`include/nemo_speech/asr.h`](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/include/nemo_speech/asr.h))

The header says "Names and behavior mirror Riva ASR (Recognize / StreamingRecognize / word time offsets / finals / force_eou)". Offline call: `nemo_speech_asr_recognize_f32(recognizer, &options, samples, n, sample_rate, &result)`. It takes mono float32 at 8–96 kHz and resamples internally. Options include `language_code`, `enable_word_time_offsets`, `enable_automatic_punctuation`, `verbatim_transcripts`, `speech_contexts` (phrase boosting), `max_alternatives`, `enable_speaker_diarization`.

Result accessors:
```c
const char* nemo_speech_asr_result_transcript(const nemo_speech_asr_result*, size_t alt);
float       nemo_speech_asr_result_confidence(const nemo_speech_asr_result*, size_t alt);
size_t      nemo_speech_asr_result_word_count(const nemo_speech_asr_result*, size_t alt);
const char* nemo_speech_asr_result_word_text(const nemo_speech_asr_result*, size_t alt, size_t i);
int32_t     nemo_speech_asr_result_word_start_time(const nemo_speech_asr_result*, size_t alt, size_t i);
int32_t     nemo_speech_asr_result_word_end_time(const nemo_speech_asr_result*, size_t alt, size_t i);
float       nemo_speech_asr_result_word_confidence(const nemo_speech_asr_result*, size_t alt, size_t i);
int32_t     nemo_speech_asr_result_word_speaker_tag(...);   // 1-based; 0 = untagged
size_t      nemo_speech_asr_result_language_count(...);
const char* nemo_speech_asr_result_language_code(..., size_t i);
```
- **Word-level** (not sub-word) start/end times, in **milliseconds**. The example prints "per-word start/end offsets (ms)" ([examples/transcribe_file.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/examples/transcribe_file.cpp)).
- Per-word confidence plus per-result confidence. The header does not define the scale. I did not check the source for the definition.
- "Today alternative_count is always 1 (greedy heads emit one hypothesis; beam N-best is wired but not yet implemented)".
- No segment/sentence structure in the C ABI beyond result boundaries. The CLI builds subtitle cues ("prefer sentence, clause, and pause boundaries"), but that is CLI-side ([docs/cli.md](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/cli.md)).

### Long audio

`Recognizer::recognize` in [src/asr/recognizer.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/src/asr/recognizer.cpp) checks `exceeds_offline_position_limit` (encoder frames > `pos_emb_max_len`). For offline-only TDT it uses `OfflineRunner`, with the comment: "Past the positional-encoding limit OfflineRunner splits the audio at quiet points and decodes segment by segment." So 1-hour input is handled inside the library by silence-split segmentation. I did not measure the accuracy at the split points.

### Swift / Apple integration

- Release archives for macOS: `nemo-speech-0.2.0-macos-aarch64-metal.tar.gz` (5 MB). I downloaded and inspected it. It holds `include/nemo_speech/{asr,diar,nmt,tts}.h`, the CMake package, and ~12 `@rpath` dylibs: `libnemo_speech_asr_c.1.dylib`, `libnemo_speech_asr.dylib`, `libnemo_speech_text_normalization.dylib`, `libggml{,-base,-cpu,-blas,-metal}.0.dylib`, `libllama.0.dylib`, and others. SentencePiece is linked statically (no external dependency in `otool -L`). `LC_BUILD_VERSION minos 13.3`.
- **No Swift package, no xcframework.** Integration means wrapping the dylibs into one or more XCFrameworks (or embedding the dylibs in the XPC bundle's `Frameworks/` with an rpath), plus a Swift shim over the C ABI. This is more glue than whisper.cpp's ready xcframework, but the C ABI is clean: append-only size-prefixed structs, "no exceptions, no STL", thread-local last error ([docs/sdk.md](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/sdk.md)).
- The SDK docs say: "Models and companion assets are not embedded in the SDK. The application owns their storage and passes local paths". This gives full download/caching control. (The CLI has its own downloader with SHA-256 pinning into `~/Library/Caches/NeMoSpeech/models`, overridable by `NEMO_SPEECH_MODEL_DIR`.)
- Metal backend: "Metal builds require macOS on Apple Silicon". **No Apple performance numbers** in [BENCHMARK.md](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/BENCHMARK.md) (RTX 4090 and generic CPU only). v0.2.0 fixed "MagpieTTS no longer returns silence on M5-class Macs" (#20). Apple is supported but not the focus.
- Bundles its own `libllama`/`libggml`. The same "never two ggml copies in one process" caution applies as for whisper.cpp.
- Hardened runtime: nothing suggests a need for JIT or other special entitlements. Plain dylibs plus embedded Metal. I did not verify this on a notarized build.

### Maturity

Three months old, v0.2.0, 195 stars, but NVIDIA-staffed with a clear ABI-stability policy ("Breaking changes require a new SONAME / v2 symbols"). It is likely to get new NVIDIA models first ("day-0 support"). The Apple path is secondary. Medium maturity risk.

## NVIDIA Riva — not an option

The [Riva support matrix](https://docs.nvidia.com/deeplearning/riva/user-guide/docs/support-matrix/support-matrix.html) lists only Linux data-center GPUs and Jetson (2.26.0: "Riva server requires L4T aarch64", Jetson Thor). It never mentions macOS or Apple. Self-hosted Riva / Riva ASR NIM is licensed under NVIDIA AI Enterprise ([Riva get-started](https://www.nvidia.com/en-us/ai-data-science/products/riva/get-started/)). Dead end for a free macOS app. NeMo-Speech.cpp is NVIDIA's local/on-device answer, and its C ABI deliberately mirrors Riva's.

## NeMo (Python) itself

Not embeddable in a hardened-runtime XPC service without shipping a Python + PyTorch runtime. I did not consider it further.

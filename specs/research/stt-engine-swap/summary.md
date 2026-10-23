# Research: Swap WhisperKit STT, Keep SpeakerKit

Researched 2026-10-21. Six subtopics; none failed.

## Bottom Line

**Yes, we can replace WhisperKit STT and keep SpeakerKit.** The swap is clean. Nothing above `Packages/Transcription` uses an Argmax type. SpeakerKit diarizes raw audio with no transcript. Its alignment call (`addSpeakerInfo`) takes WhisperKit types that have public inits, so we can wrap another engine's word timings in about 30 lines and keep today's alignment and `SegmentBuilder` unchanged. The WhisperKit *module* stays linked, because SpeakerKit's SPM target depends on it. We drop only the Whisper models and the Whisper runtime.

**The model to move to is NVIDIA Parakeet TDT 0.6B** (v2 for English; v3 or its `ultra` derivative for 25 European languages). Parakeet is CC-BY-4.0, so a free runtime can use it. Argmax paywalls its Core ML *build* of Parakeet, not the model. On meeting-style audio (AMI) Parakeet has 9.1–9.4% WER. Our current free model has 13.9%. Parakeet also gives native punctuation, casing and word timestamps that are more accurate than Whisper's.

**Recommended engine: FluidAudio** (Core ML on the Neural Engine, pure SPM, static linking, used by many shipping Mac apps). **Fallback: whisper.cpp ≥ v1.9.4**, which now runs Parakeet and fits the xcframework pattern we already ship for llama.cpp.

**Do not do the split strategy now.** Apple's `SpeechTranscriber` works for batch use in our setup, but its quality is about equal to today's Whisper, not better. It is worse than Parakeet, and much worse in noise. It also adds a second engine, and its assets still download once.

> **Update 2026-10-23 (measured on our meetings):** the STTLab run on 16 real meetings (13.4 h) confirms WER is close (Apple 9.9 %, Whisper 9.3 %), but Apple makes about 2.2x as many mistakes that matter, almost all of them technical terms. Apple is about 4x faster and uses far less memory, and its word timings work with SpeakerKit. See `specs/projects/apple_stt_validation/results/overview.md`.

**Gate the final decision on a hardware A/B with our own recordings.** Nobody has measured 1-hour real-meeting WER or energy for any candidate. FluidAudio's own 1-hour number is a warning sign (see Conflicts).

## Engine Comparison

Quality numbers are WER (lower is better). "AMI" is short meeting clips. "Long" is 1-hour or earnings-call audio. Model-level WERs come from the original PyTorch weights; ports can lose accuracy.

| Engine | Model(s) | Quality | Speed (1 h audio) | Compute | Output fit to our contract | Integration cost | Maturity | License (code / model) |
|---|---|---|---|---|---|---|---|---|
| **WhisperKit (today)** | Whisper large-v3-turbo, compressed 626 MB | AMI 13.9; Earnings-22 long 12.35 | Baseline (Apple is 2–5x faster) | Core ML / ANE | Native (the contract was shaped by it) | None | 1.x, stable | MIT / MIT |
| **FluidAudio** (v0.17.7) | Parakeet TDT v2 / v3 / ultra | Model: AMI 9.1–9.4. **FluidAudio 1-h Earnings-22: v3 16.5, ultra 13.5** (non-standard reference) | 335–457x on M5 Pro (about 10 s) | Core ML / **ANE** | One string + sub-word tokens (80 ms steps, 0–1 confidence). No segments, no language. About 100–200 lines of glue | Low–medium. SPM, no deps, static, no new dylib to sign. Links its diarizer, TTS and a Rust lib unless we move to tools-version 6.1/6.2 | 0.x, weekly releases, bus factor about 2, wide use | Apache-2.0 / CC-BY-4.0 |
| **whisper.cpp Parakeet** (≥ v1.9.4) | Parakeet TDT v3 (v2 converts) | Same model; port WER not measured | Not measured for 1 h | Metal (no ANE) | Sub-word tokens (10 ms) + probability + word-start flag. One segment. No language | **Low.** Prebuilt xcframework as `binaryTarget`, same as our llama.cpp | Mature project; Parakeet path new (June 2026); timestamp bug fixed in v1.9.4 | MIT / CC-BY-4.0 |
| **transcribe.cpp** (v0.4.0) | Parakeet v2, ultra | Not measured on meetings | 248x on a 35 s clip (M4 Max); no 1 h data | Metal / CPU | Words (no probability) + tokens (entropy confidence). Punctuation end-time drift up to 560 ms (we can fix in glue) | Medium. Dynamic framework to re-sign; no SPM | 6.5 months, 1 maintainer. **v0.4.0 cannot run 1 h of v2/v3** (fix merged, not released) | MIT / CC-BY-4.0 |
| **NeMo-Speech.cpp** (v0.2.0) | Parakeet v3, Nemotron 3.5, CTC 1.1B | Not measured on Mac | Not published | Metal | **Best shape:** words + per-word confidence + language (Nemotron) | Medium–high. Wrap about 12 dylibs ourselves | NVIDIA official, but young | Apache-2.0 / CC-BY-4.0 |
| **parakeet.cpp** (mudler) | Parakeet v2/v3, Nemotron, ultra | Claims parity with NeMo | 54x on a 7 s clip (M4) | Metal | Words + per-word confidence (JSON) | Medium. Wrap dylibs ourselves | 1 maintainer; GPU not in CI | MIT / CC-BY-4.0 |
| **sherpa-onnx** | Parakeet v2/v3 int8 | v3 frontend fix unreleased | Not measured | CPU in practice | Tokens + durations; confidence only via C struct | Low packaging (official SPM), but we write VAD chunking | Mature project | Apache-2.0 / CC-BY-4.0 |
| **Apple SpeechTranscriber** (macOS 26+) | System model | Earnings-22 12.0; AMI 14.3; **5 dB babble 31% (Parakeet 7.9%)** | 45–70x | ANE + CPU, in a system process | Per-phrase results; per-run time ranges + 0–1 confidence (sometimes missing). Group into words. No language detection | Low–medium. No model files to manage. Not yet proven in an `.xpc` | Apple; same output on 26.5 and 27 | System |

**Not viable:** MLX ports (Python cannot run in our XPC service; mlx-swift cannot build Metal shaders under `swift build`; the Swift port hides word timestamps). NVIDIA Riva (Linux/Jetson only, enterprise license). Heavier, more accurate models (Qwen3-ASR, Granite 2B, Cohere, Canary-Qwen) give no native word timestamps, so they do not suit SpeakerKit alignment.

## Key Findings

- **The real downstream contract is small.** The app reads only segment `text`, `startTime`/`endTime` and the speaker fields (from SpeakerKit). Word timings matter only *inside* the package, for word-to-speaker alignment. ([app contract](./app-contract-and-speakerkit/summary.md))
- **A new engine must supply:** word start/end in absolute seconds, word text with a leading space (SpeakerKit joins words with no separator), and punctuation plus casing (the UI and the LLM use the text verbatim). Default word probability to **1.0**, not 0, because `TranscriptSanitizer` drops low-probability trailing words. ([app contract](./app-contract-and-speakerkit/summary.md))
- **Segment `confidence` and `noSpeechProbability` were always 0 in production.** SpeakerKit's `.subsegment` path creates synthetic segments with zero values. No engine needs to supply them. No Parakeet runtime does. ([app contract](./app-contract-and-speakerkit/summary.md), [other libraries](./other-libraries/summary.md))
- **Word-timestamp accuracy limits alignment, not diarization.** SpeakerKit's timeline has about 17 ms resolution. Its split rule uses a 0.15 s word gap. Parakeet's word-boundary error is about 80 ms; Whisper's is about 123–152 ms. ([app contract](./app-contract-and-speakerkit/summary.md), [models](./stt-models-and-paywall/summary.md))
- **The Argmax paywall covers implementations, not models.** Free tier = Whisper only. Pro adds Parakeet, Qwen3-ASR, custom vocabulary, real-time and Sortformer, at $1–1.33/device/month with a 1,000-license minimum. SpeakerKit (MIT, CC-BY-4.0 models, not gated) stays free. Dropping WhisperKit changes nothing for it. ([models & paywall](./stt-models-and-paywall/summary.md))
- **Our current model is compressed Whisper large-v3-turbo**, not non-turbo large-v3 as `specs/research/argmax/README.md` says. Correct that doc. ([models & paywall](./stt-models-and-paywall/summary.md))
- **Parakeet v3 punctuates and capitalizes.** The "no punctuation" note in FluidAudio's docs (and in the `fluid_audio_engine` draft) is a doc error. NVIDIA's card, the vocab file and FluidAudio's code all confirm punctuation. ([FluidAudio](./fluidaudio/summary.md), [models](./stt-models-and-paywall/summary.md))
- **FluidAudio's ASR does not depend on its diarizer.** Its docs lag its source. The README and Getting Started calls do not compile on v0.17.7. Its model folder name differs from the draft spec's plan, and it fetches models from an unpinned HF `main` unless we pin a revision. FluidAudio now recommends `ultra` over v3. ([FluidAudio](./fluidaudio/summary.md))
- **whisper.cpp now runs Parakeet TDT** (v1.9.0, June 2026). Use v1.9.4 or later, because earlier builds had badly wrong word end times. Its Whisper path is no model upgrade. ([other libraries](./other-libraries/summary.md))
- **Apple's API is usable but is not an upgrade.** No permission prompt, punctuated output, 45–70x speed. macOS 27 gives byte-identical transcripts to 26.5. Use `SpeechTranscriber`, never `DictationTranscriber`. No diarization, no language detection, no custom vocabulary. The system can evict assets, and Apple can update the model under a fixed method id. If we ever split, macOS 26.5 is the defensible floor. ([Apple](./apple-speech-apis/summary.md))
- **Centroid embeddings need an SDK upgrade, whatever engine we pick.** The repo pins argmax-oss-swift v1.0.0. Public `speakerCentroidEmbeddings` arrived in v1.1.0. ([app contract](./app-contract-and-speakerkit/summary.md))

## Implications

- **Engine work is mostly glue.** Write a token-to-word folder, add a leading space, set probability defaults, set `language` (hard-code `"en"` for v2, or use `NLLanguageRecognizer` for v3/ultra), build WhisperKit `TranscriptionResult`/`WordTiming` values, and call `addSpeakerInfo`. All of the Parakeet runtimes need the same glue.
- **Segment size will change.** The 0.15 s split rule turns word gaps into `TranscriptSegment`s. Parakeet timings produce different gaps from Whisper DTW. Check this on hardware.
- **A new engine needs a new method id.** This marks existing transcripts stale.
- **We take on model downloads** (v3 about 480 MB, ultra about 630 MB). Pin an HF revision. FluidAudio supports a custom folder, progress, resume and offline mode.
- **Custom vocabulary:** today it uses WhisperKit `promptTokens`, which is blocked upstream anyway. FluidAudio's TDT `AsrManager` has no vocabulary boosting. Only its Unified manager does, and Unified has a stricter license.
- **Licensing is your call.** Parakeet (CC-BY-4.0) needs attribution, as SpeakerKit already does. `parakeet-unified-en` moved to the NVIDIA Open Model License. Avoid the NC-licensed Canary-1b and Granite `-nc` variants.
- **Split strategy cost/benefit:** it adds a second engine, a second set of tests and a second quality profile, but gives only "no app-managed download" on macOS 26.5+. Assets still download once, through the system. Revisit only if zero-download becomes a product goal, or if Apple's model improves.

## Conflicts and Uncertainty

- **Long-form quality may erase the Parakeet gain.** Short-clip AMI favours Parakeet strongly (9.1–9.4 vs 13.9). On the leaderboard's long-form tab, Parakeet roughly equals Whisper turbo (10.7–11.2 vs 11.0). FluidAudio's own 1-hour Earnings-22 run gives 16.5% (v3) and 13.5% (ultra). Argmax reports 12.35% on Earnings-22 for our current compressed model. These use different references, so they are not directly comparable. But FluidAudio's docs agree that long-form errors cluster at its 15 s chunk seams, which are weakest on crosstalk and soft speech — typical meeting audio. **This is the main open risk.**
- **AMI favours Parakeet** because AMI is in its training set. Apple's AMI gap (14.3 vs about 11.5) is partly this effect.
- **argmax-oss-swift version:** `Package.resolved` pins **v1.0.0**, and that is what ships. The FluidAudio subtopic read a local v1.1.0 checkout. The app-contract subtopic confirms that `addSpeakerInfo`, the 0.15 s rule and the synthetic zero-confidence segments are the same in v1.0.0 and v1.1.1, so the bridging plan holds on v1.0.0. Centroids need v1.1.0.
- **Repo docs vs source:** our argmax README is wrong about the model (turbo, not non-turbo). It is also wrong about why confidence is 0 (SpeakerKit zeroes it; the free SDK is not the cause).
- **Smaller doc/source conflicts:** transcribe.cpp's header calls token `p` a softmax probability, but its code computes entropy confidence. FluidInference's Core ML Unified model is labelled CC-BY-4.0, but upstream is now the NVIDIA Open Model License. Apple's locale list exists in 30- and 42-locale versions.
- **Moving targets:** FluidAudio ships weekly. transcribe.cpp's long-audio fix and sherpa-onnx's v3 fix are not yet released. Apple can change its model without an OS update.

## Gaps

- **No energy data for any engine.** Run `powermetrics` per engine on the same 1-hour file. Apple's work shows under a system daemon, so measure system-wide.
- **No 1-hour real-meeting WER for any candidate.** Build a small Biscotti test set (real meetings, with reference transcripts). Score WhisperKit, FluidAudio v3/ultra and Apple, and also score speaker-attribution error after SpeakerKit alignment.
- **Nothing was built, linked or run in the XPC service.** We need a spike that links FluidAudio (and, for a split, runs SpeechAnalyzer) inside `BiscottiTranscriber.xpc` under hardened runtime. It must also confirm that Apple shows no permission prompt.
- **No punctuation-quality benchmark** exists for any model. Leaderboard WER ignores punctuation.
- **Confidence calibration:** check the `TranscriptSanitizer` 0.3 threshold against Parakeet and Apple values.
- **Not measured:** peak RAM, Mac first-load (ANE compile) time, binary-size cost of keeping the WhisperKit module, and whether `Packages/Transcription` can move to tools-version 6.2 (to drop FluidAudio's unused targets).
- **No published tolerance for word-timestamp error** in alignment. The current guidance (keep errors well under 0.15 s) is inference.

## Subtopics

- [App contract & SpeakerKit decoupling](./app-contract-and-speakerkit/summary.md) — what the app consumes, and how SpeakerKit couples to WhisperKit. Headline: the swap is clean; wrap new word timings in WhisperKit types and reuse `addSpeakerInfo`.
- [STT model landscape & Argmax paywall](./stt-models-and-paywall/summary.md) — the free/paid split, the model survey and licenses. Headline: Parakeet TDT v2/v3 is the best fit; the paywall covers Argmax's builds, not the models.
- [FluidAudio deep dive](./fluidaudio/summary.md) — API, output, packaging and mapping. Headline: a workable ANE replacement with about 100–200 lines of glue; the risk is long-form seam quality and library churn.
- [Apple built-in speech APIs](./apple-speech-apis/summary.md) — SpeechTranscriber quality, speed, assets and permissions. Headline: usable and zero-config, but quality is equal to today's Whisper and below Parakeet; macOS 27 changed nothing.
- [transcribe.cpp deep dive](./transcribe-cpp/summary.md) — identity, models, output and integration. Headline: good output shape via Parakeet, but too young (one maintainer, no 1-hour support in a release).
- [Other libraries](./other-libraries/summary.md) — whisper.cpp, NeMo-Speech.cpp, parakeet.cpp, sherpa-onnx, MLX, Swift ports and Riva. Headline: whisper.cpp ≥ v1.9.4 now runs Parakeet and is the cheapest non-FluidAudio path.

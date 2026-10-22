# Apple SpeechTranscriber — Quality Benchmarks (independent)

Researched 2026-10-21. Apple publishes **no** accuracy numbers for `SpeechTranscriber` (nor did it ever for `SFSpeechRecognizer`) — [Lyonesse/Inscribe round 1](https://lyonesse.app/blog/apple-speech-api-benchmark.html): "Apple shipped SpeechAnalyzer with no accuracy numbers." Every number below is third-party. Apple's only quality claim is qualitative: the model is "good for long-form and distant audio, such as lectures, meetings, and conversations" ([WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/)).

> **Version caveat (important):** Apple's speech assets are server-delivered and update outside OS releases. "Apple's speech assets are server-provided and cannot be version-pinned, so the Apple numbers are tied to whatever asset shipped as of 2026-07-15 and may drift." ([verliapp/stt-benchmark](https://github.com/verliapp/stt-benchmark)). All good-quality Apple numbers below are from macOS 26.5.1–27.0.1, July–October 2026.

---

## 1. Summary table — Apple vs Parakeet vs Whisper (on-device, Apple Silicon)

WER %, lower is better. "Same harness" = all engines run through one harness with one normalizer, so the row is internally comparable. Do **not** compare numbers across rows from different sources.

| Source (date, HW, OS) | Dataset | Apple SpeechTranscriber | Parakeet TDT v2 | Parakeet TDT v3 | Whisper large-v3-turbo | Whisper large-v3 | Notes |
|---|---|---|---|---|---|---|---|
| [verliapp/stt-benchmark](https://github.com/verliapp/stt-benchmark) (2026-07-15, M4 Pro, macOS 26.5.1) | LibriSpeech test-clean | **1.82** (1.66–1.99) | 1.69 | 2.15 | 1.93 (WhisperKit) | 1.82 (WhisperKit) | Top four are a statistical tie ("Treat the top as a tie, not a ranking"). LibriSpeech is in Parakeet's training data. |
| same | **Earnings-22** (out-of-domain for all; "the fairest test") | **12.03** (11.52–12.56) | 11.23 | 11.20 | 12.35 (WhisperKit) | ref. PyTorch ≈11.1 | Paired bootstrap: Apple 0.5–1.2 pp **behind** both Parakeets; level with on-device Whisper turbo. |
| same | **AMI** (short clips, ESB bundle) | **14.32** (13.96–14.69) | 11.58 | 11.43 | 21.68† | leaderboard ≈14.9 | AMI is in Parakeet's training set (home advantage). †Whisper AMI number is a clip-level hallucination artefact, not real accuracy. |
| [Lyonesse round 2](https://lyonesse.app/blog/parakeet-moss-apple-speech-benchmark.html) (2026-07-15, M2 Pro, macOS 26.5.1) | LibriSpeech clean / other | **2.12 / 4.56** | 2.01 / 3.40 (FluidAudio int8 CoreML) | 2.51 / 4.28 (FluidAudio int8 CoreML) | — | — | Whisper Small 3.74 / 7.95. "Noisy speech is where they separate." |
| [Yap (yapapp.cc) speed/accuracy](https://yapapp.cc/questions/fastest-on-device-speech-recognition-mac) (Oct 2026, M2 Pro) | FLEURS English (100 clips) | **6.73** | — | 4.48 | 3.92 | — | "Apple is less accurate than Parakeet in all six shared languages." Note: yapapp.cc is a paid dictation app, not finnvoor/yap. |
| [Yap noise test](https://yapapp.cc/data/asr-noise-robustness) (Oct 2026, M2 Pro) | FLEURS EN + babble at 10 dB SNR | **13.87** | — | 4.48 | 5.51 | — | At 5 dB: Apple 31.34, Parakeet v3 7.85, Whisper turbo 13.92. "Apple SpeechTranscriber was the least accurate almost everywhere." |
| [Argmax blog](https://www.argmaxinc.com/blog/apple-and-argmax) (2025-06-20, M4 Mac mini, **macOS 26 beta 1**) | Earnings-22, 10% subset (~12 h) | **14.0** | 11.7 (Argmax Pro) | — | — | — | whisper-base.en 15.2, whisper-small.en 12.8. Vendor benchmark, beta OS. "Apple matches the speed and accuracy of mid-tier OpenAI Whisper models on long-form conversational speech." |
| [9to5Mac](https://9to5mac.com/2025/07/03/how-accurate-is-apples-new-transcription-ai-we-tested-it-against-whisper-and-parakeet/) (2025-07-03, M2 Pro, beta) | one 7:31 podcast episode | **10.3** | 12.3 | — | 1.5 | — | n=1 file, unnormalized HF `wer` metric (punctuation likely counted). Weak evidence. |
| [Dictato](https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/) (2026-04-28) | 13k real dictation clips, 5 languages | best in FR/DE/IT clean speech | Parakeet best on disfluent speech (3/5 langs) | | WhisperKit best EN clean (5.2%) | | Per-language winners only; no full table. Vendor ships all engines. |

### What the table says

1. **Clean read English:** Apple ≈ Parakeet v2 ≈ Whisper large-v3/turbo. A tie within confidence intervals ([verliapp](https://github.com/verliapp/stt-benchmark)).
2. **Conversational / long-form (Earnings-22, the only set no engine trained on):** Apple is **statistically behind Parakeet** (by 0.5–1.2 pp, paired test) and **level with on-device Whisper large-v3-turbo** ([verliapp](https://github.com/verliapp/stt-benchmark)).
3. **Meetings (AMI):** Apple 14.3% vs Parakeet ~11.5%. Part of the gap is Parakeet's home advantage (AMI is in its training data); Apple's training data is undisclosed ([verliapp](https://github.com/verliapp/stt-benchmark)). Apple's 14.3 is close to the leaderboard's long-form Whisper large-v3 (~14.9) figure — inference, different harnesses.
4. **Noise / competing talkers:** Apple degrades **much faster** than Parakeet and Whisper turbo once background speech gets within ~10 dB of the speaker ([Yap noise test](https://yapapp.cc/data/asr-noise-robustness)). This matters for meetings with crosstalk. Caveat: synthetic babble mixed digitally over read sentences, one Mac.
5. **Old API vs new:** `SFSpeechRecognizer` is 3.5–4x worse than `SpeechTranscriber` (9.02% vs 2.12% clean) ([Lyonesse round 1](https://lyonesse.app/blog/apple-speech-api-benchmark.html)). `DictationTranscriber` is also ~4.3x worse than `SpeechTranscriber` on the same audio (7.13% vs 1.64%) ([Lyonesse macOS 27 test](https://lyonesse.app/blog/macos-27-speech-api-accuracy.html)) — do not use `DictationTranscriber` as the fallback for meetings.

### Reference point: what Biscotti ships today

Biscotti today uses WhisperKit `openai_whisper-large-v3-v20240930_626MB` (`Packages/Transcription/Sources/Transcription/MethodResolver.swift:25`). The repo calls it "Non-turbo large-v3, quantized" (`specs/research/argmax/README.md`). (Out of lane, one line: the `v20240930` tag matches OpenAI's large-v3-turbo release date; the model-landscape subtopic owns this.) Either way, the benchmarks put Apple **roughly level** with on-device Whisper large-v3/turbo on clean and Earnings-22 audio, **worse** in babble noise and on FLEURS. So Apple would not be a quality upgrade over today's engine; Parakeet would be.

---

## 2. Punctuation, casing, formatting

- `SpeechTranscriber` produces punctuated, cased text: "it produces punctuated, cased text where the legacy engine's output is rougher" ([Lyonesse round 1](https://lyonesse.app/blog/apple-speech-api-benchmark.html)). Example outputs in [Lyonesse macOS 27 test](https://lyonesse.app/blog/macos-27-speech-api-accuracy.html): "… the squalid quarter of the brothels." (period, commas inserted).
- Number formatting flips between forms run to run across OS versions: "the recognizer writing "20" where it previously wrote "twenty", and "second" where it previously wrote "2nd"" ([Lyonesse macOS 27 test](https://lyonesse.app/blog/macos-27-speech-api-accuracy.html)). So expect inverse text normalization (digits) by default, and expect it to drift with asset updates.
- `etiquetteReplacements` is the only `TranscriptionOption`: "Replaces certain words and phrases with a redacted form" (profanity) ([Apple docs, SpeechTranscriber.TranscriptionOption](https://developer.apple.com/documentation/speech/speechtranscriber/transcriptionoption)). Leave it off.
- Filler words ("um", "uh"): **not determined.** I found no source that states whether SpeechTranscriber keeps or drops disfluencies.

## 3. Long files (1-hour meetings)

- The API is built for long-form. Each result is an endpointed phrase with its own `range`; there is no 30 s window or length cap like `SFSpeechRecognizer`'s one-minute limit ([Fraze](https://getfraze.app/learn/apple-speechanalyzer) citing Apple's SFSpeechRecognizer page; [Apple docs, SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)).
- Observed long runs:
  - MacStories: 34-minute episode in 45 s via Yap (unnamed Mac, June 2025 beta) ([MacStories](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/)).
  - iPhone 17 Pro Max, iOS 26.2: 95–122 minute podcasts completed (4.6–6.2x real time; thermal throttling when two ran in parallel) ([Jake Spurlock, 2025-12-17](https://jakespurlock.com/2025/12/i-wanted-podcast-transcriptions-ios-26-delivered-and-nearly-melted-my-phone/)). No missing-span reports.
  - Murmur: a 4.5-minute file, 0.7% WER, 63x real time on M1 Pro ([saymurmur.app, 2026-10-11](https://saymurmur.app/blog/apple-speech-vs-whisper-benchmark)).
- **No independent WER measurement of SpeechTranscriber on a 30–60+ minute real meeting recording was found.** All meeting-like numbers (AMI, Earnings-22) are on clips.
- No report found of SpeechTranscriber silently dropping spans mid-file. (Contrast: Parakeet TDT v3 has a reported silent 46-second drop on a 77-minute file in another runtime — [Diarist docs](https://diarist.dev/docs/models/); out of lane, noted only as a comparison risk.)
- Hangs reported on long files were app-side integration bugs:
  - Lyonesse: "fed audio to SpeechAnalyzer and closed the input stream, but never called `finalizeAndFinishThroughEndOfInput()`. Without that call the analyzer never delivers its final results, and the import hangs forever." ([Lyonesse round 1](https://lyonesse.app/blog/apple-speech-api-benchmark.html)).
  - finnvoor/yap issue #27 (2026-04-16): hang at ~68% attributed to unstructured concurrency between `start()` and the results loop ([GitHub](https://github.com/finnvoor/yap/issues/27)).

## 4. Far-field / multi-speaker

- Apple claim: designed for "conversational use cases where some speakers might not be close to the mic, such as recording a meeting" ([WWDC25 277](https://developer.apple.com/videos/play/wwdc2025/277/)).
- Independent evidence: AMI (ESB bundle; I believe this is the headset/IHM condition, as the Open ASR leaderboard uses — not confirmed in the verliapp README) Apple 14.32% vs Parakeet ~11.5% ([verliapp](https://github.com/verliapp/stt-benchmark)). Babble noise shows Apple degrading fastest ([Yap noise test](https://yapapp.cc/data/asr-noise-robustness)).
- **No AMI single-distant-mic (SDM) number for Apple was found.** [Murmur's meeting benchmark](https://mumr.app/research/local-transcription-benchmark-mac) (2026-09-30) ran Parakeet and Whisper on AMI IHM+SDM but lists "Apple Speech" as "Not covered yet".
- `DictationTranscriber` has a `farField` content hint; `SpeechTranscriber` has **no** content hints ([Apple docs, DictationTranscriber.ContentHint](https://developer.apple.com/documentation/speech/dictationtranscriber/contenthint)). Since `DictationTranscriber` is ~4x worse in general, this is not a useful lever.

## 5. Does macOS 27 improve quality? No (for the developer API)

- Apple's macOS 27 dictation claim ("a major boost in accuracy … polished text with greater precision") is for **systemwide dictation** on "Mac (M3) or later with at least 12GB of unified memory" ([Apple Newsroom, 2026-06-08](https://www.apple.com/newsroom/2026/06/apple-introduces-siri-ai-a-profoundly-more-capable-and-personal-assistant/)), English only ([yapapp.cc macOS 27 dictation](https://yapapp.cc/macos-27-dictation)).
- Measured on the Speech framework API: macOS 27.0.1 returned **byte-identical** transcripts to macOS 26.5.1 on 280/300 LibriSpeech clips (296/300 ignoring punctuation), on both an M2 Pro and an M4 Pro (M4 Pro qualifies for the advanced model). Turning system dictation on changed nothing. "If you are a developer hoping the framework quietly got better, it did not, on either machine we could test." ([Lyonesse, 2026-10-12](https://lyonesse.app/blog/macos-27-speech-api-accuracy.html)).
- The SDK diff 26 → 27 is plumbing only; "No new transcriber, no new preset, no new content hint, no new model selector." (same source; corroborated by Apple's [Speech updates page](https://developer.apple.com/documentation/updates/speech), which lists only `AssetInputSequenceProvider`/`CaptureInputSequenceProvider` and `AnalyzerInputConverter` for June 2026).

## 6. Sources of weaker quality

- [Micrologics, 2026-07-14](https://micrologics.org/blog/benchmarking-apples-speechanalyzer-api-vs-whisper-the-new-standard-for-on-device-speech-to-text) claims CHiME-6 numbers and "watchOS" support. watchOS is wrong per Apple docs (no watchOS) and the article has no data release. **Treated as unreliable; not used.**
- [tamiz.pro](https://tamiz.pro/insights/apple-speechanalyzer-vs-whisper-benchmark) lists "96–98% WER" (accuracy mislabelled). **Not used.**
- [heise, 2025-07-04](https://www.heise.de/en/news/Speech-to-text-Apple-s-new-APIs-outperform-Whisper-on-speed-10475273.html) only re-reports MacStories and 9to5Mac (beta OS, n=1).

# Apple Built-in Speech APIs (SpeechAnalyzer / SpeechTranscriber)

Researched 2026-10-21 (macOS 27.0 shipped 2026-09-14).

## Bottom Line

Apple's `SpeechTranscriber` (macOS 26+) is usable for Biscotti's batch, file-based, XPC-hosted pipeline:
- No model files for the app to manage.
- No Speech Recognition permission prompt (per Apple's docs and two working CLIs).
- Punctuated, cased text with per-run time ranges and 0–1 confidence.
- About 45–70x real time on M-series Macs.

**It does not pass a "better than what we have" quality gate.** Independent benchmarks put it:
- Level with on-device Whisper large-v3/turbo on clean speech and Earnings-22.
- Statistically behind Parakeet on conversational and meeting audio (Earnings-22 12.0% vs ~11.2%; AMI 14.3% vs ~11.5%).
- Clearly the worst of the three in noise or with competing talkers.

macOS 27 did not change quality: the API returns byte-identical transcripts to 26.5.1. WWDC26 added only audio-input plumbing, and the new "advanced dictation" model is not exposed to the API.

So Apple is a viable **zero-download tier at roughly today's quality**, not a quality upgrade. It has no diarization, no language detection and no custom vocabulary. Assets still download once (managed by the system) and can be evicted. If the split strategy goes ahead, macOS 26.5+ is the defensible floor; gating on 27 buys nothing.

## Key Findings

- **Quality vs Parakeet and Whisper** ([verliapp/stt-benchmark](https://github.com/verliapp/stt-benchmark), M4 Pro, macOS 26.5.1, July 2026):
  - LibriSpeech: Apple 1.82% ties Whisper large-v3 (1.82%) and Parakeet v2 (1.69%).
  - Earnings-22 (no engine trained on it): Apple 12.03% vs Parakeet v2/v3 11.23/11.20% and WhisperKit turbo 12.35%. A paired test puts Apple 0.5–1.2 pp behind Parakeet.
  - AMI: Apple 14.32% vs Parakeet ~11.5%, but Parakeet was trained on AMI.
- **Noise is Apple's weak spot** ([yapapp.cc noise test](https://yapapp.cc/data/asr-noise-robustness), Oct 2026). FLEURS English with background babble:

  | Condition | Apple | Parakeet v3 | Whisper turbo |
  |---|---|---|---|
  | Clean | 6.73% | 4.48% | 3.92% |
  | 10 dB SNR | 13.87% | 4.48% | 5.51% |
  | 5 dB SNR | 31.3% | 7.9% | 13.9% |

- **No long-form meeting WER exists for Apple.** Nobody has tested it on 30–60 min real meetings or AMI far-field (single distant mic) audio. Long files do complete: a 34-min episode, and 95–122 min podcasts on iPhone. The hangs people reported were app bugs: a missing `finalizeAndFinish…` call ([Lyonesse](https://lyonesse.app/blog/apple-speech-api-benchmark.html), [MacStories](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/)).
- **macOS 27 brings no quality change for the API.**
  - 280 of 300 transcripts were byte-identical to 26.5.1, on both M2 Pro and M4 Pro ([Lyonesse, 2026-10-12](https://lyonesse.app/blog/macos-27-speech-api-accuracy.html)).
  - The SDK changes are plumbing only: `AssetInputSequenceProvider`, `CaptureInputSequenceProvider`, `AnalyzerInputConverter`, and a public `ignoresResourceLimits` ([Apple Speech updates](https://developer.apple.com/documentation/updates/speech)).
  - Apple's "major boost in accuracy" is for systemwide dictation on M3+ Macs with 12 GB, English only ([Apple Newsroom](https://www.apple.com/newsroom/2026/06/apple-introduces-siri-ai-a-profoundly-more-capable-and-personal-assistant/)).
- **Use `SpeechTranscriber`, never `DictationTranscriber`, for meetings.** DictationTranscriber is a different, older model: 7.13% vs 1.64% WER on the same audio ([Lyonesse](https://lyonesse.app/blog/macos-27-speech-api-accuracy.html)).
- **Speed:** about 45–70x real time on long audio (Argmax 70x on M4 with a beta OS; MacStories ~45x; 9to5Mac ~50x on M2 Pro). That is 2–5x faster than WhisperKit large-v3/turbo and about 3–5x slower than Parakeet on the Neural Engine (Argmax 359x; on a 7.5-min file 9to5Mac measured Parakeet at 2 s vs Apple at 9 s) ([Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)).
- **Energy: nobody has measured it.** Inference only: it runs on Neural Engine + CPU (per Argmax) in a system process, so the power use shows up outside our XPC service.
- **Output shape** ([Apple docs](https://developer.apple.com/documentation/speech/speechtranscriber/result), [simonw/speech-analyzer-cli](https://github.com/simonw/speech-analyzer-cli)):
  - A stream of `SpeechTranscriber.Result` values, one per spoken phrase: `text: AttributedString`, `alternatives`, `range: CMTimeRange`, `isFinal`, `resultsFinalizationTime`.
  - Each text run carries `audioTimeRange` and `transcriptionConfidence` (0–1, sometimes missing).
  - Runs are roughly per token, so they must be grouped into words with `NLTokenizer`.
  - Word ranges are "useful for playback synchronization, but should not be interpreted as precise forced-alignment boundaries around silence."
- **Batch use** ([Apple docs, SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)):
  - Don't turn on volatile (draft) results; you then get final results only.
  - You must call `finalizeAndFinish(through:)`, or the stream never ends.
  - The file path, `analyzeSequence(from: AVAudioFile)`, is the battle-tested one. The buffer path has an unconfirmed `nilError` report on macOS 26.3.
- **No diarization, no language detection, no custom vocabulary** in `SpeechTranscriber`. Contextual strings and custom language models exist only on `DictationTranscriber`. The caller must pick the locale ([Argmax feature table](https://www.argmaxinc.com/blog/apple-and-argmax), [DictationTranscriber docs](https://developer.apple.com/documentation/speech/dictationtranscriber)).
- **Assets are managed by the system but not preinstalled** ([Apple docs, AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)):
  - The app triggers `AssetInventory.assetInstallationRequest(...).downloadAndInstall()`. Calling it repeatedly is safe, and it reports real `Progress`.
  - Assets are shared across apps, including Notes and Voice Memos.
  - They update at Apple's discretion, so the model can change under a fixed method id.
  - "The system may unsubscribe your app from assets that haven't been used in a while."
  - Size is not published.
- **Locales:** about 30 locales in 10 languages on macOS 26.6.2: EN, ES, FR, DE, IT, PT, JA, KO, ZH, YUE ([Notey](https://noteymeet.com/guides/transcription-languages-mac)). A conflicting 42-locale list also exists.
- **Permissions and XPC:**
  - Apple says the speech-recognition permission flow "only applies to speech recognition using `SFSpeechRecognizer`. `SpeechAnalyzer` transcriber modules don't send audio … to Apple's servers" ([Apple docs](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)).
  - Two CLIs ([finnvoor/yap](https://github.com/finnvoor/yap) and verliapp's `sacli`) transcribe with no Info.plist and no permission request.
  - No entitlement is documented, and the model runs outside our process.
  - Not yet proven inside an `.xpc` bundle.
- **Mapping to `TranscriptResult`:**
  - Most fields map with glue code: group runs into words, convert `CMTime` to seconds, average confidence, re-segment by speaker.
  - `noSpeechProbability` has no source, so it would be 0.
  - `language` comes from the locale we pass in, not from detection.
  - Speaker fields come from our own SpeakerKit alignment, the same work the FluidAudio path needs.
  - If Apple and SpeakerKit both get the same merged 16 kHz audio, their timelines match exactly.

## Details

- [quality-benchmarks.md](./quality-benchmarks.md): every independent WER number (LibriSpeech, Earnings-22, AMI, FLEURS, babble noise), punctuation and formatting, long-file behaviour, far-field evidence, the macOS 27 null result, and sources judged unreliable. Read this when making the quality-gate call.
- [speed-and-energy.md](./speed-and-energy.md): speed table across sources and chips, compute units, the out-of-process memory model, the missing energy data, and how to measure it.
- [api-output-and-contract-mapping.md](./api-output-and-contract-mapping.md): the API (presets, options), `Result` and attribute details, volatile vs final for batch, input options for Biscotti's merged audio, and the field-by-field mapping to `TranscriptResult.swift` with SpeakerKit alignment notes.
- [deployment-assets-permissions-os.md](./deployment-assets-permissions-os.md): the asset lifecycle (who downloads, eviction, reservations, offline), the locale list, hardware, permissions evidence, XPC suitability, error mapping, and the macOS 26 vs 27 table with the minimum-OS recommendation.

## Open Questions / Gaps

- **Energy:** no published power or energy numbers on a Mac. Needs a `powermetrics` run per engine; Apple's work shows up under a system daemon.
- **Long-form meeting WER:** no 30–60 min real-meeting or AMI far-field test of Apple exists ([Murmur](https://mumr.app/research/local-transcription-benchmark-mac) lists Apple as "not covered yet"). Running the repo's own AI test fixture would be the cheapest check.
- **Word timestamps:** nobody has measured run granularity (token vs word, separate punctuation runs) or boundary accuracy. Needs a hardware probe, ideally scored by speaker-attribution error after SpeakerKit alignment.
- **Confidence:** the 0–1 range is documented, but values are sometimes missing and calibration is unknown. The `TranscriptSanitizer` 0.3 threshold needs re-checking.
- **Asset size and eviction timing:** not published, and "haven't been used in a while" is undefined.
- **XPC spike:** no source runs SpeechAnalyzer inside an `.xpc` service; the evidence is CLIs and helper processes. Also need to confirm there is no permission prompt in a hardened-runtime, Developer-ID build.
- **Locale list:** the 30 vs 42 conflict is unresolved.
- **Filler words:** whether "um"/"uh" are kept or dropped is undocumented and untested.
- **Input format:** reports conflict on whether the file path accepts compressed AAC. Biscotti should feed uncompressed audio, which avoids the question.
- Could not open the Apple forums thread for the 26.3 buffer-path `nilError` (FB22149971). That claim rests on a third-party research note.

## Sources

- **Apple docs** (fetched 2026-10-21; they describe the macOS 27 SDK): [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber), [SpeechTranscriber.Result](https://developer.apple.com/documentation/speech/speechtranscriber/result), [Preset](https://developer.apple.com/documentation/speech/speechtranscriber/preset), [ReportingOption](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption), [ConfidenceAttribute](https://developer.apple.com/documentation/foundation/attributescopes/speechattributes/confidenceattribute), [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory), [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber), [Asking Permission to Use Speech Recognition](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition), [Speech updates](https://developer.apple.com/documentation/updates/speech). Primary source for API facts.
- [WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/) (June 2025): Apple's design intent (long-form, far-field, model runs outside the app, volatile vs final).
- [Apple Newsroom, 2026-06-08](https://www.apple.com/newsroom/2026/06/apple-introduces-siri-ai-a-profoundly-more-capable-and-personal-assistant/): the macOS 27 dictation claim and the M3/12 GB requirement.
- Lyonesse/Inscribe [round 1](https://lyonesse.app/blog/apple-speech-api-benchmark.html) (2026-07-13), [round 2](https://lyonesse.app/blog/parakeet-moss-apple-speech-benchmark.html) (2026-07-15) and [macOS 27 test](https://lyonesse.app/blog/macos-27-speech-api-accuracy.html) (2026-10-12): LibriSpeech WER with published transcripts, the 26 vs 27 comparison, and the DictationTranscriber gap.
- [verliapp/stt-benchmark](https://github.com/verliapp/stt-benchmark) (2026-07-15): the strongest independent comparison, with confidence intervals, paired tests, Earnings-22, AMI and the source of its Apple harness.
- [Argmax blog](https://www.argmaxinc.com/blog/apple-and-argmax) (2025-06-20): Earnings-22 WER and speed on macOS 26 beta 1, plus feature and deployment tables. Vendor source.
- yapapp.cc [speed/accuracy](https://yapapp.cc/questions/fastest-on-device-speech-recognition-mac) and [noise robustness](https://yapapp.cc/data/asr-noise-robustness) (Oct 2026): FLEURS speed and WER, and accuracy under babble noise. Published by a competing dictation app.
- Real-world speed and long files: [MacStories](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/) (2025-06-17), [9to5Mac](https://9to5mac.com/2025/07/03/how-accurate-is-apples-new-transcription-ai-we-tested-it-against-whisper-and-parakeet/) (2025-07-03), [saymurmur.app](https://saymurmur.app/blog/apple-speech-vs-whisper-benchmark) (2026-10-11), [Jake Spurlock](https://jakespurlock.com/2025/12/i-wanted-podcast-transcriptions-ios-26-delivered-and-nearly-melted-my-phone/) (2025-12-17).
- Working code: [finnvoor/yap](https://github.com/finnvoor/yap) (commit 2026-07-20), [simonw/speech-analyzer-cli](https://github.com/simonw/speech-analyzer-cli) (2026-07) and [yap issue #27](https://github.com/finnvoor/yap/issues/27) — CLI with no permission request, word grouping, missing confidence values, the timestamp caveat, the AAC input issue.
- [mac-transcriber research note](https://github.com/yrocaz/mac-transcriber/blob/main/docs/research/2026-07-27-apple-speechanalyzer-docs.md) (2026-07-27): secondary digest of Apple's docs and forum findings. Used for renamed APIs and the 26.3 buffer-path report.
- [Notey](https://noteymeet.com/guides/transcription-languages-mac) (2026-09-25) and [Anton Gubarenko](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide) (2025-10-22): the two conflicting locale lists.
- [Transcripty](https://gitlab.com/stoicswe/transcripty): an existing app that pairs SpeechTranscriber with a separate diarizer and merges them at word level.

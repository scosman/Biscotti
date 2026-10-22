# Apple SpeechTranscriber — Speed and Energy

Researched 2026-10-21. RTFx = seconds of audio per second of wall time (higher is faster).

## 1. Speed measurements

| Source (date) | Hardware / OS | Input | Apple SpeechTranscriber | Comparison engines (same run) |
|---|---|---|---|---|
| [Argmax](https://www.argmaxinc.com/blog/apple-and-argmax) (2025-06-20) | M4 Mac mini, macOS 26 beta 1 | Earnings-22 subset, long-form | **70x** | Parakeet v2 (Argmax Pro) 359x; whisper-small.en 35x; whisper-base.en 111x |
| [verliapp/stt-benchmark `results/apple.json`](https://github.com/verliapp/stt-benchmark) (2026-07-15) | M4 Pro, macOS 26.5.1 | LibriSpeech test-clean, 2,620 short clips, one file at a time | **~51x** (RTF 0.0196: 19,452 s audio in 381 s) | "Apple and Parakeet run single-stream at roughly 0.02 real-time factor" (Parakeet via parakeet-mlx, not CoreML) |
| [Yap (yapapp.cc)](https://yapapp.cc/questions/fastest-on-device-speech-recognition-mac) (Oct 2026) | M2 Pro | FLEURS, 100 short clips per language | **34x** EN; 46–78x other languages | Parakeet TDT v3 19x EN; Whisper large-v3-turbo 12x EN. Short clips carry per-file overhead: "treat them as a floor for file transcription." |
| [MacStories](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/) (2025-06-17) | Unnamed Mac, macOS 26 beta | 34-min episode (7 GB 4K video) | 45 s → **~45x** | MacWhisper large-v3-turbo 1:41 (~20x); large-v2 3:55 |
| [9to5Mac](https://9to5mac.com/2025/07/03/how-accurate-is-apples-new-transcription-ai-we-tested-it-against-whisper-and-parakeet/) (2025-07-03) | M2 Pro 16 GB, beta | 7:31 episode | 9 s → **~50x** | Parakeet v2 (MacWhisper) 2 s (~225x); Whisper large-v3-turbo 40 s (~11x) |
| [Murmur](https://saymurmur.app/blog/apple-speech-vs-whisper-benchmark) (2026-10-11) | M1 Pro 16 GB, macOS 26.6.2 | 4.5-min file | 4.3 s → **~63x** | whisper.cpp large-v3-turbo (Metal) 3.8 s for a 29 s clip vs Apple 0.64 s |
| [Lyonesse round 1](https://lyonesse.app/blog/apple-speech-api-benchmark.html) (2026-07-13) | M2 Pro | LibriSpeech | "about 3x faster than Whisper Small"; all engines 12–40x | No precise table ("shared the machine with a development workload") |
| [Jake Spurlock](https://jakespurlock.com/2025/12/i-wanted-podcast-transcriptions-ios-26-delivered-and-nearly-melted-my-phone/) (2025-12-17) | iPhone 17 Pro Max, iOS 26.2 | 95–122 min podcasts | 4.6–6.2x | Two parallel jobs dropped to 2.7x (thermal) |

**Library comparison points (out of lane, for context only):**
- FluidAudio Parakeet TDT v3: "2.6% Avg WER / 110x RTFx" on LibriSpeech on an M5 Pro ([FluidAudio Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)); 85.7x on a MacBook Air M2 for 100 short files ([FluidAudio benchmarks100.md, 2026-03-28](https://github.com/FluidInference/FluidAudio/blob/04747b3e/Documentation/ASR/benchmarks100.md)). A contributor claims a patch reaches 320x (v2) / 282x (v3): "one hour of audio transcribed in 11.25 and 12.75 seconds" ([HN comment citing FluidAudio PR #507](https://news.ycombinator.com/item?id=48897047)). The FluidAudio subtopic owns these numbers.
- [Murmur meeting benchmark](https://mumr.app/research/local-transcription-benchmark-mac) (M5 Max, 30 s chunks): Parakeet v3 212–227x; WhisperKit large-v3-turbo 13–20x.

### Reading the speed numbers

- On long-form audio Apple runs at about **45–70x** on M-series Macs: a 1-hour meeting takes about **50–80 seconds** (inference from the rows above).
- That is roughly **2–5x faster than WhisperKit large-v3/turbo**, and roughly **3–5x slower than FluidAudio/Argmax Parakeet on the ANE**.
- The Yap short-clip result (Apple 34x > Parakeet 19x) runs the other way. It used short FLEURS sentences, and the Parakeet runtime is not stated. Per-clip overhead dominates on short clips, so I weight the long-form numbers (Argmax 70x vs 359x; 9to5Mac 9 s vs 2 s) more heavily for 1-hour meetings.
- Preset choice: on iPhone, `.progressiveTranscription` ("fast") was not meaningfully faster than `.transcription` for batch files ([Jake Spurlock](https://jakespurlock.com/2025/12/i-wanted-podcast-transcriptions-ios-26-delivered-and-nearly-melted-my-phone/)). `.fastResults` is documented as "faster but also less accurate" ([Apple docs, ReportingOption](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption)). For batch work, use `.transcription` with no volatile or fast results.
- Concurrency: "The system normally limits simultaneous analyses to a conservative number … If you exceed that number, the system throws an `insufficientResources` error." `ignoresResourceLimits` (public in the 27 SDK) overrides this ([Apple docs, SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer); [Lyonesse SDK diff](https://lyonesse.app/blog/macos-27-speech-api-accuracy.html)). Biscotti runs one batch job at a time, so this does not apply.

## 2. Compute unit and memory

- Argmax's table (June 2025): Apple's compute engine is "Neural Engine + CPU (Hardcoded)"; the model "does not … increase my app's memory usage" ([Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)). I found no Apple doc that states the compute units. Treat this as Argmax's observation.
- Apple: the model "is retained in system storage and does not increase the download or storage size of your application, nor does it increase the run-time memory size. It operates outside of your application's memory space" ([WWDC25 277](https://developer.apple.com/videos/play/wwdc2025/277/)). In practice it runs in a shared system process. Activity Monitor shows `localspeechrecognition` for on-device speech ([whyslow.app](https://whyslow.app/process/localspeechrecognition/)); one third-party guide says the analyzer runs in "a system XPC service that is shared across apps" ([Swift Crafted](https://swiftcrafted.dev/article/speechanalyzer-speechtranscriber-ios-26-swift)). I did not confirm the exact daemon that runs `SpeechTranscriber` from a primary source.
- Consequence for Biscotti: memory and power land in a system process, not in `BiscottiTranscriber.xpc`. Our XPC service's footprint during transcription would be small (buffers plus results), but jetsam or memory pressure can still hit the system daemon.
- Caution (related API, different class): a GitHub issue documents `localspeechrecognition` growing to ~42 GB RSS when an app created a new **`SFSpeechRecognizer`** per session; "Asset subscriptions accumulate 40:1 against releases" ([openclaw#133486](https://github.com/openclaw/openclaw/issues/133486)). I found no equivalent report for `SpeechAnalyzer`. Creating one analyzer per meeting (Apple's documented pattern) is not known to leak, but this is worth watching on hardware.
- Model retention: `SpeechAnalyzer.Options.ModelRetention` is `.whileInUse` (default; "Releases the models when the analyzer is deallocated"), `.lingering`, or `.processLifetime`. `SpeechModels.endRetention()` "Releases all models held by cached recognizer instances" ([Apple docs](https://developer.apple.com/documentation/speech/speechanalyzer/options/modelretention-swift.enum), [SpeechModels](https://developer.apple.com/documentation/speech/speechmodels)).

## 3. Energy — not measured by anyone I could find

- **No published power or energy measurement (watts, joules, Wh per audio-hour, battery %) of `SpeechTranscriber` on a Mac was found.** I searched for powermetrics, battery, ANE and energy comparisons against WhisperKit and Parakeet.
- The [Micrologics](https://micrologics.org/blog/benchmarking-apples-speechanalyzer-api-vs-whisper-the-new-standard-for-on-device-speech-to-text) article makes thermal and energy claims, but it has factual errors (it claims watchOS support) and no data. Not used.
- Inferences only (labelled as such):
  - Energy per job scales roughly with compute time × power draw. Apple is reported to run on ANE + CPU, as do CoreML Parakeet and WhisperKit, so the speed ratio is a rough proxy: Apple likely uses less energy per meeting than WhisperKit large-v3 (2–5x faster) and more than ANE Parakeet (3–5x slower). This is unverified. CPU share differs between engines, and Apple's daemon is opaque.
  - Thermal: iPhone tests show throttling under sustained parallel load ([Jake Spurlock](https://jakespurlock.com/2025/12/i-wanted-podcast-transcriptions-ios-26-delivered-and-nearly-melted-my-phone/)). No Mac thermal reports were found.
- To close this gap: run `sudo powermetrics --samplers cpu_power,gpu_power,ane_power` while transcribing the same 1-hour meeting with each engine on one Mac. Note that Apple's work shows up under the system daemon, not our process.

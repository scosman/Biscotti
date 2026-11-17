# Apple SpeechTranscriber — Assets, Locales, Permissions, XPC, and OS Versions

Researched 2026-10-21.

## 1. Model assets: "zero app-managed download", not zero download

**Who downloads, and when.** The OS downloads the model, but the app must trigger the download. "Before using the SpeechAnalyzer class, you must install assets required by the modules you plan to use. These assets are machine-learning models downloaded from Apple's servers and managed by the system." ([Apple docs, AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)). The model is not preinstalled with the OS. Argmax's table: "Is the model pre-installed in the operating system? No / Is the model automatically downloaded during first use? Yes" ([Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)).

**Install flow** (Apple docs):
1. Create modules in the configuration you will use.
2. Reserve the locale (automatic, or `AssetInventory.reserve(locale:)`).
3. `AssetInventory.assetInstallationRequest(supporting:)` → `downloadAndInstall()`.
4. Wait. "Note that the download may finish immediately; the assets may have already been downloaded if the assets were preinstalled on the system, another app already downloaded them, or a previous module configuration used the same assets."
- Requests are idempotent: "The system consolidates download and installation requests; you may obtain several of these instances and call `downloadAndInstall()` several times without causing redundant downloads." ([AssetInstallationRequest](https://developer.apple.com/documentation/speech/assetinstallationrequest)).
- Progress: `AssetInstallationRequest.progress` is a Foundation `Progress` with a real `fractionCompleted` (yap polls it) ([finnvoor/yap Transcribe.swift](https://github.com/finnvoor/yap)). This is a better progress signal than WhisperKit's file-count weighting.
- Status: `AssetInventory.status(forModules:)` → `.installed / .downloading / .supported / .unsupported` ("downloading" covers "waiting for conditions to improve and continue downloading later"). One developer found `status` returning `.supported` when assets were present and recommends checking whether `assetInstallationRequest(supporting:)` returns `nil` instead ([ayousanz, 2026-09-09](https://ayousanz.hatenadiary.jp/entry/2026/09/09/235538)).

**Persistence and sharing.** "Once you download, install, or use an asset, the system retains and updates it automatically, and shares it with other apps." If the user already uses Notes or Voice Memos transcription (same model, per WWDC25), the asset is likely already present. Argmax: "a newly installed app will find that the model was previously downloaded by another app, including Apple's first-party apps" ([Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)).

**Eviction risk.** "The system may unsubscribe your app from assets that haven't been used in a while." Also: "When your app no longer needs assets for a particular locale, call `release(reservedLocale:)` … The system will remove the assets at a later time." ([AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)). So Biscotti must check and (re)install before **every** transcription. A user offline for a long stretch could find the asset gone. Treat a missing asset as a first-class error state, the same as WhisperKit's missing model.

**Reservation limit.** `maximumReservedLocales`: "The number of locale reservations permitted to an app … The value may vary between devices according to storage space." Exceeding it throws `tooManyAssetLocalesAllocated`. A benchmark harness comment says "Apple allows five reserved locales per app" ([verliapp sacli main.swift](https://github.com/verliapp/stt-benchmark)); that figure is not in Apple's docs.

**Offline.** After install, transcription runs offline. "The first run for a locale downloads Apple's speech model; every run after that is fully offline." ([arraypress/swift-speech-transcriber](https://github.com/arraypress/swift-speech-transcriber)). Apple: "transcription is entirely on device but the models need to be fetched" (WWDC25 277). The asset auto-updates. **This means the model can change between two transcriptions with no app release.** Apple's model "Updates: At Apple's discretion" ([Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)). For Biscotti's `transcriptionMethodId` reproducibility promise, this is a real semantic change: the same method id can give different output over time.

**Size.** **Not found.** Apple does not publish asset sizes. A third-party guide says "No duplicate 200 MB download" ([Swift Crafted](https://swiftcrafted.dev/article/speechanalyzer-speechtranscriber-ios-26-swift)), but gives no source or measurement, so treat it as unverified. To measure: log `progress.totalUnitCount` during `downloadAndInstall()` on a clean machine.

**Download failures seen.** "transcription.ar asset not found after attempted download" (Arabic) ([Apple Developer Forums, Speech tag](https://developer.apple.com/forums/tags/speech)). This is not relevant for English.

## 2. Locale coverage

- Ask at runtime (`SpeechTranscriber.supportedLocales`, "including locales that may not be installed but are downloadable"; it is "empty if the device does not support the transcriber"). Apple publishes no fixed list.
- On macOS 26.6.2 (2026-09-25), the list was **30 locales across 10 languages**: English (AU, CA, IN, IE, NZ, SG, ZA, GB, US), Spanish (CL, MX, ES, US), French (BE, CA, FR, CH), German (AT, DE, CH), Chinese (CN, HK, TW), Portuguese (BR, PT), Italian (IT, CH), Japanese, Korean, Cantonese ([Notey](https://noteymeet.com/guides/transcription-languages-mac)). Argmax (June 2025) counted 10 languages.
- Conflicting source: a 2025-10-22 post lists 42 locales, including ar_SA, da_DK, fi_FI, he_IL, nb_NO, nl_NL, ru_RU, sv_SE, th_TH, tr_TR and vi_VN ([Anton Gubarenko](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide)). I could not reconcile the two. It may be device- or OS-specific, or the post may have mixed in `DictationTranscriber` locales. The forum report of Arabic "asset not found after attempted download" suggests some listed locales may not be installable.
- Compared to the libraries: Whisper covers ~99–100 languages; Parakeet v3 covers 25 European languages. Apple adds CJK (ja/ko/zh/yue) that Parakeet lacks, but drops most European languages beyond the big five (no Dutch, Polish, Nordic in the 30-locale list).

## 3. Hardware

- `SpeechTranscriber.isAvailable`: "whether this module is available given the device's hardware and capabilities". Apple says it is "available for all platforms but watchOS with certain hardware requirements" (WWDC25 277), but lists no Mac models.
- Third-party: "`SpeechAnalyzer` runs on device only on Apple Silicon" ([FrigadeHQ/yap README](https://github.com/FrigadeHQ/yap/blob/main/README.md)). Benchmarks ran on M1 Pro, M2 Pro, M4 Pro, M4 and M5 Max. No reports of `isAvailable == false` on M1+ were found. Biscotti is Apple-Silicon-only, so this is fine. Still gate on `isAvailable` and fall back to the library engine.
- The macOS 27 "advanced dictation" M3/12 GB requirement applies to **system dictation**, not to `SpeechTranscriber` ([Apple Newsroom footnote](https://www.apple.com/newsroom/2026/06/apple-introduces-siri-ai-a-profoundly-more-capable-and-personal-assistant/); [Lyonesse](https://lyonesse.app/blog/macos-27-speech-api-accuracy.html)).

## 4. Permissions / TCC

**Speech Recognition permission (`NSSpeechRecognitionUsageDescription` + `SFSpeechRecognizer.requestAuthorization`): not required for SpeechAnalyzer modules, per Apple. Third-party evidence agrees.**
- Apple's "Asking Permission to Use Speech Recognition" article, current version: "This process only applies to speech recognition using `SFSpeechRecognizer`. `SpeechAnalyzer` transcriber modules don't send audio data of the user's voice to Apple's servers." ([Apple docs](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)). The article's whole framing is "permission to perform speech recognition using Apple's servers".
- Hands-on evidence: two independent macOS CLIs transcribe files with `SpeechTranscriber` without calling `requestAuthorization` and without any Info.plist. They are plain SPM `executableTarget`s:
  - finnvoor/yap (1.5k★, Homebrew-distributed) ([source](https://github.com/finnvoor/yap));
  - verliapp `SpeechAnalyzerCLI/sacli` ([source](https://github.com/verliapp/stt-benchmark)).
  - A third, simonw/speech-analyzer-cli, chooses to request authorization and wraps itself in an app bundle for the prompt ([source](https://github.com/simonw/speech-analyzer-cli)). This shows only that requesting works, not that it is needed.
- Some third-party guides say both mic and speech permission are needed ([Swift Crafted](https://swiftcrafted.dev/article/speechanalyzer-speechtranscriber-ios-26-swift), [dpearson2699 skill](https://github.com/dpearson2699/swift-ios-skills/blob/924a14db8f82ddf93845ea7c1c1a3529a98f117a/skills/speech-recognition/SKILL.md)). These are about live-mic iOS apps, and they contradict Apple's current note. I weight Apple's docs plus the working CLIs higher.
- **Microphone permission:** not involved for file or buffer input. Biscotti's recorder already holds mic permission in the app.
- **Residual risk:** none of the evidence is from an XPC service in a hardened-runtime Developer-ID app. If TCC ever applies, macOS attributes an XPC service's TCC to the responsible (host) app. Adding `NSSpeechRecognitionUsageDescription` to the app's Info.plist costs nothing as insurance. Verify on hardware.

## 5. Inside a non-sandboxed, hardened-runtime XPC service

- No entitlement is documented as required for `SpeechAnalyzer`/`AssetInventory` (none listed on the class pages). The permissions matrix in `specs/research/permissions/README.md` would need no new entitlement (inference from the absence of any documented requirement).
- The model executes outside the caller's process ("operates outside of your application's memory space", WWDC25 277), in a shared system service (`localspeechrecognition` appears in Activity Monitor for on-device speech: [whyslow.app](https://whyslow.app/process/localspeechrecognition/)). So `BiscottiTranscriber.xpc` would be a thin client: no ANE access from our process, no model files in our cache, and no `ModelStorage` disk use.
- Out-of-process precedent: muninn runs Apple Speech in a separate helper process via a request/response protocol ([bnomei/muninn apple_speech_transcriber.swift](https://github.com/bnomei/muninn/blob/main/src/apple_speech_transcriber.swift)). CLIs (yap, sacli) prove it works from non-app processes. **No source tests it specifically inside an `.xpc` bundle**; this needs a hardware spike.
- The API is Swift-only (`actor`, `AsyncSequence`). Our XPC service is Swift, so this is fine.
- Errors to map ([SFSpeechError.Code](https://developer.apple.com/documentation/speech/sfspeecherror/code)):
  - `noModel`, `assetLocaleNotAllocated`, `cannotAllocateUnsupportedLocale`, `tooManyAssetLocalesAllocated` → model-not-available / download states;
  - `audioReadFailed`, `incompatibleAudioFormats`, `unexpectedAudioFormat`, `audioDisordered` → `.invalidInput`;
  - `insufficientResources`, `internalServiceError`, `moduleOutputFailed`, `timeout` → `.transcriptionFailed`.
  - After any error, "the analysis session becomes finished … create a new analyzer to continue" ([SpeechAnalyzer docs](https://developer.apple.com/documentation/speech/speechanalyzer)).

## 6. OS versions: 26 vs 27, and which minimum to trust

| OS | What it brings for this use case | Source |
|---|---|---|
| macOS 26.0 | `SpeechAnalyzer`, `SpeechTranscriber`, `DictationTranscriber`, `SpeechDetector`, `AssetInventory`; file path `analyzeSequence(from: AVAudioFile)`; per-run `audioTimeRange` + `transcriptionConfidence`. | [Apple docs](https://developer.apple.com/documentation/speech/speechtranscriber) |
| macOS 26.0 betas | Rough: locale-allocation errors ("Cannot use modules with unallocated locales") after a beta update; `.offlineTranscription` preset shown at WWDC was renamed; WWDC `allocate/deallocate` became `reserve/release`. | [Apple forums 790108](https://developer.apple.com/forums/thread/790108); [mac-transcriber note](https://github.com/yrocaz/mac-transcriber/blob/main/docs/research/2026-07-27-apple-speechanalyzer-docs.md) |
| macOS 26.3 | Reported buffer-path bug: `start(inputSequence:)` → `nilError` while the file path works (FB22149971) — third-party report, unconfirmed. | [mac-transcriber note](https://github.com/yrocaz/mac-transcriber/blob/main/docs/research/2026-07-27-apple-speechanalyzer-docs.md) |
| macOS 26.5.1–26.6.2 | Where all the good independent benchmarks ran (Lyonesse, verliapp, Murmur, Notey). | sources in quality doc |
| macOS 27.0 (shipped 2026-09-14) | **Plumbing only**: `AssetInputSequenceProvider`, `CaptureInputSequenceProvider`, `AnalyzerInputConverter`, `AnalyzerInput` gains `CMReadySampleBuffer`, `bufferDuration`, `bufferFormat` (`buffer` deprecated); `ignoresResourceLimits` public; `cannotConfigureAudioSystem` error. **Transcripts byte-identical to 26.5.1.** No language detection, diarization, custom vocab, or new model in the API. | [Speech updates](https://developer.apple.com/documentation/updates/speech); [Lyonesse, 2026-10-12](https://lyonesse.app/blog/macos-27-speech-api-accuracy.html) |

**Recommendation on the minimum OS (inference from the above):**
- Accuracy is decided by the **server-delivered asset**, not the OS point release. 26.5.1 and 27.0.1 produce the same words. So gating on macOS 27 buys **no** quality, only convenience APIs Biscotti does not need (we already have PCM).
- The evidence base (independent benchmarks, battle-tested file path) starts at **macOS 26.5**. If the split strategy is adopted, **macOS 26.5+ (with the file-path input) is the defensible floor**. 26.0–26.4 would technically work but is unmeasured, with reported early bugs.
- Gate at runtime too: `SpeechTranscriber.isAvailable`, plus a supported locale, plus asset `.installed` after the request. Fall back to the library engine otherwise.

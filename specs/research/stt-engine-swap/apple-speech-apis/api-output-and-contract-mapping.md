# Apple SpeechAnalyzer / SpeechTranscriber — API, Output Shape, and Mapping to Biscotti's Contract

Researched 2026-10-21 against Apple's DocC JSON. The docs currently served describe the macOS 27 SDK. Items marked 27.0 are not on macOS 26. Primary pages: [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber), [SpeechTranscriber.Result](https://developer.apple.com/documentation/speech/speechtranscriber/result), [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory).

## 1. Building blocks (macOS 26.0+ unless noted)

| Type | What it is (Apple's words) |
|---|---|
| `final actor SpeechAnalyzer` | "Analyzes spoken audio content in various ways and manages the analysis session." "The analyzer can only analyze one input sequence at a time." |
| `final class SpeechTranscriber` | "A speech-to-text transcription module that's appropriate for normal conversation and general purposes." This is the new long-form model. |
| `final class DictationTranscriber` | "similar to system dictation features and compatible with older devices". It "uses the same speech-to-text machine learning models as system dictation features do, or as `SFSpeechRecognizer` does when it is configured for on-device operation." It supports `contextualStrings`, custom LMs, and content hints (`farField`, `shortForm`, `atypicalSpeech`). It measures ~4x worse than SpeechTranscriber ([Lyonesse](https://lyonesse.app/blog/macos-27-speech-api-accuracy.html)). |
| `final class SpeechDetector` | VAD. "This module only functions in conjunction with a `SpeechTranscriber` or `DictationTranscriber` module." Results "currently only support error handling from the VAD model." |
| `AssetInventory` | System-managed model download and reservation (see the deployment doc). |
| `AssetInputSequenceProvider`, `CaptureInputSequenceProvider`, `AnalyzerInputConverter` | **macOS 27.0+.** Read audio from a file or asset, read audio from a capture device, and convert buffers to the analyzer format ([Speech updates, June 2026](https://developer.apple.com/documentation/updates/speech)). |

### SpeechTranscriber configuration

`init(locale:transcriptionOptions:reportingOptions:attributeOptions:)` or `init(locale:preset:)`.

- `TranscriptionOption`: only `.etiquetteReplacements` (redaction).
- `ReportingOption`:
  - `.volatileResults`: "Provides tentative results for an audio range in addition to the finalized result".
  - `.fastResults`: "faster but also less accurate".
  - `.alternativeTranscriptions`.
- `ResultAttributeOption`:
  - `.audioTimeRange`: "Includes time-code attributes in a transcription's attributed string".
  - `.transcriptionConfidence`: "Includes confidence attributes in a transcription's attributed string".
- Presets (from Apple's table):

| Preset | volatile | fast | alternatives | audioTimeRange |
|---|---|---|---|---|
| `transcription` | No | No | No | No |
| `transcriptionWithAlternatives` | No | No | Yes | No |
| `timeIndexedTranscriptionWithAlternatives` | No | No | Yes | Yes |
| `progressiveTranscription` | Yes | Yes | No | No |
| `timeIndexedProgressiveTranscription` | Yes | Yes | No | Yes |

No preset gives time ranges plus confidence without alternatives. Biscotti would use the designated initializer: `transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence]`. The WWDC25 video's `.offlineTranscription` preset "does not exist in the shipping SDK — use `.transcription`" ([mac-transcriber research note, 2026-07-27](https://github.com/yrocaz/mac-transcriber/blob/main/docs/research/2026-07-27-apple-speechanalyzer-docs.md)).

**There is no custom vocabulary for SpeechTranscriber.** `AnalysisContext.contextualStrings` and `SFSpeechLanguageModel` are documented under `DictationTranscriber` only ([DictationTranscriber docs](https://developer.apple.com/documentation/speech/dictationtranscriber)). Argmax: "Apple's new `SpeechAnalyzer` (iOS 26) API lacks the Custom Vocabulary feature" ([Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)). This matches Biscotti's current situation (custom vocab is blocked upstream anyway), but it closes the door on Apple as a vocab path.

## 2. Output shape

`transcriber.results` is an `AsyncSequence<SpeechTranscriber.Result, Error>`. "The phrases are sent in order."

`SpeechTranscriber.Result` ([docs](https://developer.apple.com/documentation/speech/speechtranscriber/result)):

| Member | Type | Apple's description |
|---|---|---|
| `text` | `AttributedString` | "The most likely interpretation of the audio in this range." |
| `alternatives` | `[AttributedString]` | "All the alternative interpretations of the audio in this range. The interpretations are in descending order of likelihood." "The array will not be empty, but may contain an empty string". Requires `.alternativeTranscriptions`. |
| `range` | `CMTimeRange` | "The audio input range that this result applies to." |
| `isFinal` | `Bool` | "If `true`, then this result is final. There will be no later result over its range." Equivalent to `resultsFinalizationTime >= range.end`. |
| `resultsFinalizationTime` | `CMTime` | "The audio input time up to which results from this module have been finalized". Usable as a progress signal (`resultsFinalizationTime / duration`), which is what yap does. |

Per-run attributes on `text` (Foundation `AttributeScopes.SpeechAttributes`):
- `TimeRangeAttribute` (`run.audioTimeRange: CMTimeRange?`): "The time range in the source audio corresponding to the associated transcription text."
- `ConfidenceAttribute` (`run.transcriptionConfidence: Double?`): "A confidence level (0–1) of the associated transcription text."
- Helper: `AttributedString.rangeOfAudioTimeRangeAttributes(intersecting:)`.

### What a result looks like in practice

- **One result per endpointed phrase/utterance**, not per fixed window. Third-party code describes it as "Each `Result` is one endpointed segment … `text` carries the model's punctuation and casing" ([palmier-pro Transcription.swift](https://github.com/palmier-io/palmier-pro/blob/d7fe2604/Sources/PalmierPro/Transcription/Transcription.swift)). Without volatile results, "each of which covers its own range of audio without overlapping" ([WWDC25 277](https://developer.apple.com/videos/play/wwdc2025/277/)).
- **Runs ≈ words (per-token), not guaranteed.** Apple's demo highlights "each word as it's played back … whether each run should be highlighted, based on its audioTimeRange attribute" (WWDC25 277). simonw's CLI emits one JSON object per word with `start/end/confidence` ([speech-analyzer-cli](https://github.com/simonw/speech-analyzer-cli)). palmier-pro calls them "per-token TranscriptionWords". finnvoor/yap does not trust run = word: it re-tokenizes with `NLTokenizer(unit: .word)` and merges the `audioTimeRange` of all runs inside each word ([yap AttributedString+Extensions.swift](https://github.com/finnvoor/yap)). **Conclusion:** treat runs as tokens. Group them into words with `NLTokenizer` (or on whitespace) and take first-start / last-end. Whether punctuation gets its own run is not documented.
- **Timestamp quality:** "SpeechTranscriber's word ranges are useful for playback synchronization, but should not be interpreted as precise forced-alignment boundaries around silence." ([simonw/speech-analyzer-cli README](https://github.com/simonw/speech-analyzer-cli)). No quantitative word-timing accuracy study was found. On the legacy API, an Apple engineer confirmed "non-final results do not have accurate timestamps and durations" ([Apple forums 785389](https://developer.apple.com/forums/thread/785389)). Biscotti uses finals only, so this does not apply.
- **Confidence can be missing:** "Confidence is omitted … when Apple does not supply it." ([simonw](https://github.com/simonw/speech-analyzer-cli)). The documented range is 0–1, which matches the `TranscriptSanitizer` threshold of 0.3 semantically. How calibrated it is versus Whisper probabilities is unknown.
- **Sample-accurate time base:** "The timecodes are precise down to an individual audio sample." All operations are scheduled on the audio timeline (WWDC25 277). The buffer path does no conversion "In order to keep `CMTime` values sample-accurate" (per the mac-transcriber note quoting Apple). The file path converts for you.

### Volatile vs finalized for batch input

For files, do **not** request `.volatileResults`. "Normally, the transcriber only delivers finalized results, and none of them replace earlier results." (WWDC25 277). You must still finish the session, or results never complete:
- "To end an analysis session, you must use one of the analyzer's `finish` methods or parameters, or deallocate the analyzer."
- "terminating the input sequence does not generally finish the analysis session" ([SpeechAnalyzer docs](https://developer.apple.com/documentation/speech/speechanalyzer)).
- Pattern: start the results consumer first, then `analyzeSequence(from: file)` → `finalizeAndFinish(through: lastSampleTime)` (or `cancelAndFinishNow()` if nil). The other option is `start(inputAudioFile:finishAfterFile: true)`.
- Missing the finalize call caused a production hang at Lyonesse ([Lyonesse round 1](https://lyonesse.app/blog/apple-speech-api-benchmark.html)).

### Language

- **No language detection.** You pick one locale up front. Argmax's feature table: Language Detection "–" for Apple ([Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)). Mixed-language meetings are not handled; the whole file is decoded as one locale.
- Normalize the locale with `SpeechTranscriber.supportedLocale(equivalentTo:)`. An Apple engineer warned that "arbitrary locales such as `Locale.current` or `Locale(identifier: "en_US")` may not [work], because the exact equality of locales differ depending on how they were created" (as quoted in [mac-transcriber note](https://github.com/yrocaz/mac-transcriber/blob/main/docs/research/2026-07-27-apple-speechanalyzer-docs.md); original Apple forums thread not fetched).

### Diarization

- **None.** Apple's Speech framework has no speaker labels, turns, or embeddings. Argmax lists Speaker Diarization "–" for Apple ([Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)). No WWDC26 addition: the 26 → 27 SDK diff is plumbing only ([Lyonesse](https://lyonesse.app/blog/macos-27-speech-api-accuracy.html)).
- Precedent: Transcripty (macOS) runs Apple's SpeechTranscriber and FluidAudio's diarizer in parallel and "merges them at word granularity … Diarization labels are projected onto each word's audio time range" ([Transcripty](https://gitlab.com/stoicswe/transcripty)). That is the same shape Biscotti would need with SpeakerKit.

## 3. Input path options for Biscotti

Today `InProcessTranscriptionEngine` loads mic + system ADTS-AAC files, merges them to one mono 16 kHz `[Float]` (`AudioMerger`), and hands that array to WhisperKit and SpeakerKit (`Packages/Transcription/Sources/Transcription/InProcessTranscriptionEngine.swift`). For Apple:

1. **Write the merged PCM to a temp WAV/CAF and call `analyzeSequence(from: AVAudioFile)`.** This is the most battle-tested path; yap, verliapp and Lyonesse all use the file path. A third-party note reports the buffer path `start(inputSequence:)` failing with `nilError` on macOS 26.3 while the file path works ("FB22149971, unresolved"; [mac-transcriber note](https://github.com/yrocaz/mac-transcriber/blob/main/docs/research/2026-07-27-apple-speechanalyzer-docs.md); I could not open the Apple forums thread to confirm).
2. **Feed `AnalyzerInput(buffer:)` from the `[Float]`**, converted to `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` (on 27, `AnalyzerInputConverter` does this). No temp file, but this is the path with the reported 26.3 bug.
3. **Pass the raw `.aac` files directly.** Not recommended. The docs say the file path converts formats. But yap issue #27 reports "`SpeechAnalyzer.start(inputAudioFile:finishAfterFile:)` requires uncompressed Linear PCM audio" (an AAC M4A was rejected with `-50`) ([yap#27](https://github.com/finnvoor/yap/issues/27)), while another note says `AVAudioFile` on an MP4 "verified working" on 26.5. The sources conflict. Also, Biscotti needs the mic + system merge first anyway.

Whatever the path, word times come back on the timeline of the audio we feed. If Apple and SpeakerKit both get the same merged 16 kHz signal, their timelines match by construction.

## 4. Field-by-field mapping to `TranscriptResult.swift`

Contract: `Packages/Transcription/Sources/Transcription/TranscriptResult.swift`.

| Contract field | Source on the Apple path | Glue needed | Fidelity |
|---|---|---|---|
| `TranscriptWord.word` | Characters of the runs grouped into a word | Group runs into words (`NLTokenizer(unit: .word)` or whitespace). Decide where punctuation attaches (keep it on the preceding word, as Whisper does). | Good |
| `TranscriptWord.startTime` / `endTime` | `run.audioTimeRange.start` / `.end` (`CMTime.seconds`), first and last run of the word | Convert `CMTime` → `TimeInterval`. Add the offset if we ever feed chunks. | Good for playback. Not forced-alignment precision (simonw). Accuracy vs WhisperKit DTW is unmeasured. |
| `TranscriptWord.probability` | `run.transcriptionConfidence` (0–1), mean over the word's runs | Handle `nil` (sometimes omitted): default to 1.0 or skip the sanitizer rule. Re-validate the `TranscriptSanitizer` 0.3 trailing-word threshold, because calibration is unknown. | Medium |
| `TranscriptWord.speakerID` | — | Our word ↔ SpeakerKit timeline alignment (max-overlap). See the decoupling subtopic for whether `addSpeakerInfo` can take a synthesized WhisperKit `TranscriptionResult`. | Ours |
| `TranscriptSegment.startTime/endTime/text` | `Result.range` + `String(result.text.characters)` give phrase segments. Biscotti's segments are per speaker turn. | Re-segment: split phrases where the word speaker changes (and on long gaps), as `SegmentBuilder` does today from SpeakerKit groups. | Good |
| `TranscriptSegment.speakerID/speakerLabel` | — | From alignment (as today). | Ours |
| `TranscriptSegment.confidence` | Not provided per segment | Mean of word probabilities. The contract already says segment confidence is "unreliable … use word-level". | Derived |
| `TranscriptSegment.noSpeechProbability` | **Not provided** | Fixed `0`. | Lost |
| `TranscriptSegment.words` | Built above | Always non-nil on this path. | Good |
| `TranscriptResult.language` | **No detection.** The locale we passed in. | `locale.language.languageCode?.identifier ?? "unknown"`. If the wrong locale is chosen, the transcript is garbage, with no signal. | Caller-supplied |
| `TranscriptResult.speakerCount`, `speakerEmbeddings` | — | SpeakerKit (unchanged). | n/a |
| `TranscriptResult.transcriptionMethodId` | — | A new method id (e.g. `"apple-v1"`). Note: Apple's model can change under a fixed id, because assets update silently. | Caveat |
| `TranscriptResult.processingDuration` | — | Wall clock (as today). | n/a |

### Alignment with SpeakerKit's speaker timeline

- Apple gives per-word (per-run) `CMTimeRange`s on the input timeline. SpeakerKit diarizes the same `[Float]`. If both get identical audio, no clock drift is possible.
- Things that could hurt alignment:
  - (a) word boundaries that are "not … precise … around silence" (simonw), so edge words near turn changes may mis-assign;
  - (b) possible zero-length or punctuation runs;
  - (c) the absence of `noSpeechProbability` to suppress hallucinated words in silence. Note: no hallucination problem has been reported for Apple; verliapp saw "Apple and Parakeet do not hallucinate on these clips at all", whereas Whisper did ([verliapp](https://github.com/verliapp/stt-benchmark)).
- This is the same alignment work the FluidAudio path needs (the draft spec §4.2 max-overlap rule). The Apple path adds no extra difficulty, apart from the run → word grouping step.

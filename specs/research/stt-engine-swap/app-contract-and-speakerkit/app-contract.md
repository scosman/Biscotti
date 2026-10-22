# The STT contract the app actually consumes

Scope: what Biscotti reads from the transcription output, traced from `Packages/Transcription` up through `Packages/BiscottiKit`. All file references are repo paths at branch `fluid_audio` (HEAD `5f6bcc5`, Oct 2026). Pinned SDK: `argmax-oss-swift` **v1.0.0** (`25c62997…`, `Packages/Transcription/Package.resolved`; manifest says `from: "1.0.0"`).

## 1. Data flow today

```
merged [Float] 16 kHz (AudioMerger)
  ├─ WhisperKit.transcribe(audioArray:, DecodingOptions(wordTimestamps: true)) -> [TranscriptionResult]
  └─ SpeakerKit.diarize(audioArray:) -> DiarizationResult
        diarization.addSpeakerInfo(to: sttResults, strategy: .subsegment) -> [[SpeakerSegment]]
           SegmentBuilder.buildSegments -> [TranscriptSegment]
              TranscriptSanitizer.sanitize -> TranscriptResult  (Codable, crosses XPC as JSON)
                 DataStore.addTranscript -> TranscriptRecord / TranscriptSegmentRecord / TranscriptWordRecord
                    DataStore.mapTranscript -> TranscriptData / SegmentData  (read model for UI + Intelligence)
```

Sources: `InProcessTranscriptionEngine.swift` (`processAudio`, `runSTT`, `runDiarization`, `assembleResult`), `SegmentBuilder.swift`, `TranscriptSanitizer.swift`, `XPCServices/BiscottiTranscriber/main.swift`, `BiscottiKit/Sources/DataStore/DataStore+Phase3_2.swift` (`addTranscript`), `DataStore+ReadModels.swift` (`mapTranscript`).

Key structural fact: **nothing above `Packages/Transcription` imports WhisperKit or SpeakerKit.** BiscottiKit sees only `TranscriptResult` / `TranscriptSegment` / `TranscriptWord`, re-exported via `BiscottiKit/Sources/TranscriptionService/Transcribing.swift` (`@_exported import struct Transcription.TranscriptResult` etc.). The swap is contained in the package.

## 2. The read model is the real contract

`DataStore.mapTranscript` (DataStore+ReadModels.swift L741-775) builds what the UI and the LLM features see. It exposes only:

```swift
public struct SegmentData { id, speakerID: Int?, speakerLabel: String, startTime, endTime, text }
public struct TranscriptData { id, createdAt, speakerCount, segments: [SegmentData], speakerAssignments }
```

Words, probabilities, confidence, noSpeechProbability and language are **not** in the read model.

Consumers of `SegmentData`:
- `MeetingDetailUI/TranscriptListView.swift` — one row per segment; shows speaker chip/label, `startTime` as `MM:SS`, `onSeek(segment.startTime)` for click-to-seek, `text`.
- `MeetingDetailUI/TranscriptContent.swift` — copy-to-clipboard (`speaker  MM:SS\ntext`, drops leading whitespace from `text`), speaker colour keyed on `speakerID`.
- `Intelligence/TranscriptFormatter.swift` — LLM input: collapses consecutive same-`speakerID` segments into turns, trims whitespace, no timestamps.
- `Intelligence/Intelligence.swift` L216 — set of `speakerID`s decides whether speaker-name inference runs.
- `MeetingDetailUI/MeetingDetailViewModel.swift` L1622, `SpeakerMappingSheet.swift` — speaker-ID → Person mapping.
- `DataStore+ReadModels.swift` `scoreMeeting` — search matches lowercased `segment.text`.

## 3. Field-by-field classification

"Source" = where the value comes from today. "Must-have" = the app breaks or degrades visibly without it. "Nice-to-have" = persisted or reserved, but no current reader. "Unused" = never read after persistence (or always constant).

### TranscriptResult

| Field | Source today | Downstream readers | Class |
|---|---|---|---|
| `id`, `createdAt` | package | DataStore record id / version sort | Must-have (package-generated, engine-independent) |
| `transcriptionMethodId` | `MethodResolver` (`"v1"`) | `preferredTranscriptIsStale` (re-transcribe trigger), version list | Must-have (package-generated). A new engine = new method id (e.g. `"v2"`) → existing meetings flagged stale. |
| `language` | `sttResults.first?.language` (Whisper LID) | Persisted on `TranscriptRecord.language`; **no reader**. CLI prints it. | Nice-to-have. `"en"`/`"unknown"` is acceptable. |
| `speakerCount` | `DiarizationResult.speakerCount` (SpeakerKit) | Persisted + mapped to `TranscriptData.speakerCount`; no UI reader found | Nice-to-have; comes from SpeakerKit, not STT. |
| `segments` | see below | everything | Must-have |
| `speakerEmbeddings` | hard-coded `[:]` (`assembleResult` L271) | none (CLI prints if non-empty) | Unused today; reserved for P2 voiceprints. Comes from SpeakerKit, not STT. |
| `processingDuration` | wall clock | not persisted | Unused (diagnostic) |

### TranscriptSegment

| Field | Source today | Downstream readers | Class |
|---|---|---|---|
| `speakerID` | `SpeakerSegment.speaker.speakerId` (SpeakerKit) | UI colour/label, name mapping, LLM turn collapse, Intelligence | Must-have — **diarization output, not STT** |
| `speakerLabel` | `SpeakerInfo.description` → `"Speaker N"` / `"No Speaker Matched"` | UI fallback label, copy, LLM | Must-have — diarization output |
| `startTime` | `SpeakerSegment.startTime` = min word start | Display `MM:SS`, click-to-seek | **Must-have, STT-derived** (word timings) |
| `endTime` | max word end | Persisted, mapped; no UI reader found | Nice-to-have (sanitizer clamps it) |
| `text` | `SpeakerSegment.text` = `speakerWords.map(\.word).joined()` (no separator) | Display, copy, search, LLM | **Must-have, STT-derived.** Quality-critical: punctuation + casing are shown verbatim and fed to the LLM. |
| `confidence` | `transcription.avgLogprob` | **Not persisted** (`addTranscript` skips it) | Unused. Note: under `.subsegment` it is always `0` — see §5. |
| `noSpeechProbability` | `transcription.noSpeechProb` | Persisted on `TranscriptSegmentRecord`; **no reader** | Unused. Always `0` under `.subsegment` — see §5. |
| `words` | `speakerWords` | Persisted (`TranscriptWordRecord`); **never read back**; used inside the package by `TranscriptSanitizer` | Nice-to-have downstream, **must-have inside the package** (SpeakerKit alignment requires words — see `speakerkit-coupling.md`) |

### TranscriptWord

| Field | Source today | Readers | Class |
|---|---|---|---|
| `word` | `WordTiming.word` (Whisper word, **with leading space**) | joined into segment `text` | Must-have (internal) |
| `startTime`, `endTime` | `WordTiming.start/end` (Whisper cross-attention DTW timestamps) | SpeakerKit alignment; segment bounds | **Must-have (internal) — drives speaker attribution** |
| `probability` | `WordTiming.probability` (0–1) | `TranscriptSanitizer` trailing-word filter (`< 0.3` → drop), `deriveConfidence` (no caller found outside tests) | Nice-to-have, but **default must be high (e.g. 1.0), not 0** — see §6 |
| `speakerID` | per-word speaker from SpeakerKit | Persisted only | Unused downstream |

## 4. Implicit expectations (not in the types, but relied on)

1. **Word strings carry their own leading space.** SpeakerKit builds segment text with `joined()` (no separator) — `SpeakerSegment.swift` `text`, and `DiarizationResult.groupWordsIntoSubsegments` uses `currentWords.map { $0.word }.joined(separator: "")`. WhisperKit words start with a space (`splitTokensOnSpaces` keeps the `" "`-prefixed sub-word as a new word, `Sources/WhisperKit/Core/Models.swift` L1255-1277). The app then strips leading whitespace (`TranscriptContent.plainText` `drop(while: \.isWhitespace)`, `TranscriptFormatter` `trimmingCharacters`). An engine emitting bare words (`"hello"`) would produce `"helloworld"` unless glue adds the space.
2. **Times are absolute seconds from the start of the merged buffer** that is also given to SpeakerKit. Any engine that chunks internally must return offset-corrected times.
3. **Punctuation and casing are expected in `text`.** Nothing re-punctuates. The UI, copy, search (case-insensitive) and LLM prompts consume text verbatim. An unpunctuated/lower-case engine works structurally but degrades readability and LLM quality.
4. **Segment granularity = sub-segments split at pauses.** With `.subsegment`, each UI row is a run of words with no inter-word gap > 0.15 s. The LLM formatter re-merges same-speaker runs, so many short rows are fine.
5. **Sanitizer assumptions are Whisper-shaped.** `TranscriptSanitizer` drops segments starting past audio end and clamps ends (Whisper end-of-audio hallucinations), and drops a trailing single-word segment with `probability < 0.3`. Both are harmless for a non-Whisper engine provided `probability` is on a 0–1 scale or defaulted high.

## 5. Finding: `confidence` and `noSpeechProbability` are always 0 in production

`SegmentBuilder` reads `speakerSegment.transcription?.avgLogprob` and `.noSpeechProb`. Under the `.subsegment` strategy (the v1 setting, `MethodResolver.resolveV1`), `speakerSegment.transcription` is not Whisper's segment — it is a **synthetic `TranscriptionSegment` created by SpeakerKit** in `groupWordsIntoSubsegments` with hard-coded `avgLogprob: 0.0` and `noSpeechProb: 0.0` ([`Sources/SpeakerKit/DiarizationResult.swift`](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Sources/SpeakerKit/DiarizationResult.swift) v1.1.1 L241-292; identical code at v1.0.0 L165-215). So every persisted `noSpeechProbability` is 0 and every `confidence` is 0.

This corrects the repo's attribution: `TranscriptResult.swift` and `TranscriptSanitizer.swift` comments, and `specs/research/argmax/README.md` Gotcha 13, say segment confidence is "unpopulated in free SDK v1.0.0". The more precise cause is the `.subsegment` strategy discarding Whisper's segment metadata. (Inference from source; not re-validated on hardware.) Practical consequence: **no engine needs to supply segment confidence or no-speech probability** — the app has never received real values.

## 6. Glue rules for a non-WhisperKit engine (derived from §3–§5)

- `language`: engine value if available, else `"en"` (or `"unknown"`). Nothing reads it.
- `confidence`, `noSpeechProbability`: `0` (parity with today).
- `TranscriptWord.probability`: engine per-word confidence mapped to 0–1 if available; **otherwise 1.0**. A default of 0 would make `TranscriptSanitizer` drop any final single-word segment (threshold 0.3).
- `word`: ensure a leading space on each word except where the language does not use spaces; sub-word tokens must be merged into words.
- Times: absolute seconds, word-level, from the same merged buffer.
- `speakerID`, `speakerLabel`, `speakerCount`, `speakerEmbeddings`: from SpeakerKit — unchanged by an STT swap.

## 7. Other WhisperKit touchpoints in `Packages/Transcription` (beyond STT itself)

| Use | Where | Swap impact |
|---|---|---|
| `AudioProcessor.loadAudioAsFloatArray(fromPath:)` — decodes the recorded files (ADTS AAC etc.) and resamples to 16 kHz mono | `InProcessTranscriptionEngine.loadAudioSamples` | Still available: SpeakerKit depends on the WhisperKit module (see coupling doc), so this keeps compiling even if we stop using WhisperKit STT. Or replace with AVFoundation. |
| `whisperKit.tokenizer` + `DecodingOptions.promptTokens` for custom vocabulary | `runSTT`, `VocabularyFormatter` | Whisper-specific. A new engine needs its own vocab mechanism or none (custom vocab is already blocked/disabled, CLAUDE.md). |
| `WhisperKitConfig(downloadBase:modelRepo:)` + `whisperKitModelsPresent` disk probe + `estimatedDownloadBytes` keyed on Whisper model names | `InProcessTranscriptionEngine`, `Transcriber.modelsPresent` | Must be re-implemented per engine. |
| `TranscriptionMethod.v1` doc + `MethodResolver` | `TranscriptionMethod.swift`, `MethodResolver.swift` | Add a new method id; `ResolvedMethodSettings` currently has Whisper/SpeakerKit-specific fields (`sttModel`, `sttModelRepo`, `enableWordTimestamps`, `diarizationStrategy`). |
| transcribe-cli help text, AI tests' comments | `transcribe-cli/TranscribeCLI.swift`, `Tests/…/AIModelTests.swift` | Cosmetic. |

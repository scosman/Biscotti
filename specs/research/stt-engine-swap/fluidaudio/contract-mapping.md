# FluidAudio → Biscotti `TranscriptResult` Mapping and Required Glue

Inputs:
- The app contract: `Packages/Transcription/Sources/Transcription/TranscriptResult.swift` (`TranscriptWord`, `TranscriptSegment`, `TranscriptResult`).
- Today's assembly: `InProcessTranscriptionEngine.assembleResult` calls `diarization.addSpeakerInfo(to: sttResults, strategy: .subsegment)`, then `SegmentBuilder.buildSegments`, then `TranscriptSanitizer.sanitize`.
- FluidAudio v0.17.7 output: `ASRResult` (TDT: v2/v3/ultra) or `UnifiedAsrManager.TranscriptionWithTimings` (Unified). See [batch-api-and-output.md](./batch-api-and-output.md).
- SpeakerKit source at argmax-oss-swift **v1.1.0** (the version checked out in `Packages/Transcription/.build/checkouts`).

Which fields the app *consumes* above the package is the "App contract" subtopic's job. This doc maps every field.

---

## 1. Two ways to keep SpeakerKit

FluidAudio gives one flat token stream. SpeakerKit's alignment API takes WhisperKit types:

```swift
// SpeakerKit/DiarizationResult.swift (v1.1.0)
public func addSpeakerInfo(to transcription: [TranscriptionResult],
                           strategy: SpeakerInfoStrategy = SpeakerInfoStrategy.subsegment) -> [[SpeakerSegment]]
```

`SpeakerKit/DiarizationResult.swift` does `import WhisperKit`, so SpeakerKit depends on the WhisperKit module. Dropping the WhisperKit package therefore needs more care (that question belongs to the App-contract subtopic). The WhisperKit result types all have **public memberwise inits** (`WhisperKit/Core/Models.swift`):
- `TranscriptionResult(text:segments:language:timings:seekTime:)` (an `open class`)
- `TranscriptionSegment(...)`
- `WordTiming(word:tokens:start:end:probability:)`

### Path A: synthesize WhisperKit types and reuse `addSpeakerInfo` (least new logic)

1. Group FluidAudio tokens into words (§2).
2. Build `WordTiming(word: " " + text, tokens: tokenIds, start: Float(start), end: Float(end), probability: meanTokenConf)`.
3. Wrap the words in one or more `TranscriptionSegment`s (for example, one per sentence using `.`/`?`/`!`, or one per long pause). Set `avgLogprob = 0` and `noSpeechProb = 0`, because Parakeet does not produce them.
4. Wrap the segments in one `TranscriptionResult(language: detectedLanguage, ...)`.
5. Call the existing `addSpeakerInfo(..., strategy: .subsegment)`, then `SegmentBuilder`, then `TranscriptSanitizer`. No changes are needed downstream.

Facts that make Path A work, or bite (verified in SpeakerKit v1.1.0 source):
- `.subsegment` = `.subsegment(betweenWordThreshold: 0.15)`. It flattens all segments' words, re-splits them wherever `curr.start − prev.end > 0.15 s`, and assigns each sub-segment the speaker with the largest frame **intersection**. So how you build segments in step 3 barely matters for speaker assignment. The **word-gap distribution** decides it.
- `SpeakerSegment.text` is `speakerWords.map { $0.wordTiming.word }.joined()`, which joins with **no separator**. WhisperKit words carry a leading space. FluidAudio's `buildWordTimings` **trims** words. If you pass FluidAudio words straight through, the text becomes "Helloworld". **The glue must prefix a space** (or keep the raw piece's leading space).
- Words are dropped if a segment has `words == nil` or empty (`validateWordsInSegment`). Always set `words`.
- **Segment granularity will change.** Each sub-segment becomes one `TranscriptSegment` (`SegmentBuilder` maps 1:1, and SpeakerKit does not merge same-speaker neighbours). The number of segments therefore depends on how often inter-word gaps exceed 0.15 s:
  - TDT (v2/v3/ultra): word end = last token's start + TDT duration (≤ 0.32 s per token, 80 ms quantized). Gaps should resemble real pauses. Not measured.
  - Unified (RNNT): a token's end is its start + one 80 ms frame, back-filled only if the next token is earlier. A word's end is therefore often *early*, and gaps are inflated. **Expect many more, shorter segments**, unless we tune `betweenWordThreshold` or merge adjacent same-speaker segments afterwards. This is an inference from the timing code, and it needs a hardware check.

### Path B: write our own word→speaker aligner over SpeakerKit's speaker timeline

Use SpeakerKit only for `diarize(audioArray:)`, read its speaker segments, then assign each word by maximum overlap (with a nearest-segment fallback). Then build `TranscriptSegment`s ourselves. This is the draft spec's §4.2–4.4 design, originally written for FluidAudio's own diarizer. It is more code and more tests, but it removes the WhisperKit-type coupling and the 0.15 s gap re-splitting. It also lets us control segment granularity directly. Whether SpeakerKit exposes its speaker timeline publicly in a usable form is the App-contract subtopic's question.

---

## 2. Token → word grouping (needed on both paths)

FluidAudio's public `buildWordTimings(from:)` drops confidence. We need our own grouping that keeps it:
- New word when the piece starts with `" "` (FluidAudio has already turned `▁` into a space) or `▁`. Otherwise append.
- Skip `""`, `<blank>`, `<pad>`. Also skip `<|...|>` control tokens defensively (the v3 vocabulary contains 262 of them; I saw no evidence they are emitted on the TDT path).
- Punctuation pieces (`,` `.` `?` `!`) are bare continuation pieces, so they attach to the previous word (`"meeting,"`). This matches Whisper's word convention.
- Edge cases FluidAudio's own merger handles internally (not public): a boundary-marked `▁'`/`▁-` followed by a continuation piece, and bare `'`/`-` joiners (`we'll`, `co-op`). Port the logic or accept rare mis-splits.
- Word start = first piece's `startTime`. Word end = last piece's `endTime`. Word probability = mean (or min) of the pieces' `confidence`.

---

## 3. Field-by-field mapping

### `TranscriptWord`

| Field | Contract | FluidAudio source | Glue | Fidelity |
|---|---|---|---|---|
| `word` | String | Grouped `TokenTiming.token` pieces | §2. Prefix a space if using Path A (SpeakerKit joins with `""`) | Good. Punctuated + cased |
| `startTime` | seconds | First piece `startTime` | None | 80 ms quantized. TDT has a −1 frame emission correction. Unified uses emission time (can be late) |
| `endTime` | seconds | Last piece `endTime` | None | TDT: from the duration head. Unified: provisional +1 frame (often early) |
| `probability` | "Whisper's probability for this word (0.0–1.0)" | Mean of piece `confidence` (full-vocab softmax, [0,1]) | Aggregate (mean or min) | Same scale (linear 0–1), different model. The doc comment says "Whisper's" and needs rewording. `TranscriptSanitizer`'s `< 0.3` trailing-word rule is scale-compatible, but its *calibration* differs (Parakeet softmax probabilities tend to be high). Re-validate the threshold on hardware |
| `speakerID` | Int? | — (none) | From SpeakerKit (Path A: `swt.speaker.speakerId`; Path B: our aligner) | Same as today on Path A |

### `TranscriptSegment`

| Field | Contract | FluidAudio source | Glue | Fidelity |
|---|---|---|---|---|
| `id` | UUID | — | Generated (default init) | n/a |
| `speakerID` | Int? | — | SpeakerKit | Path A: unchanged |
| `speakerLabel` | String | — | SpeakerKit `speaker.description` (Path A) or `"Speaker <n>"` (Path B) | Unchanged on Path A |
| `startTime` / `endTime` | seconds | — (no segments) | First word start / last word end (SpeakerKit does this on Path A) | Depends on word timing (see above) |
| `text` | String | — | Join words (SpeakerKit joins with `""` on Path A; hence the leading-space requirement) | Good |
| `confidence` | "Average log-probability from Whisper"; already documented as unreliable ("often 0") | **Not provided** (only a whole-clip `ASRResult.confidence`, clamped [0.1, 1]) | Set `0` (Path A: `avgLogprob = 0` flows through, the same as today's frequent 0), **or** the mean word probability | Field semantics change (log-prob vs linear). Nothing should depend on it, since the sanitizer already ignores it |
| `noSpeechProbability` | Float | **Not provided** | Fixed `0` | Lost. Today it is "Whisper's no-speech probability". Parakeet does not hallucinate on silence the way Whisper does, so the need is lower (inference) |
| `words` | [TranscriptWord]? | — | Always non-nil | Good |

### `TranscriptResult`

| Field | Contract | FluidAudio source | Glue | Fidelity |
|---|---|---|---|---|
| `id`, `createdAt` | | — | Default init | n/a |
| `transcriptionMethodId` | opaque String | — | New method id (for example `"v2"`) | n/a |
| `language` | "Detected language code (e.g. "en")" | **Not provided.** v3 detects internally but does not expose it. `language:` is only a script-filter *hint*. v2 / Unified / Phonon-2 are English-only | v2/Unified/Phonon-2: hard-code `"en"`. v3/ultra: run `NLLanguageRecognizer` over the text (Apple NaturalLanguage, no new dependency) and fall back to `"unknown"` | Approximate. Meetings that switch languages get one dominant code |
| `speakerCount` | Int | — | SpeakerKit `diarization.speakerCount` (Path A, unchanged) or the count of distinct assigned speakers (Path B) | Unchanged on Path A |
| `segments` | [TranscriptSegment] | — | Path A or Path B | See granularity caveat |
| `speakerEmbeddings` | [Int: [Float]], "Reserved (empty) in v1" | — | Keep `[:]` (SpeakerKit-side concern) | n/a |
| `processingDuration` | wall clock | `ASRResult.processingTime` covers ASR only | Keep measuring wall clock around STT + diarization + merge, as today | n/a |

---

## 4. Other glue we would write

| Item | Why |
|---|---|
| Audio in | Biscotti already builds one merged 16 kHz mono `[Float]`: it loads each file with WhisperKit's `AudioProcessor.loadAudioAsFloatArray`, then merges with `AudioMerger`. Pass that array to `asr.transcribe(samples, decoderState: &state)`. If WhisperKit's loader goes away, FluidAudio's public `AudioConverter().resampleAudioFile(_ url: URL) throws -> [Float]` is the replacement. |
| Decoder state | `var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)`, a fresh one per file. |
| Model directory | Pass `<biscotti models root>/<anything>`. FluidAudio rewrites the last component to `parakeet-tdt-0.6b-v3-coreml` (layout quirk). The presence probe uses `AsrModels.modelsExist(at:version:)`. |
| Model pinning | Set `ModelRegistry.revisionOverrides` to a fixed HF commit, because ASR repos are fetched from `main`. |
| Download progress | Rescale the per-file 0→1 `DownloadProgress.fractionCompleted` across the four model files (or keep stage strings, as today). |
| Error mapping | `ASRError`/`AsrModelsError`/`DownloadError` → existing `TranscriptionError` cases (the draft spec §7 table is accurate against v0.17.7). |
| Transcription progress (optional) | `await asr.transcriptionProgressStream` before calling `transcribe` (TDT only). |
| Sanitizer | Re-check the 0.3 trailing-word threshold against Parakeet's probabilities. The rest (drop segments past the end, clamp end times) still applies. |
| Language | `NLLanguageRecognizer` for multilingual models. |

**What we do *not* need to write:** chunking and seam merging for long audio (FluidAudio owns it), resampling, and model download/retry.

---

## 5. Net assessment

- Everything the contract needs for **word↔speaker alignment** is present: per-word text, start/end at 80 ms resolution, and a 0–1 confidence. TDT (v2/v3/ultra) timestamps are better suited than Unified's because of the duration head.
- **Lost or synthesized:** segment-level `confidence` (already unreliable today), `noSpeechProbability` (lost), and `language` (must be detected ourselves for v3).
- **Smallest-change integration:** Path A. Synthesize WhisperKit `TranscriptionResult`/`TranscriptionSegment`/`WordTiming` and keep `addSpeakerInfo` + `SegmentBuilder` + `TranscriptSanitizer` unchanged. About 100–200 lines of pure, unit-testable glue (my estimate). Watch two things: the leading space on words, and the segment-granularity shift from the 0.15 s gap rule.

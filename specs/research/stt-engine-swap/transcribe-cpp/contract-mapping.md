# transcribe.cpp — Mapping to the App Contract and SpeakerKit Glue

Research date: 2026-10-21. Engine: transcribe.cpp **v0.4.0**, Parakeet family (the only family with word-level timing; see [models-and-output.md](./models-and-output.md)). App contract: `Packages/Transcription/Sources/Transcription/TranscriptResult.swift`. SpeakerKit: `argmax-oss-swift` **v1.0.0** (the version pinned in `Packages/Transcription/Package.resolved`).

## 1. How the app builds a transcript today

`InProcessTranscriptionEngine.assembleResult` (repo):

1. WhisperKit returns `[TranscriptionResult]` (segments with `[WordTiming]`).
2. `diarization.addSpeakerInfo(to: sttResults, strategy: .subsegment)` → `[[SpeakerSegment]]`.
3. `SegmentBuilder` maps each `SpeakerSegment` → `TranscriptSegment` (words from `speakerWords[].wordTiming`, `confidence = transcription.avgLogprob`, `noSpeechProbability = transcription.noSpeechProb`).
4. `language = sttResults.first?.language ?? "unknown"`.
5. `TranscriptSanitizer` drops/clamps segments past audio end and drops trailing single-word segments with mean word probability < 0.3.

SpeakerKit side, from source (`Sources/SpeakerKit/DiarizationResult.swift`, v1.0.0):

```swift
public func addSpeakerInfo(to transcription: [TranscriptionResult],
                           strategy: SpeakerInfoStrategy = SpeakerInfoStrategy.subsegment) -> [[SpeakerSegment]]
```

- `.subsegment` = `.subsegment(betweenWordThreshold: 0.15)` (`SpeakerInfo.swift`). It flattens each segment's `words`, starts a new sub-segment whenever `curr.start - prev.end > 0.15` s, and assigns **one speaker per sub-segment** by maximum frame intersection with diarization turns (falls back to the previous speaker).
- Sub-segment `text` is `currentWords.map { $0.word }.joined(separator: "")` — it relies on Whisper-style words that carry their own leading space.
- Segments without `words` are skipped ("Enable `wordTimestamps` on DecodingOptions").
- WhisperKit's `TranscriptionResult` (open class), `TranscriptionSegment` and `WordTiming` all have **public memberwise initializers** (`Sources/WhisperKit/Core/Models.swift` L447, L574, L622), and `TranscriptionTimings` has a public init with defaults. So we can construct them from any engine's output.

Whether we keep this WhisperKit-typed path or write our own aligner is the "App contract & SpeakerKit decoupling" subtopic's call. This doc shows the glue for the low-change path: **synthesize WhisperKit types and keep calling `addSpeakerInfo`**.

## 2. Field-by-field mapping

Source rows: `transcribe_word {t0_ms, t1_ms, seg_index, first_token, n_tokens, text}`, `transcribe_token {id, p, t0_ms, t1_ms, seg_index, word_index, text}`, `transcribe_segment {t0_ms, t1_ms, first_word, n_words, …, text, speaker_id}`, top-level `full_text`, `detected_language`, timings.

### TranscriptWord

| Contract field | transcribe.cpp source | Fit | Glue |
|---|---|---|---|
| `word: String` | `word.text` | Partial | Text is trimmed: "trimming the word-opener's leading space" (`src/arch/parakeet/model.cpp`). Prepend `" "` for every word (WhisperKit convention, needed by SpeakerKit's `joined(separator: "")`). Punctuation stays attached ("so,"). |
| `startTime` | `word.t0_ms / 1000` | Good | 80 ms resolution (encoder frame). |
| `endTime` | `word.t1_ms / 1000` | Fair | Released builds include the predicted duration of a trailing punctuation token; word ends can drift "up to 560 ms" ([PR #93](https://github.com/handy-computer/transcribe.cpp/pull/93), unmerged). **Glue:** recompute `endTime` as the end of the last non-punctuation token in the word (token rows have `text`), i.e. give punctuation tokens zero duration like NeMo. |
| `probability: Float` (0–1) | none on words; `token.p` per token | Partial | Aggregate the word's tokens (`first_token ..< first_token + n_tokens`), e.g. `min` or mean of `p`. Note: for TDT/RNN-T, `p` is **entropy-based confidence** `1 - H/Hmax`, not a softmax probability (`token_confidence()` in `decoder.cpp`). Range 0–1 but a different scale from Whisper. Exclude punctuation tokens from the aggregate. Requires `timestamps = .token` (or `.auto`). |
| `speakerID: Int?` | — | n/a | From SpeakerKit (unchanged). |

### TranscriptSegment

| Contract field | Source | Fit | Glue |
|---|---|---|---|
| `id: UUID` | — | n/a | Generated. |
| `speakerID`, `speakerLabel` | — | n/a | From SpeakerKit `SpeakerSegment.speaker` (unchanged). |
| `startTime`, `endTime` | Parakeet returns **one segment for the whole clip** ("v1 produces a single segment over the whole clip"); `parakeet-ultra` > 30 s returns one per VAD piece | Poor as-is | Segments come out of SpeakerKit's sub-segmenting (word gaps > 0.15 s + speaker turns), so the engine's segment boundaries barely matter with `.subsegment`. For `.segment` strategy we would need to cut segments ourselves (sentence punctuation + pauses). |
| `text` | — | Derived | SpeakerKit builds it from words (needs the leading-space fix above). Alternative: re-slice `full_text` — not needed. |
| `confidence: Float` (Whisper avg log-prob; documented unreliable) | none | Missing | Already 0 for SpeakerKit sub-segments today (SpeakerKit sets `avgLogprob: 0.0`). Optionally compute `mean(log(p))` over the segment's tokens. No consumer depends on it ("use word-level probabilities" — contract doc comment). |
| `noSpeechProbability: Float` | none | Missing | Set 0 (SpeakerKit sub-segments already set `noSpeechProb: 0.0`). |
| `words: [TranscriptWord]?` | words + tokens | Good | As above. |

### TranscriptResult

| Contract field | Source | Fit | Glue |
|---|---|---|---|
| `id`, `createdAt` | — | n/a | Generated. |
| `transcriptionMethodId` | — | n/a | New method id (e.g. `"v2-parakeet-tdt-0.6b-v2-q8"`) via `MethodResolver`, so re-transcribe knows the engine. |
| `language: String` | `transcribe_detected_language()` | **Missing for Parakeet** | Parakeet never sets it (always `""`, also for v3/ultra). Options: hard-code `"en"` for v2; or run the VoxLingua107 ECAPA LANGID model (`LangIdSession`, Apache-2.0) on a sample; or keep `"unknown"`. |
| `speakerCount` | — | n/a | From SpeakerKit (unchanged). |
| `segments` | — | n/a | From SpeakerKit + `SegmentBuilder` (unchanged). |
| `speakerEmbeddings` | — | n/a | SpeakerKit-only concern (reserved/empty in v1). Unaffected by STT swap. |
| `processingDuration` | wall clock; `transcribe_get_timings()` gives load/mel/encode/decode ms | Good | Unchanged measurement. |

### Other WhisperKit behaviours we lose or gain

- **Lose:** Whisper end-of-audio hallucinations (Parakeet is a transducer and does not hallucinate past audio end in the same way — inference; the sanitizer's clamp stays harmless). Whisper language detection. Custom-vocab prompt (blocked anyway; Parakeet has no vocabulary support yet, [#221](https://github.com/handy-computer/transcribe.cpp/issues/221)).
- **Gain:** native punctuation/casing (v2/v3/ultra), no 30 s window stitching for v2/v3 (single pass), WER improvement (see model-landscape subtopic).
- **New risk:** silent span drops in TDT ([#71](https://github.com/handy-computer/transcribe.cpp/issues/71)); not flagged by any status.

## 3. Glue sketch (low-change path)

```swift
// Inside the XPC service, replacing the WhisperKit STT call.
let model = try Model(path: ggufPath, options: ModelOptions(backend: .auto))
let session = try model.session(SessionOptions(nThreads: perfCoreCount))
let t = try await session.run(samples16kMono, options: RunOptions(timestamps: .token))

func isPunct(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) } }

let words: [WordTiming] = t.words.map { w in
    let toks = t.tokens[Int(w.firstToken) ..< Int(w.firstToken + w.nTokens)]
    let spoken = toks.filter { !isPunct($0.text.trimmingCharacters(in: .whitespaces)) }
    let endMs = spoken.last?.t1Ms ?? w.t1Ms              // zero-duration punctuation
    let conf = spoken.map(\.p).filter { !$0.isNaN }.min() ?? 0
    return WordTiming(word: " " + w.text, tokens: toks.map { Int($0.id) },
                      start: Float(w.t0Ms) / 1000, end: Float(endMs) / 1000, probability: conf)
}
let segment = TranscriptionSegment(start: words.first?.start ?? 0, end: words.last?.end ?? 0,
                                   text: t.text, words: words)
let result = TranscriptionResult(text: t.text, segments: [segment],
                                 language: "en", timings: TranscriptionTimings())
let groups = diarization.addSpeakerInfo(to: [result], strategy: .subsegment)
// SegmentBuilder + TranscriptSanitizer unchanged (re-tune the 0.3 threshold).
```

(Sketch only; names follow the v0.4.0 Swift wrapper: `Transcript.words/tokens`, `Word.firstToken/nTokens/t0Ms/t1Ms/text`, `Token.p/id/t1Ms/text`.)

Notes on the sketch:

- One segment holding all words is fine for `.subsegment`: SpeakerKit flattens and re-splits by word gaps. If we chunk long audio ourselves, produce one `TranscriptionSegment` per chunk with times already offset to file time.
- Word gaps: Parakeet TDT words often abut (gap 0 within fluent speech) because durations cover whole frames. Splits happen at pauses ≥ 160 ms (two frames). Without the punctuation fix, inflated word ends shrink real pauses, so speaker changes right after a comma/period can be missed — the fix is load-bearing for alignment quality.
- Timing accuracy: after the PR #93 fix, v2 word times were within 80 ms max / 3.6 ms mean of NeMo; NeMo's own timestamps are frame-quantized (80 ms). SpeakerKit (pyannote) frame rate is finer, so STT timing (80 ms) is the limiting factor. Inference: adequate for turn-level attribution; not for sub-100 ms precision.

## 4. Long-audio glue choices

| Choice | Pros | Cons |
|---|---|---|
| **parakeet-ultra**, single `run` (v0.4.0) | Bounded memory today; pause-based ≤30 s pieces; multilingual; CC-BY-4.0 | No progress callback; slightly higher LibriSpeech WER than v2 (1.80% vs 1.69%) but better long-form claims; language still not reported |
| **v2/v3 single `run`**, wait for release with [#199](https://github.com/handy-computer/transcribe.cpp/pull/199) | NVIDIA's documented long-audio mode `[256,256]`; linear memory; "multi-hour recordings fit" | Not released as of 2026-10-21; on v0.4.0 a 1 h file runs full attention (est. tens of GB — do not ship) |
| **Own chunking** (e.g. 60–300 s at silence, using our existing mic/system activity labels or Silero VAD role) + per-chunk `run` | Works on v0.4.0 with any variant; gives progress; limits blast radius of span drops | Must offset times and avoid cutting words; more code |

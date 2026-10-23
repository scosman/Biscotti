---
status: complete
---

# Component: `sttlab analyze`

Spec: functional_spec §5. The pure logic is in `STTLabAnalysis` (depends on `STTLabCore` only). The loading of WhisperKit/SpeakerKit types and the speaker alignment are in `STTLabHome` (`AnalyzeInputs.swift`, `SpeakerAlignment.swift`). The command is in `sttlab`.

## 1. Pipeline

The analyze step has two subcommands: `prep` and `final`.

### `sttlab analyze prep`

```
sttlab analyze prep --workspace W --results R --analysis-dir W/analysis
  1. Load inputs (manifest, metas, transcripts) — same as before.
  2. Per meeting with both Apple and Whisper: run TieBreak to find
     disagreement regions, then write disagreement_report.json.
  3. Never touches existing disagreement_decision.json files.
  4. Warns if a decision file's fingerprint is stale.
```

Output per meeting: `<analysis-dir>/<mid>/disagreement_report.json`.

### LLM judging (manual)

Feed each `disagreement_report.json` to an LLM. The LLM writes a
`disagreement_decision.json` in the same directory with one entry per
disagreement (`decision`: `apple_wins` / `whisper_wins` / `both_acceptable` /
`unknown`; `severity`: `high` / `med` / `low`). Must include the
`report_fingerprint` from the report file.

### `sttlab analyze final`

```
sttlab analyze final --workspace W --results R --analysis-dir W/analysis [--out W/report]
  1. Run the core metrics pipeline (WER, timing, speakers, flags, etc.).
  2. Load disagreement reports and decisions per meeting from analysis-dir.
  3. Parse decisions tolerantly (case-insensitive, extra fields ignored,
     warnings for invalid/unknown/missing entries).
  4. Aggregate LLM decisions via LLMJudgementAggregator.
  5. Overlay LLM data onto ReportModel → report.md + metrics.json + transcripts/
```

Build both in release (`swift run -c release sttlab analyze prep …`); the alignment DP is slow in debug.

## 2. Neutral model (`STTLabAnalysis/Model.swift`)

```swift
public enum EngineID: String, Codable, Sendable, CaseIterable { case apple, whisper, reference }

public struct EngineWord: Codable, Sendable, Equatable {
    public var text: String          // display text, with punctuation, no leading/trailing space
    public var start: Double?        // seconds on the merged-audio timeline
    public var end: Double?
    public var confidence: Double?
    public var segmentIndex: Int     // Apple result index / Whisper segment / reference segment or chunk
}
public struct EngineTranscript: Codable, Sendable {
    public var engine: EngineID
    public var words: [EngineWord]
    public var displayText: String   // engine's text: Apple = results' text joined with " ";
                                     // Whisper = words joined; reference = chunk `text` joined with " "
    public var hasWordTimes: Bool    // false when the reference returned no words
}
public struct AlignedWord: Codable, Sendable { public var word: EngineWord; public var speaker: Int? }
public struct AlignedSegment: Codable, Sendable { public var speaker: Int?; public var start: Double; public var end: Double; public var text: String; public var wordCount: Int }
public struct AlignedTranscript: Codable, Sendable { public var engine: EngineID; public var segments: [AlignedSegment]; public var words: [AlignedWord]; public var droppedUntimedWords: Int }
```

Building `EngineTranscript` (`AnalyzeInputs.swift`):

- **Whisper:** for each `TranscriptionResult`, for each segment in order, for each `WordTiming` → `EngineWord(text: word.trimmed, start, end, confidence: probability, segmentIndex: running segment counter)`. Skip words whose trimmed text is empty or matches `^<\|.*\|>$` (special tokens).
- **Reference:** for each chunk in `startSample` order, parse the response. If `words` is present: one `EngineWord` per word, with times + `startSample/16000`, `confidence`, and `segmentIndex` = the index of the response segment whose [start, end] contains the word's midpoint (else the chunk index offset by 10_000). If `words` is missing: split the chunk `text` (or the joined segments' text) on whitespace into untimed words, and set `hasWordTimes = false`.
- **Apple:** `AppleWordGrouper.group(results:)` (§3).

## 3. Apple runs → words (`AppleWordGrouper.swift`)

For each `AppleResult` (`segmentIndex = result.index`):

1. Tokenize `result.text` into whitespace-separated tokens. Keep each token's Character range `[lo, hi)`.
2. For each token, collect the runs whose `[charOffset, charOffset+charLength)` overlaps `[lo, hi)` and that have `timeStart`. The word's `start = min(run start)`, `end = max(run start + duration)`, `confidence = mean(run confidence where present)` (nil if none). If no timed run overlaps, `start = end = nil`.
3. Granularity per run (`RunClass`): `punctuationOnly` (the run text has no letter or digit); `wholeWord` (the run's trimmed range equals one token's range, or equals that token without leading/trailing punctuation); `subWord` (inside one token, but smaller); `multiWord` (overlaps 2 or more tokens); `whitespace` (only whitespace).
4. Anomalies over all timed runs in result order: `zeroLength` (duration ≤ 0); `outOfOrder` (start < previous start − 0.001); `overlapping` (start < previous end − 0.001, and not out of order); `outsideAudio` (start < 0 or end > audioDuration + 0.5); `untimedRun` (a run with letters or digits and no time).

Output: `(words: [EngineWord], runStats: RunStats)`. `RunStats` has the counts per class and per anomaly, and the total runs.

## 4. Normalization (`Normalizer.swift`)

`Normalizer.tokens(for words: [EngineWord]) -> [NormToken]`, with `NormToken { text: String; sourceIndex: Int }` (the index into `words`). Per word, in this order:

1. Unicode NFKC; lowercase (en_US_POSIX); `’ ‘ ʼ` → `'`.
2. Symbols: `%` → ` percent`; `&` → ` and `; `$<number>` → `<number> dollars`; `+` → ` plus `.
3. Hyphens, en/em dashes, `/` → space.
4. Remove every character that is not a letter, a digit, an apostrophe or whitespace. Remove apostrophes at the token edges.
5. Split on whitespace.
6. Contractions (fixed table): `i'm→i am`, `you're→you are`, `we're→we are`, `they're→they are`, `it's→it is`, `that's→that is`, `there's→there is`, `what's→what is`, `let's→let us`, `don't→do not`, `doesn't→does not`, `didn't→did not`, `can't→can not`, `cannot→can not`, `won't→will not`, `isn't→is not`, `aren't→are not`, `wasn't→was not`, `weren't→were not`, `haven't→have not`, `hasn't→has not`, `wouldn't→would not`, `shouldn't→should not`, `couldn't→could not`, `i've→i have`, `we've→we have`, `you've→you have`, `they've→they have`, `i'll→i will`, `we'll→we will`, `you'll→you will`, `it'll→it will`, `i'd→i would`, `gonna→going to`, `wanna→want to`, `gotta→got to`, `okay→ok`. Then remove a remaining trailing `'s` (possessive) and every other apostrophe.
7. Numbers: a token of only digits (after step 4; `1,000` became `1000` there) → `NumberFormatter` `.spellOut` with `en_US`, then step 3 and step 5 on the result (`2024` → `two thousand twenty four`). Ordinals `1st/2nd/3rd/Nth` → `.ordinal` spell-out (`first`). Decimals `3.5` are handled before step 4 (a regex `\d+\.\d+` → `three point five`).
8. Fillers: drop tokens in `{um, umm, uh, uhh, uhm, erm, er, ah, hmm, hm, mm, mhm, mmhmm, uhhuh}`.

All tokens from one source word keep that word's `sourceIndex`. A unit test table covers each rule. The report's caveats section lists the rules (spec §5.7.5).

## 5. Alignment (`Aligner.swift`)

```swift
public enum EditOp: Equatable, Sendable { case match(Int, Int), sub(Int, Int), del(Int), ins(Int) }  // (a index, b index)
public enum Aligner {
    public static func align(_ a: [String], _ b: [String]) -> [EditOp]   // Hirschberg, linear memory
    static func alignNaive(_ a: [String], _ b: [String]) -> [EditOp]     // full matrix, tests only
}
```

- Costs: match 0, substitution 1, insertion 1, deletion 1. Tokens are interned to `Int` ids before the DP.
- Hirschberg: recursive split on `a`'s midpoint. The forward and reverse last rows use `[Int32]` buffers. Base cases: `a.count <= 1` or `b.count == 0` use a small full DP. Tie order in the backtrace and the base case: diagonal (match/sub) before deletion before insertion. Then the op lists of both halves are concatenated.
- `del(i)` = a token of `a` is missing in `b`; `ins(j)` = an extra token in `b`. In WER calls, `a` = the reference and `b` = the hypothesis.
- Test: the total cost and the counts of each op type are equal to `alignNaive` on 200 seeded random pairs (length 0–60, vocabulary of 6). The op sequence can differ only between equal-cost paths. So the test compares costs and counts, and checks the op list is a valid edit script (it replays `a` into `b`).

## 6. Metrics (`Metrics*.swift`)

### 6.1 WER (`WER.swift`)

`WERResult { refWords, substitutions, deletions, insertions, wer: Double? }` with `wer = (S+D+I)/refWords` (nil when refWords == 0). Computed for Apple vs reference, Whisper vs reference, and Apple vs Whisper (Whisper as "ref"; labelled "disagreement rate, not accuracy"). The overall value is pooled: the sum of errors divided by the sum of reference words.

### 6.2 Disagreement regions and tie-break (`TieBreak.swift`)

Inputs: the token lists A (Apple), W (Whisper), R (reference), and the alignments `opsAW = align(W, A)`, `opsRA = align(R, A)`, `opsRW = align(R, W)`.

1. **Regions:** walk `opsAW`. A region is a maximal run of non-`match` ops. Two runs separated by exactly one `match` are merged (so one shared word does not split a phrase). Region = `[w0, w1)` in W and `[a0, a1)` in A (half-open, can be empty).
2. **Map to R:** from `opsRA`, build `refOfA[i]: Int?` (the R index for match/sub) and `insertPointA[i]` (for insertions: the R index of the next aligned token). The same for W. R span of a region = `[min, max+1)` over the mapped indices of both sides. If nothing maps, it is the empty span at the smallest insert point.
3. **Score:** `eA = editDistance(A[a0..<a1], R[span])`, `eW = editDistance(W[w0..<w1], R[span])` (the naive DP; regions are small; a region over 400 tokens uses Hirschberg). `common(X)` = the number of `match` ops between X and R[span].
4. **Class:** `appleMatches` (eA == 0), `whisperMatches` (eW == 0), `appleCloser` (0 < eA < eW), `whisperCloser` (0 < eW < eA), `tiedPartial` (eA == eW > 0 and common(A) + common(W) > 0), `neither` (eA == eW > 0 and no common tokens).
5. Each region also gets the time span `[min start, max end]` of its A and W words (via `sourceIndex`), the three display texts (the source words joined by spaces; R words from the span), the size `max(a1−a0, w1−w0)`, and the class.

Counts per class per meeting and overall. Also the **token-weighted** counts (sum of region sizes), so many small regions do not hide one big one.

Sample (spec §5.2): the 15 largest regions overall, plus 15 random regions (a `SplitMix64` RNG with seed 42, without replacement, from the rest). The sample is in the report with the meeting id, the time (mm:ss), the class, and the A / W / R texts.

### 6.3 Flags (`Flags.swift`)

- `werRatio`: both WERs exist, the smaller one is > 0.02, and the larger / smaller > 2. Detail: both values.
- `droppedStretch(engine)`: for each engine with word times, the gaps between consecutive timed words, including `[0, first start)` and `[last end, duration)`. A gap ≥ 30 s is flagged when each of the other two engines has ≥ 3 timed words with midpoints inside it. (When the reference has no times, only the other local engine is checked, with ≥ 3 words.) Detail: the gap start, end and engine.
- `emptyResult(engine)`: an engine with a completed status and zero words.

### 6.4 Text quality (`TextQuality.swift`)

On each engine's `displayText` and words:

- `punctuationPer100Words`: the count of `. , ? ! ; : …` per 100 words. Sentence count: the number of runs of text ended by `.`, `?`, `!` or `…`, plus a final run without a mark if non-empty.
- `sentenceStartCapitalizedShare`: over the first word of each sentence that starts with a letter.
- `midSentenceCapitalizedShare`: over the other words that start with a letter, excluding `I`, `I'm`, `I've`, `I'll`, `I'd`.
- `fillerCounts`: per filler word (step 8 list), counted on the lowercased words stripped of punctuation. Plus the total, and the rate per 1000 words.

### 6.5 Word timing (`Timing.swift`)

For each engine pair (A–W, A–R, W–R) where both have word times: take the `match` ops of the pair's token alignment and map them to `(sourceIndex X, sourceIndex Y)`. Keep each pair once. Drop pairs where either word has no time. Stats for `ΔStart = startY − startX` and `ΔEnd`:

`TimingStats { pairs, medianAbs, p90Abs, maxAbs, medianSigned }` (percentiles by nearest-rank on sorted values). A pair with the reference but no reference times is `unavailable` (spec §7).

Apple run granularity and anomalies (§3) go into the same section.

### 6.6 Speaker metrics (`SpeakerMetrics.swift`)

Inputs: `AlignedTranscript` per engine (from §7), and `opsAW` for the word matches.

- **Time agreement (A vs W):** a 10 ms grid over `[0, duration)`. The label of an engine at a grid point = the speaker of the aligned segment that contains it (nil if none). `agreement = equal / both labelled`, plus `coverageA`, `coverageW` (the share of grid points labelled). The speaker ids need no mapping: both use the same diarization.
- **Word agreement (A vs W):** over the `match` pairs that both have a speaker: the share with an equal speaker.
- If the reference has times: the same two numbers for A vs R-aligned and W vs R-aligned. This is a third view; the report says it uses the same diarization.
- **Segments:** per engine, the count of aligned segments, length stats in seconds and in words (median, p90, max). **Turns** = merges of consecutive segments with the same speaker; speaker changes = turns − 1.
- **Disagreement sample:** contiguous runs of matched word pairs with different speakers. The 20 longest runs, with the time, words, speaker A, speaker W, and the nearest diarization boundary (the closest segment start or end in the saved diarization to the run's start).

## 7. Speaker alignment (`STTLabHome/SpeakerAlignment.swift`)

```swift
public enum SpeakerAlignment {
    public static func align(_ t: EngineTranscript, whisperRaw: [TranscriptionResult]?,
                             diarization: DiarizationResult, audioDuration: Double) -> AlignedTranscript
    static func bridge(_ t: EngineTranscript) -> (results: [TranscriptionResult], dropped: Int)
}
```

- Whisper: use `whisperRaw` as-is (the production input).
- Apple and reference: `bridge` groups the timed words by `segmentIndex` (in first-appearance order) into `TranscriptionSegment(id: n, start: first.start, end: last.end, text: words joined by " ", words: [WordTiming(word: " " + text, tokens: [], start:, end:, probability: Float(confidence ?? 1.0))])`. Then `[TranscriptionResult(text: all, segments: segs, language: "en", timings: TranscriptionTimings())]`.
- Then `diarization.addSpeakerInfo(to: results, strategy: .subsegment)` → `ProductionAssembly.transcriptResult(from: groups)` (a copy of `SegmentBuilder`) → `TranscriptSanitizer.sanitize(_, audioDuration:)` → map to `AlignedTranscript`. Each `AlignedWord` keeps its `EngineWord` text (trimmed) and the times from the `TranscriptWord`.

## 8. Report (`Report/`)

`ReportModel` (Codable) is written as `metrics.json`. `MarkdownRenderer.render(_:) -> String` writes `report.md`:

1. **Run summary:** the bundle id; for each machine the chip, RAM and OS (home from the Whisper outputs, runner from `run.json`); the reference model, provider(s), ZDR flag and total cost; the meetings, with a status table per engine (completed / failed / not run / unsupported locale).
2. **Summary table** (one row per engine): pooled WER vs reference; LLM wins (high/med/low/total); median RTF (audio / wall) with the machine name; median |ΔStart| vs reference (and vs Whisper for Apple); speaker agreement with the other local engine (time).
3. **Per-meeting table:** id, duration, speakers, WER A, WER W, A–W disagreement, LLM A wins/W wins/both-ok/unknown, high-severity losses per engine, median |ΔStart| A–W, speaker agreement, flags.
4. **Sections:** §5.1 speed; §5.2 accuracy (S/D/I tables, LLM Judgement section with decision table and Mistakes That Matter, flags); §5.3 text quality; §5.4 timing; §5.5 speakers; §5.6 other.
5. **Caveats:** cross-machine speed; the reference is not ground truth; normalization rules; alternatives were on for Apple; the Apple asset version is unknown (assets update silently); every failure.

No verdict text. `transcripts/<mid>/{apple,whisper,reference}.txt` (display text) and `transcripts/<mid>/{apple,whisper,reference}.speakers.md` (aligned segments as `[mm:ss] Speaker N: text`) let the user read the transcripts.

Missing data never crashes the report. A metric that cannot be computed is shown as `n/a` with a short reason (`no reference word times`, `apple not run`, …).

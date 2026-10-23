# LLM Judgement of Apple vs Whisper Disagreements (Run 1)

WER says how far each engine is from the reference. It does not say which mistakes matter for Biscotti. So every place where Apple and Whisper disagree was judged by an LLM.

## Method

1. **Regions.** `sttlab analyze prep` aligns Apple and Whisper word sequences and groups each run of differing words into one *disagreement region*: 7,131 regions in 16 meetings. Each region in `disagreement_report.json` has the Apple, Whisper and reference text, times, a few words of context on each side, and the judge instructions.
2. **Judges.** LLM agents (Claude Opus 5.5), one agent per batch of up to 250 regions (38 batches). Prompt: `experiments/STTLab/scripts/judge/prompts/region_judge.md`.
3. **Decision per region:** `apple_wins`, `whisper_wins`, `both_acceptable` (the difference does not matter for meeting notes: contractions, number format, punctuation, fillers), or `unknown`.
4. **Severity of the losing engine's mistake**, for a meeting recorder whose transcripts feed summaries, search and action items:
   - `low`: minor, unlikely to matter.
   - `med`: could hurt search or a summary (wrong name, wrong technical term, dropped short clause).
   - `high`: changes meaning, wrong number that matters, drops a substantive sentence, or hallucinated text.
5. **Merge.** `merge_decisions.py` writes one `disagreement_decision.json` per meeting. `sttlab analyze final` reads them into the report.
6. **Mistake categories.** All 1,880 med/high wins were then categorized by the type of the loser's mistake (`categorize.py`, prompt `categorize_mistakes.md`).

During judging we found and fixed an analyzer bug (WhisperKit word pieces such as a number and its `,000` were split, so Whisper was blamed for errors it did not make). After the fix, `analyze prep` was re-run (7,189 → 7,131 regions). All 7,131 regions have a decision: 6,958 kept their first judgement by content match, and the 173 regions that changed were judged again.

## Results

| Decision | Low | Med | High | Total |
|---|---|---|---|---|
| Whisper wins (Apple's mistake) | 2,192 | 1,159 | 142 | 3,493 |
| Apple wins (Whisper's mistake) | 2,187 | 517 | 62 | 2,766 |
| Both acceptable | — | — | — | 585 |
| Unknown | — | — | — | 287 |

- **Mistakes that matter (med + high):** Apple 1,301, Whisper 579. Apple makes about **2.2x** as many.
- **High severity only:** Apple 142, Whisper 62 (2.3x).
- **Low severity is a tie** (2,192 vs 2,187), but see the caveat below: many "Apple wins" at low severity are only filler words that Whisper drops.
- Whisper wins more regions in 14 of 16 meetings. Apple wins more in m09 (154 min, 10 speakers, much informal talk) and m15. See `report_stats.md` → Per-Meeting Results.

## Mistakes That Matter, by Type

Each med/high win was put into one category by the type of the losing engine's mistake (LLM agents, prompt `categorize_mistakes.md`).

| Category | Apple med | Apple high | **Apple total** | Whisper med | Whisper high | **Whisper total** |
|---|---|---|---|---|---|---|
| Technical term (jargon, product / tool names, acronyms) | 688 | 90 | **778** | 70 | 3 | **73** |
| Meaning change (common word replaced) | 266 | 11 | **277** | 95 | 3 | **98** |
| Dropped content | 75 | 8 | **83** | 263 | 39 | **302** |
| Garbled phrase | 53 | 20 | **73** | 19 | 3 | **22** |
| Person name | 40 | 5 | **45** | 17 | 2 | **19** |
| Number or version | 36 | 7 | **43** | 45 | 8 | **53** |
| Hallucination | 1 | 1 | **2** | 8 | 4 | **12** |
| **All** | 1,159 | 142 | **1,301** | 517 | 62 | **579** |

- **Technical terms are the gap.** They are 60 % of Apple's mistakes that matter (778 of 1,301), against 73 for Whisper. **Without technical terms, the two engines are about equal: Apple 523, Whisper 506.**
- **Apple's other weak point is meaning change** (277 vs 98): a common word heard as a different common word.
- **Whisper's main weak point is dropped content** (302 vs 83), and nearly all its hallucinations (12 vs 2).
- **Numbers and versions are about equal** (Apple 43, Whisper 53), but the errors differ: Apple drops decimal points; Whisper more often drops the number.

## Patterns (in general terms)

- **Apple: domain vocabulary.** Apple's main failure is technical terms: AI-tooling jargon, product and framework names, git terms, acronyms. They often become a common English word that sounds similar. The single most frequent domain term in these meetings (593 uses in the reference transcripts) was written correctly by Apple 112 times (19 %) and by Whisper 498 times (84 %).
- **Apple: version numbers.** Apple often drops the decimal point in version numbers (a "four point one" version becomes a two-digit integer) and drops model-name prefixes. Whisper more often drops the number. The counts are about equal.
- **Apple: names.** People's names are garbled more often than by Whisper.
- **Whisper: deletions.** Whisper's main failure is dropping content: short phrases, back-channel replies, and sometimes whole sentences. Pooled deletions vs the reference: Whisper 7,442, Apple 5,313.
- **Whisper: hallucination over silence.** Whisper writes repeated stock phrases over long silences (end of meetings, the meditation recording). These are rare but high severity.
- **Both:** fast or overlapping speech and informal banter are hard for both engines.

## Caveats

- **Filler words.** The first round of judges did not all treat a dropped filler word or stutter the same way: some marked it `both_acceptable`, some a low-severity win for the engine that kept it (usually Apple). The re-judge prompt is strict (`both_acceptable`). So low-severity counts are not reliable; med + high are.
- **The reference is not ground truth.** It is the most accurate of the three on this data (see `reference_quality.md`), but judges could also overrule it. m13 is a weak meeting for the reference.
- **One judge per region.** No inter-judge agreement was measured.
- **One person's meetings.** Most meetings are technical software / AI-tooling discussions in English (en_US). This is the worst case for Apple's vocabulary weakness; non-technical meetings may show a smaller gap.

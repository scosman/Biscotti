# Apple SpeechTranscriber Validation — Results Overview

Run 1: 2026-10-23 on macOS 26.5.2. Run 2 (re-test on macOS 27.0.1): 2026-10-23, see `macos27.md`. Code: `experiments/STTLab` (branch `fluid_audio`). Spec: `../functional_spec.md`, `../architecture.md`.

## Question

Can Apple `SpeechTranscriber` (macOS 26+) replace or sit beside our WhisperKit pipeline as a Biscotti transcription engine? We measured, on real Biscotti meetings:

1. Speed.
2. Where Apple and Whisper disagree, and which one is right.
3. Which local engine is closer to a strong cloud model (the reference).
4. Memory.
5. Whether Apple's word timings work with SpeakerKit speaker alignment.

## What Was Run

| Item | Value |
|---|---|
| Meetings | 16 real Biscotti recordings (mic + system audio merged to mono 16 kHz), chosen by hand from proposed short (~30 min) and long (~60 min) buckets |
| Audio | 13.4 h total; 29–154 min per meeting; 2–10 speakers; English (`en_US`) |
| Content | Mostly technical software / AI-tooling work meetings; one guided-meditation class (m13); one long informal multi-party call (m09) |
| Apple engine | `SpeechTranscriber` (macOS 26.5.2), alternatives on, runner app `STTLabRunner` |
| Whisper engine | WhisperKit `openai_whisper-large-v3-v20240930_626MB` (Biscotti production settings), argmax-oss-swift 1.0.0 |
| Diarization | SpeakerKit (production settings), run once; both engines' words are aligned to the same diarization |
| Reference | `microsoft/mai-transcribe-2` via OpenRouter, ZDR on, 300 s chunks cut at quiet points; total cost $1.34 |
| Runner Mac (Apple) | Apple M2, 16 GB, macOS 26.5.2 |
| Home Mac (Whisper, diarization, analysis) | Apple M4 Pro, 48 GB, macOS 15.6.1 |
| LLM judges | Claude Opus 5.5 agents (region judging, mistake categories, blind reference check) |

Pipeline: `select` → `confirm` → `bundle` → home engines (Whisper, diarization, reference) → runner app on the macOS 26 Mac (Apple) → `analyze prep` → LLM judging → `analyze final`. See `how_to_retest.md` and `experiments/STTLab/NOTES.md`.

## Headline Results

| Measure | Apple | Whisper | Notes |
|---|---|---|---|
| WER vs reference (pooled, 126,910 ref words) | 9.9 % | **9.3 %** | Whisper lower in 14 of 16 meetings |
| Substitutions / deletions / insertions | 5,686 / 5,313 / 1,577 | 3,237 / 7,442 / 1,161 | Apple substitutes; Whisper deletes |
| LLM: mistakes that matter (med + high) | 1,301 | **579** | Apple about 2.2x more; see `llm_judgement.md` |
| LLM: high-severity mistakes | 142 | **62** | |
| LLM: med + high, technical terms excluded | 523 | 506 | About equal; technical terms are 778 of Apple's 1,301 |
| Speed (median real-time factor) | **65x** (M2) | 15x (M4 Pro) | Cross-machine; Apple is about 4x faster on a slower chip |
| Memory (engine process peak) | **34–58 MB** + 34–65 MB system `localspeechrecognition` | 298–868 MB | SpeakerKit adds 0.7–2.4 GB for both |
| Word timing vs Whisper (median / P90 \|Δstart\|) | 0.08 s / 0.28 s | — | |
| Word timing vs reference (median / P90 \|Δstart\|) | 0.10 s / 0.42 s | 0.10 s / 0.32 s | |
| Speaker agreement with reference (time) | **98.8 %** | 97.9 % | Same diarization; only the words differ |
| Speaker agreement Apple vs Whisper | 97.4 % time, 98.1 % words | | |
| Apple result runs that are whole words | 100 % (119,051 of 119,054) | | No sub-word or multi-word runs, so alignment works |
| Stability | 16 / 16 completed | 16 / 16 completed | Reference also 16 / 16 |
| Blind readability score (1–5) | 2.88 | 3.25 | Reference 3.69; see `reference_quality.md` |

## What the Results Say

- **Accuracy: Whisper is better, and the gap is technical vocabulary.** Overall WER is close (9.9 % vs 9.3 %), but the LLM judges found about twice as many mistakes that matter in Apple's output (1,301 vs 579). Technical terms are 778 of Apple's 1,301; **without them, the engines are about equal (523 vs 506)**. The most frequent domain term in these meetings was right 19 % of the time for Apple and 84 % for Whisper. See the category table in `llm_judgement.md`.
- **Whisper's own weak points:** dropped content (302 med/high vs 83 for Apple), and rare but severe hallucinations over long silence. Number errors are about equal (Whisper 53, Apple 43; Apple drops decimal points, Whisper drops numbers).
- **Speed and memory: Apple is far better.** About 4x faster on an older chip, and 3–10x less engine memory.
- **Integration: Apple works with SpeakerKit.** Word runs are whole words with good timings, and speaker agreement with the reference is slightly better than Whisper's.
- **Readability: neither local engine matches the reference.** Whisper reads smoothest (it removes fillers) but sometimes falls into long lowercase, unpunctuated stretches. Apple is the hardest to read, mostly because of garbled terms.
- **The reference is a good reference.** In a blind check it ranked first in 49 of 64 windows and never last (`reference_quality.md`). The exception is the meditation recording (m13).

## Re-Test on macOS 27 (Run 2)

The same bundle was run again on the same M2 Mac after its upgrade to **macOS 27.0.1**, with the same runner build. Apple's text output was **identical** to macOS 26.5.2 (all 38,461 results, alternatives and confidence values). So all accuracy results above also apply to macOS 27.0.1. Only two things changed:

- **Better timestamps.** macOS 27 trims leading silence from result time ranges. Apple vs reference P90 |Δstart| went from 0.42 s to 0.30 s, and Apple speaker agreement with the reference from 98.8 % to 99.3 % (time).
- **Higher process memory.** 55–195 MB, rising over the session (macOS 26: 34–58 MB). It is still well below Whisper. Check for growth in a long-lived process.

The `SpeechTranscriber` model is a system-managed asset per language, with no version API, so we cannot prove that macOS 27 has the same model. The system reported no asset update. Details: `macos27.md`.

**Caveat on scope:** these are one person's meetings, mostly technical, in English. That is the hardest case for Apple's vocabulary weakness. Non-technical meetings and other languages were not tested. Custom vocabulary was not tested for either engine (Whisper's is blocked by an upstream SDK bug; whether Apple's `SpeechAnalyzer` contextual strings work with `SpeechTranscriber` is unverified).

## Issues Found During the Run

Fixed (committed with the analyzer):

- `sttlab select` crashed on `String(format:)` with `%s`.
- Reference segment indices collided across chunks.
- Apple result runs with a leading space were misclassified (they are whole words).
- WhisperKit word pieces with no leading space (thousands separators, decimals, `%`, hyphen suffixes) were treated as separate words, which blamed Whisper for errors it did not make. Fixed before the final numbers.

Open:

- **m09 reference speakers:** `reference.speakers.md` was not written for m09, so reference speaker-agreement numbers exclude m09. Not investigated.
- **Whisper lowercase stretches:** in 4 of 16 style windows, Whisper produced long unpunctuated lowercase stretches. Check whether production post-processing hides this.
- **Max timing delta:** the maximum |Δstart| between Apple and Whisper is 328 s. It probably comes from long hallucination stretches matched across silence; medians are not affected.
- **Low-severity win counts** are not reliable (filler-word inconsistency in the first judging round).

## Files in This Folder

| File | Contents |
|---|---|
| `overview.md` | This summary |
| `llm_judgement.md` | Region judging method, results by severity, mistake categories, patterns |
| `reference_quality.md` | Blind check of the reference: accuracy ranking and style scores |
| `how_to_retest.md` | How to re-run (new macOS, new model) and compare with run 1 |
| `macos27.md` | Run 2: the macOS 27.0.1 re-test and what changed |
| `report_stats.md` | Run 1: the `analyze final` report with all speech-quoting sections removed |
| `metrics_stats.json` | Run 1: the machine-readable metrics with all text fields removed |
| `run2-macos27/` | `report_stats.md` and `metrics_stats.json` for run 2 |

Meeting audio, transcripts, disagreement reports and judge work stay in the private workspace (`~/STTLabData/run1`; Apple results in `bundle-results-macos26/` and `bundle-results-macos27/`) and are not committed.

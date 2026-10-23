# Re-Test on macOS 27 (Run 2)

Run date: 2026-10-23. Same 16 meetings, same audio bundle, same runner app build, same Mac as run 1. Only the OS changed: macOS 26.5.2 (25F84) → **macOS 27.0.1 (26A434)**. Whisper, diarization and the reference are reused from run 1.

Full stats: `run2-macos27/report_stats.md` and `run2-macos27/metrics_stats.json` (no meeting content).

## Result: Same Recognition Output

The en_US `SpeechTranscriber` output on macOS 27.0.1 is **identical in text** to macOS 26.5.2 (`experiments/STTLab/scripts/compare_apple_runs.py`):

| Item | macOS 26.5.2 vs 27.0.1 |
|---|---|
| Results (final segments) | 38,461 on both, same count in each meeting |
| Result text | Identical (38,461 of 38,461) |
| Alternative texts | Identical (38,461 of 38,461) |
| Word runs and confidence values | Identical (119,054 of 119,054) |
| Disagreement regions (`analyze prep`) | 7,131 on both; all 7,131 match run 1 decisions by content |

So **every accuracy result from run 1 applies to macOS 27.0.1 unchanged**: WER (Apple 9.9 %, Whisper 9.3 %), LLM decisions (Apple 1,301 med/high mistakes, Whisper 579), and the mistake categories (technical terms are the gap). No new LLM judging was needed.

## What Changed

| Measure | macOS 26.5.2 | macOS 27.0.1 | Note |
|---|---|---|---|
| Result time ranges | — | 6,580 of 38,461 results start later (most often by exactly 0.96 s); the end time does not change | macOS 27 trims leading silence from result ranges |
| Word runs whose start moved > 0.1 s | — | 6,584 of 119,054 (5.5 %) | |
| Apple vs Whisper, P90 \|Δstart\| | 0.28 s | **0.24 s** | Median unchanged (0.08 s) |
| Apple vs reference, P90 \|Δstart\| | 0.42 s | **0.30 s** | Median unchanged (0.10 s) |
| Speaker agreement Apple vs Whisper (time / words) | 97.4 % / 98.1 % | **98.0 % / 98.2 %** | Same diarization |
| Speaker agreement Apple vs reference (time / words) | 98.8 % / 99.3 % | **99.3 % / 99.5 %** | |
| Median RTF (M2) | 65.4x | 67.6x | About 3 % faster; probably within run-to-run noise |
| Apple process peak footprint | 34–58 MB (first meeting 38 MB) | 55–195 MB (first meeting 55 MB) | Rises over the session; see below |
| System `localspeechrecognition` peak | 34–65 MB | 34–74 MB | About the same |

- **Timings are better.** With the leading silence trimmed, Apple's word times are closer to both Whisper and the reference, and speaker alignment improves a little. This is a small gain for SpeakerKit alignment.
- **Memory in our process is higher and grows.** On macOS 27 the runner's footprint goes up across the 16 meetings in one session (55 MB on the first meeting, up to 195 MB later). On macOS 26 it stayed at 34–58 MB. The runner code is the same, so the growth comes from the framework on macOS 27, or from how our runner code interacts with it. It is still far below Whisper (298–868 MB). **Open:** check for growth in a long-lived Biscotti process that transcribes many meetings.

## Was This a New Model?

Probably not a new model, and we cannot fully confirm it:

- The `SpeechTranscriber` model is a **separate, system-managed asset**, not part of the OS image and not the Dictation model. The system installs and updates it through `AssetInventory`. Assets are **per language**: on this Mac, 9 English locales (en_US, en_GB, en_AU, ...) were installed together and no other language, so one English asset probably serves all `en_*` locales.
- At the start of the run, the runner asks `AssetInventory.assetInstallationRequest(supporting:)`. On macOS 27 it returned no request: the system considered the installed asset current. Apple gives no API for the asset version, and no supported way to force a new download (`release(reservedLocale:)` only removes our app's claim on the asset).
- We found no Apple announcement of a new `SpeechTranscriber` model for macOS 27. The only confirmed new Speech API in the 27 SDK is file and video input (`AssetInputSequenceProvider`, `AnalyzerInputConverter`).

**Conclusion:** on macOS 27.0.1 (as of 2026-10-23), the en_US model output is the same as on macOS 26.5.2. A later macOS point release or a background asset update can change this, and each language can change separately. Re-test when one arrives (`how_to_retest.md`); if the text is identical again, a re-test takes about 15 minutes and needs no LLM judging.

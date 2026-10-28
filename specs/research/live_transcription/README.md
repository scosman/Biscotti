# Live Transcription: Engine Experiment

The `live_transcript` project's phase 5 replay experiment. It measured three live engines on public meeting audio at real-time speed and picked the engine and settings that `LiveTranscriptionDefaults` holds.

**Decision (2026-10-24):** live captions use `openai_whisper-small`, unprompted (`LiveDecoderPrompt.none`), two-track, one decode per track every 1 s. No option passed every gate as frozen. small is the only option in a latency tier (the slower one), it held it for 45 minutes, and it runs on macOS 15. Its cost is critical words: it keeps 84.1% of names, numbers and negations against 92.5% for the final pass, and names are its weakest category (77.8% against 92.6%). Live text has no custom vocabulary with either engine: live Whisper decodes unprompted, and SpeechAnalyzer's contextual strings changed nothing measurable. See [Recommendation](#recommendation) and [Follow-ups](#follow-ups).

Raw results and the overnight reports stayed on the Mac that ran them; they are not in the repo.

## Method

### Machine

One Mac: MacBook Pro (MacBookPro18,2), Apple M1 Max, 64 GB, macOS 26.6.2 (25G83), on AC power, Low Power Mode off for every run. No other Mac was measured.

### Fixtures

AMI Meeting Corpus 1.6.2, individual headset channels. Clips were chosen from the AMI word and named-entity annotations only, before any option ran: 3-minute windows on a 60 s grid, scored for longest turn, speaker changes, overlap, interjections, numbers, negations, named entities and speech density. No clip was chosen by how an option did on it.

| Split | Clips |
|---|---|
| Smoke | `smoke` (ES2011a, 90 s) |
| Calibration | `cal-es2011a-long-turn`, `cal-es2011a-fast-turns`, `cal-is1003b-sparse`, `cal-is1003b-numbers`, `cal-ts3010a-sparse-long-turn`, `cal-ts3010a-negations` |
| Validation | `val-es2009a-long-turn`, `val-es2009a-fast-turns-names`, `val-ib4003-numbers`, `val-ib4003-names-negations`, `val-ts3012a-long-turn`, `val-ts3012a-sparse` |
| Soak | `soak` (TS3006d, 45 min) |

Validation clips come from meeting series that calibration does not use. The mic track is each clip's most talkative speaker; the system track is the other headsets summed. Critical words are the annotated person, place and organization names, numbers and negations.

- Clip list: `Tools/live_bench/clips.json` on the reference branch, SHA-256 `b8cf0e5f2f7521eaa0a493c7ecc0169f4b8cde34aa8ce485b08606ecdc17f9d6`.
- Fixture lock: `Tools/live_bench/fixtures.lock.json` on the reference branch, SHA-256 `14780f8fee507a06f252ae834af9e38d7216987d1a2ff27e5c2ebf5320adb3c8`. Each headset is scaled so its speaker's annotated speech, over the whole meeting, sits at -26 dBFS (ITU-T P.56 active speech level); the gains are in the lock.

### Harness

The harness is kept on a separate reference branch, [`live-transcript-bench`](https://github.com/brainstencil/Biscotti/tree/live-transcript-bench), not in the app's source; its `Tools/live_bench/README.md` says how to fetch the fixtures and run it. `live-bench` (a Swift executable in `Packages/Transcription` there) drives the same session code the app ships, paced in real time, with a simulated call load (2 threads at 60% duty) on every gated run. `Tools/live_bench` scores the runs and writes the reports. Recording safety is measured by the writer integration test in `AudioCaptureTests`, not here. Latency is session-result latency; the app adds XPC delivery, merging and rendering. Whisper runs use `LiveLanguage.english` and SpeechAnalyzer runs `en-US`.

The gated runs ran unattended overnight on 2026-10-24 from the frozen harness (source fingerprint `38acb15d02d5`), through `Tools/live_bench/overnight.py`: 41 steps, from 03:47 to 15:14. Options were interleaved and validation ran twice, the second round in reverse order, so background load and heat drift do not favor one option. Models: `openai_whisper-large-v3-v20240930_626MB` and `openai_whisper-small` from `argmaxinc/whisperkit-coreml`, on argmax-oss-swift 1.1.0; manifest model SHA-256 `7ab4b8fa32f0` and `d9ed43f36277`.

### Frozen thresholds

From `GATES` in `Tools/live_bench/report.py`, frozen before any option was compared:

| Gate | Passes when |
|---|---|
| Latency | 95% of words shown within 3 s of being spoken and settled within 5 s. 95% within 5 s and 8 s is the "slower tier". |
| Accuracy | WER at most 20%, at most 3 points over the final pass on the same clips, and at least 95% of critical words kept. |
| Endurance | Over the 45-minute soak: lag growth at most 5 s, first-display growth at most 5 s, no overflow gaps, added memory under 3 GB, no more than 60 s at a serious heat level. The memory limit is set for a 16 GB Mac. |
| Recording safety | Measured by `AudioCaptureTests`. |

### Quiet and busy rules

- **Before each run** the runner waits until the median CPU idle over 30 s is at least 67%: the 50% busy limit, plus the share of the CPU that the simulated call load takes (2 threads x 60% / 10 cores), plus 5 points. The check runs before `live-bench` starts the call load, so the call load's share is added back.
- **After each run,** a run is busy and left out of the gates when its 30 s baseline (call load running, engine not yet loaded) had a median CPU idle under 50%, when it started in Low Power Mode, or when it recorded no CPU idle. The load during the replay includes the engine's own work, so it is shown but never excludes a run.
- **Why CPU idle, not the load average.** The load average counts runnable threads. Spotlight and `mediaanalysisd` run at background priority, which on Apple silicon uses only the two efficiency cores, so their queue raises the load average while the performance cores stay idle. At night `mds_stores`, `corespotlightd` and `mediaanalysisd` kept it at 15 to 20 for hours while the CPU stayed 65 to 75% idle. A wait on the load average started no run in 45 minutes.

### The night

- All 41 steps finished on the first attempt. None timed out, failed to score or was retried.
- No run was busy. Every baseline had a median CPU idle of at least 61.6%. The first runs (own load and validation round 1, 03:48 to 05:12) had baselines of 62 to 77% idle and a load average of 2 to 27, while Spotlight indexed; from 05:32 on, baselines were mostly 70 to 87% idle.
- Power: AC, Low Power Mode off, before every run.
- The SpeechAnalyzer variant for the soak and the back-to-back arm was chosen by the runner's fixed rule (better latency tier, then accuracy, then the lower of its shown-within-3 s and settled-within-5 s shares): fast results on, because both variants failed both gates and fast results settled more words within 5 s (76.3% against 58.5%).

## Three defects found before the comparison

The first real runs found three defects that made any comparison meaningless. They were fixed before options were compared.

1. **WhisperKit prompts switch off timestamp rules (argmax-oss-swift 1.1.0).** On a multilingual model (large-v3, small), `TimestampRulesFilter` looks for the task token among the first three tokens, and a prompt comes first. Prompted live decodes returned words timed past the window's end, which are dropped, or squeezed into its first second, which defeats duplicate removal. On a 60 s trial clip, before the fixture-level and first-token fixes, the spec's prompt (vocabulary plus settled text) gave 38% WER against 26% unprompted. A diagnostic that kept the prompt and restored the rules gave 67%. Every gated run decodes with `LiveDecoderPrompt.none`.
2. **WhisperKit's first-token check empties decodes.** Its default `firstTokenLogProbThreshold` (-1.5) asks for a retry at a higher temperature; with no retries the decode comes back empty. On a long monologue two decodes in three were empty, agreement never formed and the forced boundary dropped the speech with no gap. `WhisperKitLiveDecoder` sets the threshold to `nil`. On that clip WER went from 20.4% to 8.4%.
3. **AMI fixture levels were too quiet.** AMI's headsets put speech at -44 to -29 dBFS (one meeting at -22 to -14), so much of it sat under the Whisper session's -45 dBFS silence test and was skipped. The fixtures now scale each headset to -26 dBFS active speech level, as described above.

## Cost and intervals

Median (p95) decode time on the smoke clip, under no call load:

| Window | large-v3 | small |
|---|---|---|
| 2 s | 1.20 s (1.34) | 0.33 s (0.57) |
| 10 s | 1.65 s (2.54) | 0.89 s (1.39) |
| 30 s | 3.82 s (5.31) | 2.62 s (3.35) |

Load time: large-v3 1.4 s, small 0.7 s (warm, from disk cache).

In the gated runs, under call load, live decodes took a median 1.3 to 1.5 s (p95 2.3 to 2.5 s) for large-v3 and 0.30 to 0.37 s (p95 0.8 to 1.0 s) for small, from each decode's `decode_milliseconds`.

**The shared decode lane.** The Whisper session runs one decode at a time for both tracks. In two-track mode, while both tracks talk, one round holds two decodes. In the gated validation runs, two consecutive decodes of different tracks took a median 2.8 s (p95 4.6 s) for large-v3 and 0.7 s (p95 1.5 s) for small. So large-v3 cannot keep a 2 s interval on both tracks (a median 2.7 s between decodes of one track), and small keeps its 1 s interval most of the time (a median 1.1 s). Of its 333 gaps over 1.5 s between decodes of one track, 133 came from a busy lane; in the other 200 the lane sat idle (a median 2.6 s) while that track had nothing to decode.

**How intervals were chosen.** Before the night, from runs on a busy Mac labeled provisional and virtual-clock runs: of the intervals that fit one track, the one with the best latency tier on the calibration clips, then the lowest WER. That picked 1 s for small (it beat 2 s on both) and 2 s for large-v3 (it beat 4 s on latency). Those numbers are diagnostics only; the night rechecked them on quiet real-time runs.

**Rechecks (calibration clips, real time, quiet):**

| Configuration | Shown ≤ 3 s | Settled ≤ 5 s | Within 5 s / 8 s | WER |
|---|---|---|---|---|
| small, 1 s | 96.6% | 94.4% | 98.6% / 98.6% | 22.7% |
| small, 2 s | 86.3% | 63.4% | 95.3% / 87.2% | 27.1% |
| small, 4 s | 49.3% | 19.2% | 86.2% / 51.1% | 25.7% |
| large-v3, 1 s | 64.7% | 42.6% | 91.1% / 75.8% | 21.9% |
| large-v3, 2 s | 54.1% | 27.5% | 88.5% / 65.2% | 22.0% |
| large-v3, 4 s | 29.1% | 6.6% | 72.7% / 36.9% | 22.3% |

Four rows here (small at 1 s and 2 s, large-v3 at 2 s and 4 s) and the two Whisper mixed rows in the next section pool two cold runs over different halves of the calibration clips (3 clips each); the diagnostics report marks them as measured in parts. The other rows are one run over all six clips.

The recheck confirms 1 s for small. For large-v3 it contradicts the provisional choice: 1 s is faster than 2 s, but no large-v3 interval comes near either latency tier, so the error does not change the decision. Calibration WER is high in two-track mode because of crosstalk (next section).

## Mixed vs two-track

Calibration only, so a diagnostic (gated validation ran two-track). The final pass scores 19.1% WER on the same calibration clips.

| Configuration | Two-track WER | Mixed WER | Two-track settled ≤ 5 s | Mixed settled ≤ 5 s |
|---|---|---|---|---|
| small, 1 s | 22.7% | 15.3% | 94.4% | 94.3% |
| large-v3, 2 s | 22.0% | 12.9% | 27.5% | 36.9% |
| SpeechAnalyzer | 34.5% | 16.6% | 59.0% | 59.3% |
| SpeechAnalyzer, fast | 35.1% | 17.1% | 73.2% | 73.9% |

Two-track WER on calibration is driven by three clips where other speakers' voices bleed into the mic headset and the mic stream transcribes them: for small, `cal-is1003b-sparse` 62.4% (59 crosstalk insertions), `cal-ts3010a-sparse-long-turn` 29.8% (22) and `cal-ts3010a-negations` 27.3% (29). Almost all crosstalk insertions are on the mic stream. SpeechAnalyzer, which has no level gate, transcribes more of the bleed than Whisper, whose session skips audio under -45 dBFS: on the same three clips SpeechAnalyzer two-track reached 48 to 70% WER.

AMI's bleed comes from other people in the same room. In a call, the app's mic path uses VoiceProcessingIO echo cancellation (`LiveMicCaptureEngine`, `setVoiceProcessingEnabled(true)`), and the system track is the call's own audio, which carries none of the mic speaker's voice. So AMI overstates two-track crosstalk for a call with remote participants; it is closer to a room where several people share one Mac. This is not measured.

Two-track stays the default because it names "You" and "Others", which the drawer needs; mixed mode is the fallback the spec already has.

## Results (gated)

Six validation clips, two quiet real-time runs each, pooled; one 45-minute soak per option. Two-track, simulated call load, vocabulary off. The final pass scores 11.3% WER on the same validation clips.

### Headline

| Option | Shown ≤ 3 s | Settled ≤ 5 s | Within 5 s / 8 s | Latency | WER (vs final) | Critical words | Accuracy | Endurance |
|---|---|---|---|---|---|---|---|---|
| whisper-current (large-v3, 2 s) | 45.6% | 24.4% | 83.5% / 64.6% | fail | 11.9% (+0.6) | 90.2% | fail (critical) | pass |
| **whisper-small (1 s)** | **97.2%** | **93.6%** | **99.7% / 98.8%** | **slower tier** | **12.7% (+1.4)** | **84.1%** | **fail (critical)** | **pass** |
| SpeechAnalyzer | 71.6% | 58.5% | 98.0% / 81.5% | fail | 14.0% (+2.7) | 91.6% | fail (critical) | not measured |
| SpeechAnalyzer, fast results | 97.9% | 76.3% | 98.5% / 89.5% | fail | 13.8% (+2.4) | 87.9% | fail (critical) | pass |

Every option passes the WER limits and fails only the critical-word part of accuracy. The validation clips hold 107 critical words, 214 over the two pooled runs, so one word is 0.5 points.

The final pass itself keeps only 92.5% of the critical words (99 of 107) on the same clips, so on this clip set the 95% limit is out of reach for any live engine. The threshold stays frozen; the table below compares each option with the final pass instead.

| Critical words kept | Names (27 per run) | Numbers (30) | Negations (50) | All (107) |
|---|---|---|---|---|
| Final pass (large-v3, one run) | 92.6% | 93.3% | 92.0% | 92.5% |
| whisper-current | 87.0% | 95.0% | 89.0% | 90.2% |
| whisper-small | 77.8% | 86.7% | 86.0% | 84.1% |
| SpeechAnalyzer | 88.9% | 93.3% | 92.0% | 91.6% |
| SpeechAnalyzer, fast results | 88.9% | 86.7% | 88.0% | 87.9% |

### Other measures (validation, both runs pooled)

| Option | Corrections /100 words | Crosstalk insertions | Repeat insertions | Words in silence | Decodes in silence | Gaps |
|---|---|---|---|---|---|---|
| whisper-current | 79.1 | 24 | 5 | 81 | 145 of 1166 (12%) | one 1.3 s queue-overflow gap (`val-ib4003-names-negations`, run 1) |
| whisper-small | 37.0 | 4 | 15 | 55 | 422 of 2567 (16%) | none |
| SpeechAnalyzer | 23.9 | 141 | 12 | 42 | n/a | none |
| SpeechAnalyzer, fast results | 29.3 | 112 | 13 | 56 | n/a | none |

- **Repeat insertions** (an inserted word that repeats one of the four before it, phase 1's duplicate-text question) are rare for every option: at most 15 in 4494 scored words (0.3%). On the soak: large-v3 15, small 10, SpeechAnalyzer fast 13.
- **Decodes in silence** are Whisper decodes whose new audio held no speech from that track's speakers. For small, 263 of the 422 had new audio above the -45 dBFS gate (bleed or noise); the other 159 had new audio under it: the session's own decodes that confirm a tail after a second of silence or finish a window. They take a share of the shared lane: 16% of small's decodes.
- **Crosstalk** is mostly SpeechAnalyzer on the mic stream (`val-ts3012a-long-turn`: about 50 per run), as on calibration.
- **Gaps:** the only lost audio in any gated run is large-v3's one queue-overflow gap, which the session showed as a gap, as the functional spec's rule 2 (speech is never lost silently) requires.

### Spread between the two validation runs

| Option | WER | Shown ≤ 3 s | Settled ≤ 5 s | Baseline CPU idle (run 1 / run 2) |
|---|---|---|---|---|
| whisper-current | 1.0 pts | 2.4 pts | 2.7 pts | 64.7% / 85.6% |
| whisper-small | 0.2 pts | 0.7 pts | 1.7 pts | 65.1% / 86.5% |
| SpeechAnalyzer | 0.2 pts | 0.0 pts | 0.0 pts | 67.9% / 85.8% |
| SpeechAnalyzer, fast | 0.1 pts | 0.6 pts | 0.3 pts | 76.6% / 76.2% |

The spreads are small against the gaps between options. The first Whisper runs started on a less idle Mac than the second and were still within 1 to 3 points, so the busy rule did not hide a large load effect on this Mac.

### Soak (45 minutes)

| Option | Shown ≤ 3 s | Settled ≤ 5 s | WER | Lag growth | First-display growth | Overflow gaps | Added memory | Serious heat |
|---|---|---|---|---|---|---|---|---|
| whisper-current | 42.6% | 22.4% | 12.9% | +0.0 s | +0.4 s | 0 | 0.73 GB | 0 s |
| whisper-small | 95.8% | 93.4% | 14.7% | +0.1 s | +1.0 s | 0 | 2.68 GB (see below) | 0 s |
| SpeechAnalyzer, fast | 97.7% | 81.1% | 16.0% | +0.0 s | -0.5 s | 0 | 0.59 GB | 0 s |

p95 first display per five minutes (s):

- whisper-current: 8.6, 6.4, 11.4, 15.4, 12.6, 28.2, 15.8, 5.5, 9.8, 3.9
- whisper-small: 2.7, 2.1, 2.4, 2.3, 3.1, 3.3, 3.5, 3.0, 5.1, 3.2
- SpeechAnalyzer, fast: 1.4, 1.7, 2.4, 1.9, 1.7, 1.4, 1.3, 2.1, 1.3, 1.2

No option falls further behind over 45 minutes. SpeechAnalyzer without fast results had no soak (the runner's rule picked the fast variant).

**whisper-small's 2.68 GB peak is a transient wired-memory spike of unknown source.** Added memory is system-wide on purpose, so SpeechAnalyzer's model, which runs in another process, counts. For the first 32 minutes of small's soak it was at most 0.34 GB. It then climbed, was over 2 GB for 16 s at minute 34 (09:06), and peaked at 2.68 GB as wired memory jumped from 1.28 to 3.03 GB over the baseline, 1.8 GB above its usual level. A minute later another process freed about 12 GB, and system memory stayed 8.5 to 12 GB below the baseline for the rest of the soak.

- **The spike recurs.** The same wired-memory jump happened 11 times in small's soak (wired memory more than 0.5 GB above the run's median), between minutes 17.6 and 41.8, for 6 to 25 s each. Five came after the other process freed its 12 GB, so they are not that process's memory; the added-memory gate missed them because system memory was then below the baseline.
- **It follows whisper-small.** Episodes with wired memory more than 1 GB above the run's median also appear in 6 of small's other 12 runs (peaks of 1.8 to 4.7 GB over the baseline), in 1 of the 12 other large-v3 runs (`104052`, 2.4 GB) and in none of the 11 other SpeechAnalyzer runs or the 2 vocabulary runs. Three runs from the first hour, while Spotlight indexed (`034835`, `041134`, `043152`), also cross that line but are left out: there wired memory swung by up to 4 GB or fell 3.4 GB mid-run.
- **Footprint does not settle it.** live-bench's own footprint stayed between 0.43 and 0.51 GB for the whole soak (large-v3: 0.41 to 0.50 GB), but it is not known whether that figure includes CoreML's Neural Engine and GPU memory.

The endurance gate passes as measured (2.68 GB is under 3 GB), but the source of the spikes is not identified.

The engines' CPU cost is small: on the quietest runs, replay CPU idle was 2 to 4 points under the baseline for Whisper and 0 to 1.5 points for SpeechAnalyzer. GPU and Neural Engine use are not measured.

### Own load

Each option alone on the smoke clip, under call load, at the start of the night (03:48 to 04:00, baseline CPU idle 62 to 66%). One 90 s clip with two critical words, so a check that each option runs, not a gate result. The latency order matched validation: small 98.3% shown ≤ 3 s and 97.5% settled ≤ 5 s; large-v3 58.3% and 23.3%.

## Back-to-back

Each live option ran once on the six validation clips while final passes of the 45-minute soak clip ran one after another in another process. This is the case the spec forbids: "No final pass runs while a recording is in progress." The arm measures what that rule protects.

| Live option | Shown ≤ 3 s (alone → alongside) | Settled ≤ 5 s (alone → alongside) | WER alongside | Final passes of the 45-min soak that finished, minutes each |
|---|---|---|---|---|
| whisper-current | 45.6% → 37.0% | 24.4% → 17.8% | 11.5% | 1 in 20 min: 13.3 |
| whisper-small | 97.2% → 89.0% | 93.6% → 82.6% | 12.1% | 3: 6.6, 7.1, 6.1 |
| SpeechAnalyzer, fast | 97.9% → 99.0% | 76.3% → 75.4% | 13.8% | 3: 4.4, 4.7, 4.3 |

"Alone" is the pooled two-run validation result; "alongside" is one run. The times are each pass's transcription (`finish_seconds`). A pass still running when the live run ended was stopped and is not counted. There was no final pass of the soak alone. The cold final pass of all 13 short clips (about 40 minutes of audio) took 4.7 minutes, so a lone 45-minute pass takes about 5 minutes (5.3 by linear scaling); the passes beside SpeechAnalyzer took 4.3 to 4.7.

One pass beside SpeechAnalyzer waited 4 minutes before it began: its CoreML cache had lost a file (`resources.bin missing` in the e5rt bundle cache) and was rebuilt. That is a cache event, not contention; its transcription took 4.7 minutes.

With whisper-small live, the back-to-back run also leaves the slower latency tier: 95.3% shown within 5 s, 94.1% settled within 8 s.

What it means:

- **Whisper live and a Whisper final pass contend.** Both use WhisperKit's CoreML models, presumably on the same Neural Engine and GPU (not measured). whisper-small drops from passing the slower tier to failing it, and each final pass takes 6.1 to 7.1 minutes, about 1.5 times the passes beside SpeechAnalyzer. With large-v3 live a pass takes 13.3 minutes, about 3 times as long.
- **SpeechAnalyzer live and a Whisper final pass barely touch each other.** Live latency and WER did not change, and the final passes ran at about their lone speed.
- **Keep the rule with Whisper live.** Running an earlier meeting's final pass during a recording would push whisper-small out of its latency tier, and the pass itself runs slower. The rule in the spec (cancel the earlier pass, requeue it at the front, restart after the recording) stays as specified. For back-to-back meetings this means each earlier meeting's saved transcript waits until the next recording stops, then takes about 5 minutes per 45 minutes of audio.
- **SpeechAnalyzer live would allow relaxing it.** With SpeechAnalyzer live, an earlier meeting's final pass could run during the next recording without hurting live text. That would change the functional spec ("No final pass runs while a recording is in progress"), and the recording-safety gate would have to hold with a final pass running. This run measured live text only.

## Vocabulary

- **Live Whisper has no custom vocabulary.** `LiveDecoderPrompt.none` sends no prompt, so the vocabulary in `LiveSessionConfig` is not used. The spec's "custom vocabulary applies to live transcription with every engine that supports it" is not met for live Whisper until WhisperKit applies timestamp rules to prompted decodes on multilingual models, or Biscotti finds another way to bias decodes.
- **SpeechAnalyzer's contextual strings did not change the names.** The functional spec asked the experiment to check whether custom vocabulary works with `SpeechTranscriber`. On 2026-10-24 (16:34 to 16:55, after the night, baseline CPU idle 66 to 68%, same live-bench binary, SHA-256 `c67bbfe94d94`), each SpeechAnalyzer variant ran once with vocabulary on (`AnalysisContext.contextualStrings`, each clip's `vocabulary` from `meta.json`, 4 to 13 terms) on the three clips with names: `val-es2009a-long-turn`, `val-es2009a-fast-turns-names`, `val-ib4003-names-negations`. Runs `20261024-163437-speechanalyzer-i2-two-track-fast-load` and `20261024-164510-speechanalyzer-i2-two-track-load`.

  | Variant | Vocabulary | WER | Names kept | Critical words |
  |---|---|---|---|---|
  | SpeechAnalyzer | off (2 gated runs) | 10.9% | 48 of 54 | 90.9% |
  | SpeechAnalyzer | on (1 run) | 11.1% | 24 of 27 | 90.9% |
  | SpeechAnalyzer, fast results | off (2 gated runs) | 10.2% | 48 of 54 | 87.0% |
  | SpeechAnalyzer, fast results | on (1 run) | 10.2% | 24 of 27 | 89.6% |

  Each variant missed the same three names in every run, with the same text with vocabulary on and off: "Gisella" as "Gisela" ("Jizala" with fast results), "ETPFL" as "Tepe Valley" ("Tepe Fell" with fast results), and "Willing" as "Welling" (AMI and the final pass write "Tom Willing"; live Whisper also writes "Tom Welling"; the actor's name is spelled Welling). All three were in the vocabulary. The other differences are within run-to-run variation (one or two words). So contextual strings had no measurable effect on `SpeechTranscriber` here. Leaving them in place is harmless, as the live_session design allows, but the spec's custom-vocabulary promise is not met by SpeechAnalyzer either.
- **Out of scope, found here:** the app's final pass prompts large-v3 when custom vocabulary is on (`InProcessTranscriptionEngine.runSTT`), so it too runs without WhisperKit's timestamp rules. The final pass was not changed in this project; its timestamps and duplicate handling with vocabulary on should be checked separately.

## Recommendation

**Decision: whisper-small, unprompted, two-track, every 1 s.** Made on 2026-10-24, from the numbers below.

No option passes every gate as frozen. The decision is a judgement about which misses matter.

- **Latency is what makes live captions useful.** A caption that settles 10 to 20 s late is not live. whisper-current settles only 24% of words within 5 s and has a p95 settle time of 17 to 26 s; no interval fixes that, because two-track large-v3 needs about 3 s per round on the shared lane. It fails the gate that matters most.
- **whisper-small is the only option in a latency tier.** It passes the slower tier with margin (99.7% shown within 5 s, 98.8% settled within 8 s) and misses the faster tier only on settling (93.6% against 95%). Its first display (97.2% within 3 s) passes the faster threshold. It held this for 45 minutes.
- **SpeechAnalyzer with fast results shows text fastest but settles late:** 76.3% within 5 s and 89.5% within 8 s, so it misses even the slower tier. It also needs macOS 26, while the app supports macOS 15. Without fast results it is slower on both counts.
- **Critical words are the real cost.** whisper-small keeps 84.1% of names, numbers and negations, the lowest of the four (large-v3 90.2%, SpeechAnalyzer 91.6%, the final pass 92.5%). Names are its weakest category: 77.8% kept against 92.6% for the final pass. Misses include negations ("shouldn't", "not"), numbers ("five") and names ("Edinburgh", "La Jolla"). For live captions this is acceptable but not good: the final pass, which keeps large-v3, writes the saved transcript, and live text is replaced when it finishes. A user who acts on a live caption during the meeting may misread a missed negation. This is the main risk of the choice.
- **WER is close across options** (11.9% to 14.0% against 11.3% for the final pass), so it does not decide.
- **Back-to-back favors SpeechAnalyzer.** Only SpeechAnalyzer live leaves room to run an earlier meeting's final pass during a recording (see [Back-to-back](#back-to-back)). With whisper-small, saved transcripts of back-to-back meetings wait for the next recording to stop.

**What would change the decision:** a Mac with 16 GB or less, where small's 2.68 GB peak would be near the 3 GB limit (not measured; see [Soak](#soak-45-minutes)); results on a slower Mac, where small's settle latency may leave the slower tier (not measured); a product rule that names, numbers and negations matter more than settle time, which favors SpeechAnalyzer without fast results (91.6% critical words) on macOS 26; or a later WhisperKit release that makes prompted decodes keep timestamp rules, which would bring back context and vocabulary and may recover critical words.

### `LiveTranscriptionDefaults` each choice implies

| Choice | engine | whisperModel | tracks | updateInterval | Whisper prompt | minimum macOS |
|---|---|---|---|---|---|---|
| **whisper-small (chosen)** | `.whisper` | `openai_whisper-small` | `[.mic, .system]` | 1 s | `.none` | 15 |
| whisper-current | `.whisper` | `openai_whisper-large-v3-v20240930_626MB` | `[.mic, .system]` | 1 s (fastest measured; no interval reaches a tier) | `.none` | 15 |
| SpeechAnalyzer | `.speechAnalyzer` | `nil` | `[.mic, .system]` | 2 s (no effect) | n/a | 26 |
| SpeechAnalyzer, fast | `.speechAnalyzer`, plus a new fast-results constant for `SpeechAnalyzerLiveSession(fastResults:)`, which `LiveSessionConfig` does not carry | `nil` | `[.mic, .system]` | 2 s (no effect) | n/a | 26 |

The chosen engine, model, tracks and interval are in `Packages/BiscottiKit/Sources/LiveTranscriptionService/LiveTranscriptionDefaults.swift`; the prompt is `WhisperKitLiveDecoder.defaultPrompt`. whisper-small runs on the app's macOS 15 deployment target, so the live path needs no availability check.

## Known limits

- **One Mac.** All results are from one M1 Max with 64 GB. Smaller Macs, especially with 16 GB or less, and other chips were not measured.
- **No custom vocabulary in live text.** Live Whisper decodes unprompted, and SpeechAnalyzer's contextual strings changed nothing measurable (see [Vocabulary](#vocabulary)).
- **The final pass prompts large-v3 when vocabulary is on** (`InProcessTranscriptionEngine.runSTT`), so it runs without timestamp rules. Not changed here.
- **Background maintenance can contend for the Neural Engine.** Spotlight and `mediaanalysisd` ran through much of the night. The busy rule reads CPU idle, which does not see Neural Engine or GPU use; a run with a quiet CPU can still share the Neural Engine. The small spread between validation runs suggests the effect was small on this night, but it is not measured.
- **AMI is not a video call.** The headsets are in one room, so the mic track carries other speakers' voices. In a call the app's mic is echo-cancelled (VoiceProcessingIO) and the system track is the call's own audio. Two-track crosstalk is likely overstated, most for SpeechAnalyzer; real network audio and codecs are not represented.
- **The critical-word limit is above the final pass.** The final pass keeps 92.5% of critical words on the validation clips, so no live engine can pass the frozen 95% limit on this clip set.
- **Memory is system-wide.** It counts other processes, and a 16 s wired-memory spike set whisper-small's soak figure (see [Soak](#soak-45-minutes)).
- **GPU and Neural Engine use are not measured.** The CPU-idle rules do not see them.
- **The vocabulary check is one run per variant on three clips**, with a vocabulary of 4 to 13 terms per clip.
- **Session latency only.** The app adds XPC delivery, store merging and rendering, to be read with `OSSignposter` during the hardware checks.
- **Back-to-back is one run per option.**
- **Endurance for SpeechAnalyzer without fast results was not measured.**
- **English only.** Every run used English (AMI is English). Detect language, the functional spec's default on a non-English Mac, was not measured.
- **Latency counts matched words only:** 89.8 to 91.2% of scored validation words; a word the engine dropped or changed has no latency.

## Follow-ups

- **The `openai_whisper-small` download (done in phase 8).** `WhisperModelFiles` downloads the live model and its tokenizer into the large-v3 copy's layout, without loading it. Onboarding fetches it when live transcription is on; until it is on disk the live transcript is Unavailable, as the functional spec's "no transcription model" case says, and the drawer and Settings offer the download (phase 10). The live and final models now differ, so the worker cannot share one loaded `WhisperKit` between them. It never keeps both loaded: as [`components/transcriber_worker.md`](../../projects/live_transcript/components/transcriber_worker.md) specifies, `EngineHost` loads the live model on its own when a session starts, after unloading the final pass's models, and unloads it when the session ends, before any final pass (phase 7).
- **Memory (phases 7 and 11).** The source of whisper-small's 2.68 GB soak peak is not identified: it is a transient wired-memory spike that recurs in whisper-small runs (see [Soak](#soak-45-minutes)). The worker never holds both models (phase 7), until the second UI review: on Macs with more than 8 GiB, whisper-small now stays loaded next to large-v3 during a final pass, so what remains is small's own spikes. The worker logs its footprint and the system's wired memory (unified log, category `live`, "Worker memory …") after it loads and after it unloads the live model; phase 11's 16 GB check must read wired memory as well as the footprint.
- **No custom vocabulary in live text.** Neither engine applies it. Re-measure `LiveDecoderPrompt.vocabularyAndSettledText` with the replay harness when argmax-oss-swift keeps timestamp rules for prompted decodes on multilingual models (TODO on `WhisperKitLiveDecoder.defaultPrompt`). Until then the live drawer must not claim to use the custom vocabulary.
- **Keep the final-pass hold (phases 7 and 8).** With Whisper live, an earlier meeting's final pass waits until the recording stops, as the functional spec says.
- **Critical words.** Phase 11's hardware check should read names, numbers and negations in the drawer on a real call; small's names are its weakest point.
- **Slower Macs.** small's settle latency sits 1.4 points under the faster tier on an M1 Max. Phase 11 should check the tier on a base M-series Mac.
- **First compile during a meeting (phase 11).** The live model is never loaded ahead of time, so the first live start of a new build runs the Neural Engine compile during a meeting, for minutes. Stop during that start closes the only connection and the worker exits, so the next start may compile again. Phase 11 should check how long it takes and whether the compile result survives.
  - *Measured, 25 October 2026:* the first live start of a new test build took 1 min 51 s. Since the UI review that day, Biscotti loads the live model and the final pass's model once in the background after an install, an update or a model download, while nothing records ([transcriber_worker](../../projects/live_transcript/components/transcriber_worker.md#model-preparation)). A recording that starts during it stops it, so that meeting may still compile. Phase 11 should check that a meeting started after the preparation finished starts in seconds.
  - *Corrected in the second UI review, 25 October 2026:* the compile does not happen once per build in the app's worker. After the background preparation (100 s), the next two live starts compiled again: the drawer waited 2 min 0 s and 1 min 44 s. A probe outside the app, loading whisper-small's three Core ML models with WhisperKit's compute units, compiled in 112.7 s and then loaded in 0.32 s in a new process, whatever the exit mode, unloads or signing identity; large-v3 took 247 s cold (audio encoder about 3.5 min, text decoder about 8.5 s) and 1.05 s warm. So the cache works across processes, and something removes it between meetings: the e5 bundle cache (`~/Library/Caches/<identity>/com.apple.e5rt.e5bundlecache/<OS build>/…`) is purgeable data, and CacheDelete (`deleted`) purges purgeable data when the disk runs low. The startup disk had 7.1 GB free against a purge goal of about 14.8 GB, purgeable data stood at 3.7–4.4 GB and kept refilling, and each compile writes temporary weight copies of 176–420 MB. No public API moves the cache or marks it as not purgeable, so the app cannot keep it; freeing disk space does. The user chose the fallback: while the live transcript is on, the worker keeps whisper-small loaded (about 0.2–0.3 GB: footprint 0.07 GB against 0.04 GB, and the system's wired memory changed by 0.13–0.27 GB at load and unload), loads it at every launch, and loads it again after a final pass ([transcriber_worker](../../projects/live_transcript/components/transcriber_worker.md#keeping-the-live-model-loaded)). A live start then needs no load. The final pass's large-v3 still recompiles on each pass while the disk is low. Phase 11 should check a live start on a Mac with plenty of free disk, where the cache should last.
  - *Decided, 25 October 2026 (the user chose these):* one rule for the kept model. On Macs with more than 8 GiB, whisper-small stays loaded whenever the live transcript is on, also during a final pass; large-v3 and SpeakerKit are unloaded in place after the last pass. A probe that loaded and unloaded large-v3 and SpeakerKit three times next to whisper-small saw the system's wired memory return from 5.7–6.2 GB to about 4.7 GB within 13 s of each unload, while about 0.27 GB of process footprint stayed after the first load and did not grow ([transcriber_worker](../../projects/live_transcript/components/transcriber_worker.md#keeping-the-live-model-loaded)). And the app says when low disk space makes a load slow: a load past 15 s with less than 20 GB free is blamed on the disk, in the drawer, the final transcription's status and Settings.
- **Final-pass prompt (outside this project).** Check the final pass's timestamps with vocabulary on (`InProcessTranscriptionEngine.runSTT`).
- **The harness's default prompt.** `live-bench --whisper-prompt` still defaults to `settled-text`, the spec's original prompt. Pass `--whisper-prompt none` to measure what the app ships.

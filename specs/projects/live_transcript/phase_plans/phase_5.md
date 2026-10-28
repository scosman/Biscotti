---
status: complete
---

# Phase 5: Run the Experiment

## Overview

Run the replay experiment that picks the live engine, record the results in `specs/research/live_transcription/README.md`, and stop for the user's engine decision, which later sets `LiveTranscriptionDefaults`. This phase is measurement, not product code. It first fixes the phase 3 and phase 4 follow-ups that would skew a comparison, then freezes the clip list and fixtures, then runs every option the same way on this Mac (MacBook Pro M1 Max, 64 GB, macOS 26.6).

The options are the current Whisper model (`openai_whisper-large-v3-v20240930_626MB`), `openai_whisper-small` as a full option (user decision), and SpeechAnalyzer with and without `.fastResults`. The user also asked for a back-to-back diagnostic arm: each live option on the validation clips while a final pass of another long clip decodes in parallel.

Rules that hold throughout: the clip list and `fixtures.lock.json` are frozen before any option is compared, and no clip is chosen by how an option does on it; only real-time runs on a quiet Mac are gated; the endurance thresholds frozen in `report.py` stay as they are.

This plan was rewritten once, during the phase. The first real runs found three defects that made a comparison meaningless (a WhisperKit prompt bug, a WhisperKit first-token check, and AMI's quiet headset levels), and the gated runs moved to an unattended overnight window on a quiet Mac, because other work kept the load average near 35 during the day.

## Steps

1. **Follow-up fixes (`Tools/live_bench`):**
   - `normalize.py`: join AMI's letter spellings (`L_C_D_`, `T_V_s`, `T_V_'s`, `anti-R_S_I_`) into one token, as Whisper writes them.
   - `score.py`: record clips the manifest lists but has no session for as `missing_clips`; record each stream's word count beside its corrections; place each word of a live row within the row (`word_times`) for the crosstalk diagnostic; count repeat insertions (an inserted word that repeats one of the four before it) as phase 1's duplicate measure; p95 first-display latency per five-minute block on long clips (`first_display_by_block`); the run's system load (median and p90 1-minute load average, median CPU idle).
   - `report.py`: missing clips fail every gate their split feeds; corrections are `100 * sum(rewritten) / sum(words)` over both streams; a "Repeat insertions" column; the soak's five-minute timeline; runs with `alongside` set, and dry runs (clips cut short, their own configuration, never the final-pass baseline), are diagnostics; a run that started in Low Power Mode, or whose 30 s baseline, before the engine loads, was busy (median CPU idle under `BUSY_CPU_IDLE`, 50%; the load average is shown but does not decide, see step 9) or that recorded no CPU idle is left out of the gates (a configuration with only such runs is a diagnostic), and the load while the clips replayed is only displayed; repeated runs of a configuration pool their clips, and a runs table shows each run's numbers and both loads, with the spread between gated runs of the same clips.
   - `make_fixtures.py`: scale each headset so its speaker's annotated speech, over the whole meeting, sits at -26 dBFS (ITU-T P.56 active speech level), instead of a fixed -3 dB; record the gains in the lock.
   - `hooks_mcp.yaml`: `bench_live` timeout 3600 → 7200 s.

2. **Live decoder (`WhisperKitLiveDecoder`):**
   - `LiveDecoderPrompt` (`.vocabularyAndSettledText`, the spec's default, or `.none`): with argmax-oss-swift 1.1.0, a prompt on a multilingual model switches off WhisperKit's timestamp rules and live text lands at the wrong times.
   - `firstTokenLogProbThreshold = nil`: WhisperKit's -1.5 default asks for a temperature fallback, and with no fallback the decode comes back empty.

3. **`live-bench`:**
   - `run --alongside TEXT` (the back-to-back arm, recorded in `options.alongside`).
   - `run`/`cost --whisper-prompt settled-text|none|settled-text-timestamp-rules`; the last is a diagnostic (`PromptedTimestampRules`) that keeps the prompt and restores the timestamp rules.
   - `resources.jsonl` gains `one_minute_load_average` and `cpu_idle`; the manifest's repo record gains `source_fingerprint` (SHA-256 over `git diff HEAD` and every untracked file).
   - Dry-run cuts, validated and recorded in the manifest: `run --clip-seconds S --baseline-seconds N`, `final-pass --clip-seconds S`, `cost --decodes N`. The fixtures are read whole and never change.
   - A TODO on `WhisperKitLiveDecoder.init`: the default stays the spec's prompt until the engine decision.

4. **Overnight runner (`Tools/live_bench/overnight.py`):** one run at a time under `caffeinate -i`, holding a lock so a second runner on the same folder refuses to start, resumable through `<out>/overnight/state.json` (written atomically), waits before each run until the median CPU idle over 30 s is at least `QUIET_CPU_IDLE` (`BUSY_CPU_IDLE`, plus the share of the CPU the simulated call load takes in the run's baseline, plus 5 points: about 67% on this 10-core Mac) and logs it with the load average at the start of a wait, every 10 minutes during it and before each run, refuses uncommitted changes and untracked files and resumes only from the same commit and source fingerprint (the manifest's value), refuses to start on battery or in Low Power Mode and logs the power state before each run, runs a private copy of live-bench from the startup disk (the working copy was on a USB volume, and paging the binary back in from it crashed two runs with SIGBUS), stops a run after twice its estimate plus ten minutes, retries a failed run once, records a run it cannot score and goes on, scores each run as it ends and writes three reports (gated, own load, diagnostics), each headed by the steps that did not finish or needed a retry. Order and priority: each option's own load on one smoke clip; cost and the final-pass baseline; validation of every option twice, options interleaved and the second round reversed; a soak per option (whisper-current, SpeechAnalyzer, whisper-small); whisper-small's interval recheck; the back-to-back arm; the other real-time calibration rechecks on half the calibration clips; then the extended calibration block, for the diagnostics report only: all six calibration clips for the spec's candidates (Whisper at 1, 2 and 4 s, two-track or mixed; SpeechAnalyzer two-track or mixed, with or without fast results), completing the rechecked combinations with the other three clips (all six when the recheck did not count; the report notes a combination measured in parts), most informative first, 14 of 16 combinations, about 3.8 h. A deadline (`--hours` after the first start, kept across restarts; 7.5 by default, 24 tonight) skips what would end later. The whole plan is about 11.4 h before waits. The SpeechAnalyzer variant for the soak and the back-to-back arm follows a fixed rule over its quiet validation runs.
   - `--dry-run`: the same steps through the same code, each cut short (one clip per run, 4 s of each clip, 60 s of the soak, a 1 s baseline, one timed decode per cost length), into `<out>/dry-runs/<time>/`. It kills the schedule during a validation run and starts it again, forces one tiny timeout and one scoring failure, measures CPU idle over 3 s and logs it with the load average instead of waiting, labels both reports as plumbing only, and prints a pass or fail per check.

5. **Models:** download `openai_whisper-small` and its tokenizer into the benchmark's model folder in the large-v3 copy's layout, with `HF_HOME` outside the app's data.

6. **Fixtures:** pick clips from the AMI annotations only (3-minute windows on a 60 s grid measured for longest turn, speaker changes, overlap, interjections, numbers, negations, named entities and speech density), write `Tools/live_bench/clips.json`, fetch the meetings, cut the fixtures and copy `fixtures.lock.json` to `specs/research/live_transcription/`.

7. **Before the night (busy Mac, provisional):** cost check, smoke, real-time calibration of whisper-current at 2 and 4 s, and virtual-clock calibration runs for accuracy (whisper-small at 1, 2 and 4 s; whisper-current at 2 and 4 s; the spec's prompt; mixed mode). Settings are chosen from these and written into `overnight.py`; the overnight rechecks test them.

8. **Overnight (quiet Mac):** `overnight.py --dry-run` as a preflight, then `overnight.py`, launched after a restart.

9. **Morning:** check the runner's log and state, read both reports (load per run, spread between repetitions, soak timelines), compare the rechecks with the chosen settings, and write `specs/research/live_transcription/README.md` (machine, fixtures and lock hash, clips, frozen thresholds including endurance, the quiet and busy tests and why they read CPU idle, not the load average (the runner waits for a median CPU idle over 30 s of at least 50% plus the simulated call load's share plus 5 points, about 67% on this Mac, because the check runs without the call load that the run's baseline includes, and a run whose baseline median CPU idle is under 50% is left out of the gates; the load average counts runnable threads; Spotlight and mediaanalysisd run at background priority, which on Apple silicon uses only the two efficiency cores, so their queue raises it while the performance cores stay idle: at night Spotlight's `mds_stores` and `corespotlightd` and `mediaanalysisd` kept it at 15 to 20 for hours while the CPU stayed 65 to 75% idle, so a wait on the load average started no run in 45 minutes), the three defects, cost, calibration, validation, soak, back-to-back and what it means for holding an earlier meeting's final pass, vocabulary, the recommendation and the `LiveTranscriptionDefaults` each choice implies). Explain how the intervals were chosen, including the shared decode lane (one decode at a time for both tracks, so two-track large-v3 needs about 3 s and small about 1.3 s per round while both tracks talk). State that live Whisper with `LiveDecoderPrompt.none` has no custom vocabulary, and record, out of scope, that the app's final pass prompts large-v3 when custom vocabulary is on (`InProcessTranscriptionEngine.swift:203`), so it too runs without WhisperKit's timestamp rules; the final pass is not changed here. Point the live-captions note in `specs/research/argmax/README.md` to it. Stop for the engine decision; set nothing in `LiveTranscriptionDefaults`.

   Note, after the decision: whisper-small (every 1 s, two-track, unprompted) was chosen on 2026-10-24, and that decision set `LiveTranscriptionDefaults`.

## Tests

`Tools/live_bench/tests` (pytest):
- `test_ami_letter_spellings_read_as_whisper_writes_them`
- `test_crosstalk_inside_a_row_with_the_speakers_own_words_is_counted`
- `test_repeated_insertions_are_counted_as_repeats`
- `test_first_display_is_summarized_per_five_minutes_on_long_clips`
- `test_score_run_end_to_end` (extended): missing clips, corrections word count, load summary.
- `test_make_fixtures_uses_the_corpus_channel_map` (changed): every speaker at the speech level; gains in the lock.
- `test_report_applies_gates` (extended): the corrections column over both streams.
- `test_clips_a_run_never_finished_fail_their_gates`
- `test_runs_with_work_alongside_are_diagnostics`
- `test_a_configuration_measured_in_parts_says_so`, `test_dry_runs_never_pool_with_real_runs_or_give_the_baseline`.
- `test_busy_runs_are_left_out_of_the_gates_and_shown_with_their_load` (baseline CPU idle, a high load average with an idle CPU still gated, no CPU idle recorded, Low Power Mode), `test_busy_is_judged_by_cpu_idle_not_the_load_average`, `test_repeated_runs_pool_their_clips_and_report_the_spread_of_the_same_clips` (a soak is not compared with validation runs).
- `test_overnight.py`: priority order and interleaving, the core plan fits the default deadline but for its last recheck and the extended block adds 3 to 4 h, the extended block's coverage and order and its completions' settings, the completion fallback (a high load average with an idle CPU counts), the runner lock, the dry run's cut of completions, power read from `pmset`, the SpeechAnalyzer variant rule with the busy filter, timeouts and one retry, resume skipping done, failed and score-failed steps, scoring failures recorded, the deadline kept across restarts and atomic state, completion needs every clip. The quiet wait: `test_a_busy_cpu_delays_the_next_run_and_a_late_step_is_skipped` (an unreadable idle waits; the wait logs every 10 minutes), `test_a_high_load_average_with_an_idle_cpu_does_not_wait`, `test_a_dry_run_measures_a_short_window_and_only_logs_a_busy_cpu`, `test_cpu_idle_is_the_median_of_each_second`, `test_the_quiet_limit_leaves_a_margin_after_the_call_load` (the call-load constants match `SimulatedCallLoad.swift`).

Swift:
- `WhisperKitLiveDecoderTests`: `noPromptSendsNoTokens`; `decodingOptionsFollowTheLiveSettings` (first-token check off).
- `LiveBenchTests`: `alongsideIsRecorded`, `whisperPromptIsWhisperOnly`, `dryRunCutsAreParsed`, `sourceFingerprintFollowsUncommittedCode`, `idleShareUsesTheDifference`, and the sampler test's new `one_minute_load_average` field.

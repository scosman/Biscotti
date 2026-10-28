---
status: complete
---

# Phase 3: Replay Harness

## Overview

Build the experiment's tools without running the experiment. `live-bench`, a Swift executable in `Packages/Transcription`, replays fixture audio at real-time speed (or on a virtual clock) through `WhisperLiveSession` with `WhisperKitLiveDecoder`, logs every update, samples system memory and heat, and can add simulated call load. `Tools/live_bench`, a `uv` project, fetches AMI audio and annotations, cuts frozen fixtures, scores runs and applies the four gates. `make bench-live` and a `bench_live` hooks-mcp action run the Swift tool. Phase 5 runs the experiment; phase 4 adds the SpeechAnalyzer option.

The accuracy gate compares live WER with the final pass "on the same clips", and nothing in the component spec produces that number without touching production paths. `live-bench final-pass` transcribes each clip once the way the final pass does (both tracks merged with `AudioMerger`, the current method's decoding options), from the `--models` folder.

## Steps

1. **Package manifest** (`Packages/Transcription/Package.swift`):
   - Product `.executable(name: "live-bench", targets: ["live-bench"])`.
   - `executableTarget` `live-bench` (`Sources/live-bench`), depending on `LiveTranscription`, `LiveTranscriptModel`, `Transcription`, `WhisperKit` and `ArgumentParser`; `warningsAsErrors`.
   - Test target `LiveBenchTests` (`Tests/LiveBenchTests`) depending on `live-bench`, `LiveTranscription`, `LiveTranscriptModel`.

2. **Small additions to existing targets:**
   - `Transcription`: `ResolvedMethodSettings.decodingOptions` (used by `InProcessTranscriptionEngine.runSTT`, no behavior change) and a public `TranscriptionMethod.whisperModel` / `whisperDecodingOptions`, so `whisper-current` and `final-pass` follow the app instead of copying its constants.
   - `LiveTranscription`: `public var latestRevision: Int` on `WhisperLiveSession`. On a virtual clock the replay waits until its reader has logged that revision before time moves on, so `t_release` is exact.

3. **Command line** (`LiveBench.swift`): `AsyncParsableCommand` `live-bench` with subcommands `cost`, `run`, `final-pass` and `check-paths`. A shared `BenchPaths` option group holds `--models`, `--fixtures` and `--out` (all required; `cost` also needs fixture audio). Options:
   - `run --option whisper-current|whisper-small|speechanalyzer [--model NAME] --interval 1|2|4 --mode mixed|two-track --clips ID[,ID...] [--load none|call] [--virtual-clock] [--vocabulary-off]`.
   - `cost --model NAME [--clip smoke]`.
   - `final-pass --clips ID[,ID...] [--model NAME]`.
   - `speechanalyzer` exits with a clear "not built yet" error (`TODO` for phase 4).

4. **Path guard** (`PathGuard.swift`): expands `~` against an injectable home, makes paths absolute, resolves symlinks of the existing part with `realpath` and `..` in the rest, and rejects (case-insensitively, by whole components) anything equal to or inside `~/Library/Application Support/Biscotti` or `/Applications/Biscotti.app`, in both literal and resolved form. Clip IDs and model names must be single path components.

5. **Errors** (`BenchError.swift`): one enum whose messages name the path or file involved (production path, missing model folder, missing model file, unknown or missing tokenizer, missing clip, unreadable audio, clip too short, existing output, SpeechAnalyzer not built).

6. **Model location** (`WhisperModelLocation.swift`): the model at `<models>/argmaxinc/whisperkit-coreml/<name>` (the app's Hub layout) must hold `MelSpectrogram`, `AudioEncoder` and `TextDecoder` (`.mlmodelc` or `.mlpackage`); the tokenizer is `tokenizer.json` in the model folder or in `<models>/openai/whisper-<size>`, chosen from the model name. `load()` builds `WhisperKitConfig(modelFolder:tokenizerFolder:download: false, load: true)`; it never calls `ModelStorage`.

7. **Fixtures** (`ClipAudio.swift`): reads `<fixtures>/<clip>/mic.wav` and `system.wav` with `AVAudioFile`, requires 16 kHz mono, pads the shorter track with silence, and reads `vocabulary` from `meta.json`. `mixedSamples` is their sum.

8. **Pacing** (`VirtualClock.swift`, `PacedSource.swift`):
   - `VirtualClock`: a `Clock` that moves only when advanced.
   - `PacedSource` (thread-safe, `Sendable`): releases 100 ms steps. `.realTime(clock)` sleeps until each step's absolute deadline; `.simulated(VirtualClock)` releases at once and advances the shared clock by 100 ms. `releasedSamples` and `releasedThrough` expose only what has arrived; `isSimulated` labels times.

9. **Chunks** (`ChunkAssembler.swift`): 250 ms `LiveAudioChunk`s per track (mic, then system), or the summed tracks in mixed mode, from the released samples; `flush` sends the last partial chunks.

10. **Replay** (`ReplayRunner.swift`, `JSONLinesWriter.swift`): a reader task writes each update to `events.jsonl` as `{t_release, t_event, update}`; the feeder appends chunks as steps arrive. With a virtual clock it runs `runScheduledWork()` after each step and waits for the reader to log `latestRevision`. Then `finish(timeout: .seconds(10))`, and `final.json` with the finish time and updates. Harness JSON uses snake_case keys.

11. **Resources** (`ResourceSampler.swift`): every second, system memory in use from `host_statistics64` (active + wired + compressed pages), process footprint and resident size, memory pressure (`kern.memorystatus_vm_pressure_level`) and thermal state, written to `resources.jsonl` with the current phase (`baseline`, `load-model`, `clip:<id>`). `measureBaseline(seconds: 30)` returns the median used bytes of the baseline phase.

12. **Simulated call load** (`SimulatedCallLoad.swift`): two threads busy 60 ms of every 100 ms, and a thread running batches of 2048×2048 `MPSMatrixMultiplication` whose batch size adapts to about 30 ms of GPU time, followed by idle time for a 30% duty cycle. Started before the baseline, stopped at the end.

13. **Manifest** (`Manifest.swift`, `SystemProbe.swift`): kind, arguments, repo commit and dirty flag (`git`), argmax-oss-swift version and revision (`Packages/Transcription/Package.resolved`), model name, load time and SHA-256 of every model file plus a combined hash, machine model, chip, RAM and OS (`sysctl`, `ProcessInfo`), options, fixture file hashes and the lock file hash, per-session warm or cold, Low Power Mode and thermal state at start, and the memory baseline. Written at start and after each clip.

14. **Commands:**
   - `run`: guard, locate model, load clips, create `<out>/<timestamp>-<option>-i<interval>-<mode>[-load][-virtual]`, start load, baseline, load model, then each clip in `<run>/<clip>/`.
   - `cost`: three warm-up decodes, then ten decodes each of 2, 10 and 30 s windows spread over the clip's mixed audio, through `WhisperKitLiveDecoder` with the session's options; `cost.json` with each time, median and p95 (nearest rank).
   - `final-pass`: per clip, `AudioMerger.merge` of mic and system, `whisperKit.transcribe` with `TranscriptionMethod.current.whisperDecodingOptions`, words before the audio end into `<run>/<clip>/final_pass.json`.
   - `check-paths`: prints the resolved paths.

15. **Python project** (`Tools/live_bench`): `pyproject.toml` with exact pins (`numpy`, `soundfile`, `meeteval`, `jiwer`, `pytest`), `uv.lock`, `.python-version` 3.12, `pythonpath` for pytest.
   - `normalize.py`: lowercase, punctuation except apostrophes removed, hyphens split, fillers dropped, digits, ordinals, decimals and percentages spelled out, a short British-to-American map; number and negation detection for critical words.
   - `fetch_ami.py`: official AMI URLs (annotations 1.6.2 zip, `Headset-<channel>.wav` per meeting from `meetings.xml`), injectable opener, SHA-256 index (`hashes.json`), `ATTRIBUTION.txt` (CC BY 4.0, citation), skips files already present, refuses any download that would take the cache past 2 GB (checked before writing and while streaming).
   - `make_fixtures.py`: reads a clip list (`clips.json`), refuses known defective meetings (from the AMI data-problems page) and an existing lock, maps agents to headsets from `meetings.xml`, crops with lead-in, writes `mic.wav`, `system.wav` (other headsets × fixed gain), `mixed.wav`, `reference.json` (words with speaker, track, times, scored, overlap and critical flags), `meta.json` and `fixtures.lock.json`; `verify_lock` rejects missing or changed files.
   - `score.py`: verifies the lock and the run's fixture hashes, rebuilds each track's display from the events, and writes `metrics.json` per clip: non-overlap WER (jiwer, with substitutions, deletions and insertions), time-constrained matching (longest common subsequence where a match needs equal text and a compatible time), first-display and settled latency per matched word, unmatched words and coverage, critical-word survival, corrections per 100 words and the longest rewritten tail, words shown during reference silence, decodes and decodes during silence per track, tcORC-WER (MeetEval) on clips with overlap, lag over time and gaps; run-level resource figures. Final-pass runs get WER and critical words only.
   - `report.py`: frozen `GATES`; groups live runs by configuration, pools clips, applies latency (with the slower tier), accuracy (against final-pass runs on the same clips) and endurance (soak clips: lag growth, overflow gaps, added memory, serious heat); recording safety is reported as measured elsewhere; per-clip tables and failure examples into `report.md`.

16. **Make and hooks-mcp:** `make bench-live` checks `BENCH_LIVE_MODELS`, `BENCH_LIVE_FIXTURES` and `BENCH_LIVE_OUT`, then `swift run -c release --package-path Packages/Transcription live-bench $(ARGS) --models … --fixtures … --out …`; non-gating, not in CI. `hooks_mcp.yaml` gets `bench_live` with an `ARGS` string parameter and the three variables as required environment variables, output tailed, timeout one hour.

17. **Manual-test staleness:** the recordable `tx_*` steps are already `not-run`; confirm.

## Tests

`LiveBenchTests` (Swift):
- `pacedSourceReleasesOnlyArrivedSamples`: on a clock that moves only when advanced, nothing is released before 100 ms, and after 250 ms exactly two steps.
- `virtualClockAdvancesWithoutWaiting`: 60 s of simulated steps finish in well under a second of wall time, the virtual clock reads 60 s, and the source is labeled simulated.
- `pathGuardRejectsProductionPaths`: the data folder, a folder inside it, `~` form, `..` traversal, a symlink into it, other letter case and the installed app are rejected; a sibling named `BiscottiBench` and a Data folder are accepted.
- `manifestRecordsAllRequiredFields`: every required key is present, model and fixture hashes match the files.
- `missingModelFailsWithClearMessage`: a missing folder, a missing model file and a missing tokenizer each name what is missing.
- `chunksMatchThePump`: two-track chunks are 250 ms per track at exact start times; mixed chunks are the sum; flush sends the remainder.
- `replayLogsEveryUpdateWithReleaseTimes`: a simulated replay with a scripted decoder writes every streamed update with step-aligned `t_release`, and `final.json` holds the finish updates.
- `costStatisticsUseNearestRank` and `windowOffsetsSpreadOverTheClip`.
- `clipNamesMustBeSingleComponents`.

`MethodResolutionTests`: `currentMethodExposesModelAndFinalPassOptions`.

`Tools/live_bench/tests` (pytest via `uv run pytest`, no network):
- `test_wer_counts_sub_del_ins`
- `test_latency_keeps_repeated_words_distinct`
- `test_latency_reports_unmatched_words`
- `test_gate_thresholds_are_frozen`
- `test_fixture_lock_rejects_hash_mismatch`
- `test_cache_cap_is_enforced`
- `test_normalization_spells_numbers_and_drops_fillers`
- `test_make_fixtures_uses_the_corpus_channel_map` (synthetic AMI tree; mic is the mapped headset, system the others with the fixed gain, reference tracks and lead-in)
- `test_make_fixtures_refuses_defective_meetings`
- `test_corrections_count_rewritten_tail_words`
- `test_decodes_during_silence_are_counted`
- `test_score_run_end_to_end` (synthetic run directory to `metrics.json`)
- `test_report_applies_gates` (a passing and a failing configuration, slower tier)

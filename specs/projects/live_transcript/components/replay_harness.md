---
status: complete
---

# Component: Replay Harness

The harness is kept on a separate reference branch, [`live-transcript-bench`](https://github.com/brainstencil/Biscotti/tree/live-transcript-bench), not in the app's source. This document is the design record.

## Purpose and scope

The experiment that picks the live engine. It replays public meeting audio at real-time speed through the shipping session code and scores the four gates in the functional spec.

The harness has two parts:

- **`live-bench`:** a Swift executable in `Packages/Transcription`.
- **`Tools/live_bench`:** Python, run through `uv`, for fixtures and scoring.

Not in scope: the recording-safety gate, which is the writer test in [live_audio_branch](live_audio_branch.md), and hardware checks.

## `live-bench` commands

```text
live-bench cost  --models DIR --model NAME --out DIR
live-bench run   --models DIR --fixtures DIR --out DIR
                 --option whisper-current | whisper-small | speechanalyzer
                 --interval 1|2|4 --mode mixed|two-track --clips ID[,ID...]
                 [--load none|call] [--virtual-clock] [--vocabulary-off]
live-bench check-paths --models DIR --fixtures DIR --out DIR
```

**Path guard:** every command first resolves `--models`, `--fixtures` and `--out` and exits with an error if any lies under `~/Library/Application Support/Biscotti` or the installed app. It never calls `ModelStorage` and never downloads Whisper weights. A missing model folder or SpeechAnalyzer asset fails with a message naming what is missing.

### `cost`

Loads the model once. Warms up with three decodes, then times ten decodes each of 2, 10 and 30 s of fixture audio with the session's decode options. Writes `cost.json` with each decode time and the median and p95 per length.

### `run`

1. **Source:** reads the clip's 16 kHz WAV tracks into memory. `PacedSource` releases 100 ms steps by `ContinuousClock` and exposes only samples whose time has arrived. With `--virtual-clock`, steps advance as fast as the session accepts them, and times are labeled simulated.
2. **Session:** runs the same session code as the app.
   - Whisper: `WhisperLiveSession` with `WhisperKitLiveDecoder`, in-process. The worker hosts the same type behind XPC.
   - SpeechAnalyzer: `SpeechAnalyzerLiveSession`.
   - The config matches `LiveSessionConfig` in the app, except `--vocabulary-off`. Gated runs pass no vocabulary.
3. **Chunks:** 250 ms `LiveAudioChunk`s per track, or summed in mixed mode, identical to the app's pump.
4. **Events:** every `LiveTrackUpdate` is written to `events.jsonl` with `t_release` (source time), `t_event` (monotonic) and the update.
5. **Finish:** calls `finish(timeout: .seconds(10))`, then writes `final.json`.
6. **Manifest:** writes `manifest.json` with:
   - repo commit and argmax-oss-swift revision,
   - model folder name and SHA-256 of its files,
   - machine model, chip, RAM and OS,
   - options, fixture hashes, warm or cold,
   - Low Power Mode and thermal state at start.
7. **Resources:** every second, samples system-wide memory in use with `host_statistics64` (active, wired and compressed pages) into `resources.jsonl`, against a 30-second baseline taken before the session starts under the same simulated load. The endurance gate's memory limit uses this baseline-adjusted system figure, so SpeechAnalyzer's model, which runs outside the process, counts the same as Whisper's in-process model. Process resident memory, memory pressure and thermal-state changes are recorded as diagnostics.
8. **Latency scope:** the harness measures session-result latency. The app adds XPC delivery, update merging and rendering; signposts in the app measure that part during a hardware check.

**`--load call`** runs simulated call load in the same process: two threads at 60% duty cycle, and a Metal matrix-multiply loop sized to keep the GPU about 30% busy. Reports label it "simulated call load".

## `Tools/live_bench` (Python via `uv`)

A `uv` project with pinned dependencies (`numpy`, `soundfile`, `meeteval`, `jiwer`, `pytest`).

| Script | Does |
|---|---|
| `fetch_ami.py` | Downloads the chosen AMI headset tracks and manual annotations v1.6.2 from official URLs, saves license and attribution text, and writes SHA-256 hashes. Refuses to grow the cache past 2 GB. |
| `make_fixtures.py` | Cuts the frozen clip list; builds `mic.wav` (one headset), `system.wav` (the other headsets summed with fixed gain and headroom) and `mixed.wav`, all 16 kHz mono; writes `reference.json` (words with speaker, start, end) and `fixtures.lock.json` (hashes, annotation version, channel map, gains, seed, split). |
| `score.py` | For one run: WER with substitutions, deletions and insertions on non-overlap speech; MeetEval tcORC-WER on overlap clips (diagnostic); latency from reference word end to first correct display and to settled display, aligned by sequence and time; match coverage; the critical-word list; corrections per 100 words, longest rewritten tail, text during silence. Writes `metrics.json`. |
| `report.py` | Applies the four gates with frozen thresholds to one or more runs and writes `report.md` with pass or fail per gate, per-clip tables and failure examples. |

**Fixture layout:**

```text
<fixtures>/<clip-id>/mic.wav, system.wav, mixed.wav, reference.json, meta.json
<fixtures>/fixtures.lock.json
```

**Clip set:**
- One 90-second smoke clip.
- Six 3-minute calibration clips.
- Six 3-minute validation clips from different sessions.
- One continuous 45-minute soak recording.

Clips are chosen from the annotations to cover a long uninterrupted turn, fast turn-taking, natural overlap, short interjections, names, numbers and negations, and sparse speech. Each scored crop starts with lead-in audio. Known defective AMI recordings are excluded, and the corpus's participant-to-channel map is used, never an assumed one. The list is frozen in `fixtures.lock.json` before any option is compared, and no clip is picked by which option handles it best.

## Running it

- **Make target:** `make bench-live ARGS="run --option whisper-current --interval 2 --mode two-track --clips smoke"`. It reads `BENCH_LIVE_MODELS`, `BENCH_LIVE_FIXTURES` and `BENCH_LIVE_OUT` from the environment and passes them as flags. It is non-gating and not part of CI, like `make bench`.
- **hooks-mcp:** a `bench_live` entry in `hooks_mcp.yaml`.
- **Folders:** models come from an existing model cache that holds `argmaxinc/whisperkit-coreml/<model>`; fixtures and output go in folders of your choice, outside the app's data.
- **Results:** the experiment phase writes its findings and the engine decision to `specs/research/live_transcription/README.md`, and adds a pointer to it in `specs/research/argmax/README.md`'s live-captions note.

## Dependencies

- Depends on: `LiveTranscription`, ArgumentParser (already used by `transcribe-cli`), Metal.
- Used by: the experiment phase only.

## Test plan

`LiveBenchTests` (Swift):
- `pacedSourceReleasesOnlyArrivedSamples`
- `virtualClockAdvancesWithoutWaiting`
- `pathGuardRejectsProductionPaths`
- `manifestRecordsAllRequiredFields`
- `missingModelFailsWithClearMessage`

`Tools/live_bench/tests` (pytest via `uv run pytest`):
- `test_wer_counts_sub_del_ins`
- `test_latency_keeps_repeated_words_distinct`
- `test_latency_reports_unmatched_words`
- `test_gate_thresholds_are_frozen`
- `test_fixture_lock_rejects_hash_mismatch`
- `test_cache_cap_is_enforced`

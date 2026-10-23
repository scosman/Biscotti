# STTLab Experiment — Runbook

This document describes how to run the Apple SpeechTranscriber validation
experiment end to end: from the home Mac (macOS 15+), to the runner Mac
(macOS 26 or later), and back.

When the experiment is complete, remove `EXPERIMENT_PACKAGES` from the
root `Makefile` and delete the `experiments/STTLab` directory.

---

## Prerequisites

- **Home Mac:** macOS 15+, Apple Silicon, Biscotti installed with at least
  10 meetings recorded (both mic + system tracks, 2+ speakers each).
  WhisperKit models already downloaded (Biscotti does this on first
  transcription).
- **Runner Mac:** macOS 26 or later (first run: macOS 26.5), Apple Silicon.
- **OpenRouter account** with API key and credit. Confirm the reference
  model's data retention policy meets your ZDR requirement before the
  first upload (functional_spec section 9).

## Step 1: Home Mac — Prep

All commands use `--workspace ~/STTLabData/run1` (or any path outside
the repo). Data is never committed.

```bash
# Set the workspace for all commands.
export WS=~/STTLabData/run1

# 1a. Select meetings (proposes 10: 5 x 30 min, 5 x 60 min).
swift run --package-path experiments/STTLab sttlab select --workspace "$WS"

# Review ~/STTLabData/run1/selection.json — remove any meeting you do not
# want uploaded to the cloud. Edit locale per meeting if needed.

# 1b. Confirm the selection (locks the meeting list, assigns IDs).
swift run --package-path experiments/STTLab sttlab confirm --workspace "$WS"

# 1c. Build the bundle (merges audio into mono 16 kHz WAV per meeting).
swift run --package-path experiments/STTLab sttlab bundle --workspace "$WS"
```

## Step 2: Home Mac — Run Home Engines

```bash
# Set the OpenRouter API key (never saved to disk).
export OPENROUTER_API_KEY=sk-or-...

# 2a. Probe the reference model (sends 60 s, checks word timestamps).
swift run --package-path experiments/STTLab sttlab reference \
    --workspace "$WS" --probe

# 2b. Run all three home engines in sequence.
#     Whisper -> SpeakerKit diarization -> Reference (OpenRouter).
#     The reference step asks for consent before uploading.
swift run --package-path experiments/STTLab sttlab home-run \
    --workspace "$WS"

# Or run them individually:
#   sttlab whisper --workspace "$WS"
#   sttlab diarize --workspace "$WS"
#   sttlab reference --workspace "$WS" --yes   (skip consent prompt)
```

Each engine is resumable. If a meeting fails, re-run the same command to
retry only the failed items.

## Step 3: Package the Runner App

```bash
cd experiments/STTLab
scripts/package_runner.sh
```

This builds `build/STTLabRunner.app` (ad-hoc signed) and
`build/STTLabRunner.zip`.

## Step 4: AirDrop to Runner Mac

Send these to the runner Mac via AirDrop:

1. The **bundle folder**: `~/STTLabData/run1/bundle/`
2. The **runner app**: `experiments/STTLab/build/STTLabRunner.zip`

On the runner Mac, unzip the app. Right-click and choose "Open" to get
past Gatekeeper (ad-hoc signed).

## Step 5: Runner Mac — Run Apple SpeechTranscriber

Open STTLabRunner.app:

1. Select the bundle folder.
2. Click **Run**. The app processes each meeting through Apple
   SpeechTranscriber and shows progress.
3. When done, the results folder appears next to the bundle
   (`<bundle-parent>/<bundle-name>-results/`).

**Alternative (CLI mode):**

```bash
./STTLabRunner.app/Contents/MacOS/STTLabRunner --cli /path/to/bundle
```

## Step 6: AirDrop Results Back

Send the entire results folder back to the home Mac via AirDrop.

## Step 7: Home Mac — Analyze (Prep)

Run `analyze prep` in **release mode** (the alignment DP is slow in
debug). This step computes disagreement regions between Apple and Whisper
and writes one `disagreement_report.json` per meeting.

```bash
swift run -c release --package-path experiments/STTLab sttlab analyze prep \
    --workspace "$WS" \
    --results /path/to/bundle-results \
    --analysis-dir "$WS/analysis"
```

Output: `$WS/analysis/<mid>/disagreement_report.json` for each meeting
that has both Apple and Whisper results.

## Step 8: LLM Judging

Feed each `disagreement_report.json` to an LLM (e.g. Claude) and ask it
to write a `disagreement_decision.json` in the same directory. The
decision file contains one entry per disagreement, with a `decision`
(`apple_wins`, `whisper_wins`, `both_acceptable`, or `unknown`) and a `severity`
(`high`, `med`, or `low`). It must include the `report_fingerprint`
from the report file.

Place each decision file next to its report:
`$WS/analysis/<mid>/disagreement_decision.json`.

Meetings without a decision file are treated as unjudged (the final
report still includes their WER metrics).

## Step 9: Home Mac — Analyze (Final)

Run `analyze final` to produce the report. This step re-runs the core
metrics pipeline and overlays LLM decisions onto the output.

```bash
swift run -c release --package-path experiments/STTLab sttlab analyze final \
    --workspace "$WS" \
    --results /path/to/bundle-results \
    --analysis-dir "$WS/analysis"
```

The report lands in `~/STTLabData/run1/report/`:

- `report.md` — the full Markdown report (LLM judgement section replaces
  the old tie-break section).
- `metrics.json` — machine-readable metrics (Codable `ReportModel`).
- `transcripts/<mid>/` — plain text and speaker-annotated transcripts
  per meeting per engine.

Re-run `analyze prep` and `analyze final` at any time on the saved data.
Prep never deletes existing decision files, so LLM judgements survive
re-runs. Final deletes and regenerates the output directory.

## Environment Variables

| Variable | Used by | Purpose |
|---|---|---|
| `OPENROUTER_API_KEY` | `sttlab reference` | OpenRouter API key (required for reference engine). Never saved to disk. |

## Cleanup

When the experiment is done:

1. Remove `EXPERIMENT_PACKAGES := experiments/STTLab` from the root `Makefile`.
2. Delete `experiments/STTLab/`.
3. Keep or archive `~/STTLabData/` as needed (it is outside the repo).

---

## Findings

*To be filled in after the experiment run.*

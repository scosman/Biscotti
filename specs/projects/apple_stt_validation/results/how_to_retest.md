# How to Re-Test

Use this to repeat the experiment, for example on a new macOS version (a new Apple speech model), a new Apple speech asset, or a new Whisper model. The full first-run runbook is `experiments/STTLab/NOTES.md`; this page covers what changes for a re-test and how to compare with run 1.

## What You Need

- The **run 1 workspace** (`~/STTLabData/run1`). It holds the meeting audio, the Whisper, diarization and reference outputs, and the run 1 judge work. It is private data and is never committed. If it is gone, start from scratch with NOTES.md (new meetings, new reference spend: run 1 cost $1.34 for 13.4 h).
- The STTLab experiment code on a branch where `experiments/STTLab` still exists.
- A runner Mac on the macOS version under test (macOS 26 or later; `SpeechTranscriber` needs it).
- For the LLM steps: Claude Code (or another agent runner) that can start sub-agents. Run 1 used Claude Opus 5.5, up to 20 agents at a time.

```bash
export WS=~/STTLabData/run1          # reuse run 1 inputs
export RUN=run2                      # name for this re-test
export J=experiments/STTLab/scripts/judge
```

## 1. Re-run only the engine that changed

**New macOS / Apple model (the usual case).** Whisper, diarization and the reference do not change, so reuse them.

1. Build the runner app on the home Mac: `experiments/STTLab/scripts/package_runner.sh` (writes `experiments/STTLab/build/STTLabRunner.zip`).
2. AirDrop `$WS/bundle/` and the zip to the runner Mac. Open the app (right-click → Open, it is ad-hoc signed).
3. Run the same bundle. Write the results to a new folder, so run 1 results stay intact. In the app, the results go next to the bundle as `<bundle>-results`; rename it, or use the CLI:
   ```bash
   ./STTLabRunner.app/Contents/MacOS/STTLabRunner --cli /path/to/bundle --results /path/to/bundle-results-$RUN
   ```
4. AirDrop the results folder back to `$WS/bundle-results-$RUN`.

**New Whisper model.** Change `ProductionSettings.sttModel`, move `$WS/home/whisper/` aside, and run `sttlab whisper --workspace "$WS"`. Then continue below with the run 1 Apple results.

## 2. Analyze prep into a new analysis folder

```bash
swift run -c release --package-path experiments/STTLab sttlab analyze prep \
    --workspace "$WS" --results "$WS/bundle-results-$RUN" --analysis-dir "$WS/analysis-$RUN"
```

This writes `$WS/analysis-$RUN/<mid>/disagreement_report.json`.

## 3. Reuse run 1 judgements, judge only what changed

Run 1 decisions are matched to the new regions by content (same Apple, Whisper and reference text, start within 3 s), not by ID. Regions where the new engine output is the same as before keep their run 1 decision. Only changed regions need an LLM.

```bash
# Copy run 1 judge work so new batches do not mix into it.
cp -r "$WS/judge_work" "$WS/judge_work-$RUN"

python3 $J/merge_decisions.py --analysis "$WS/analysis-$RUN" --work "$WS/judge_work-$RUN" status
python3 $J/merge_decisions.py --analysis "$WS/analysis-$RUN" --work "$WS/judge_work-$RUN" plan
```

`plan` writes `<mid>_rN.input.json` for each meeting with unmatched regions. Judge each file with one agent, using `$J/prompts/region_judge.md`: replace `{INPUT}` with the input path and `{OUTPUT}` with the same path ending in `.decisions.json`. For large files (more than about 250 regions), split first, or judge from scratch:

```bash
# From scratch (e.g. a completely new Apple model with very different output):
python3 $J/split_batches.py --analysis "$WS/analysis-$RUN" --work "$WS/judge_work-$RUN-fresh" --size 250
```

Agent tips from run 1:
- One agent per batch of up to 250 regions takes 5–10 min. At most 20 agents run at a time; keep a list so no batch is skipped.
- If the agents cannot write to `$WS` (sandbox), use a work folder under `$TMPDIR` and copy it to `$WS` afterwards.

When every meeting shows `unmatched=0`:

```bash
python3 $J/merge_decisions.py --analysis "$WS/analysis-$RUN" --work "$WS/judge_work-$RUN" write
```

This writes `disagreement_decision.json` next to each report, with the new report fingerprint.

## 4. Analyze final

```bash
swift run -c release --package-path experiments/STTLab sttlab analyze final \
    --workspace "$WS" --results "$WS/bundle-results-$RUN" \
    --analysis-dir "$WS/analysis-$RUN" --out "$WS/report-$RUN"
```

## 5. Optional extra passes

**Mistake categories** (technical term, number/version, name, dropped content, ...):

```bash
python3 $J/categorize.py --analysis "$WS/analysis-$RUN" --work "$WS/categorize-$RUN" build
# One agent per catN.input.json with $J/prompts/categorize_mistakes.md -> catN.result.json
python3 $J/categorize.py --analysis "$WS/analysis-$RUN" --work "$WS/categorize-$RUN" summarize
```

**Reference quality check** (only needed if the reference model changes, or to double-check):

```bash
python3 $J/refcheck_build.py --workspace "$WS" --work "$WS/refcheck-$RUN" --report "$WS/report-$RUN"
# One agent per batchN.json with $J/prompts/blind_accuracy.md -> batchN.result.json
# One agent per styleN.json with $J/prompts/blind_style.md -> styleN.result.json
python3 $J/refcheck_summarize.py --work "$WS/refcheck-$RUN"
```

## 6. Publish the results (no meeting content)

```bash
python3 $J/sanitize_report.py --report "$WS/report-$RUN" \
    --out specs/projects/apple_stt_validation/results/$RUN
```

This copies every number and drops all sections and fields that quote speech. Check the output before committing: the script prints any long string that survived, and you can grep for names or phrases you know occur in the meetings. Never commit anything from `$WS` directly.

## 7. Compare with run 1

Put these side by side (run 1 values from `overview.md`):

| Metric | Where |
|---|---|
| Pooled WER Apple / Whisper vs reference, and S / D / I | `report_stats.md` → Summary, WER Breakdown |
| LLM wins by severity (med + high is the fair comparison) | `report_stats.md` → LLM Judgement |
| Mistake categories for Apple (technical terms, numbers) | `categorize.py summarize` |
| Apple RTF and memory | `report_stats.md` → Speed, Memory |
| Apple run granularity (must stay whole-word) and timing deltas | `report_stats.md` → Word Timing |
| Speaker agreement A-W | `report_stats.md` → Speaker Alignment |

Run on the same machine as run 1 (M2 runner) when you compare speed; RTF numbers from different chips are not comparable.

## Known Caveats to Carry Forward

- The run 1 region judges did not all treat dropped filler words the same way (some `both_acceptable`, some low-severity wins). The current prompt is strict (`both_acceptable`). Low-severity win counts are not comparable across runs; med + high counts are.
- The m09 reference has no speaker transcript (`reference.speakers.md` is missing), so reference speaker-agreement numbers exclude m09.
- m13 (meditation, long silences) is a weak meeting for the reference; see `reference_quality.md`.

# Calibration Pass — Speaker Embeddings

This is the final step of the speaker embeddings project. The developer runs
these commands on the real database to set voiceprint matching thresholds from
measured data. See `architecture.md` section 12 and `functional_spec.md`
section 9.3.

---

## Prerequisites

- The Biscotti app must be **quit** (the CLI refuses to run while the app is open).
- Meetings should have confirmed speaker tags (`userSet == true`) — the more
  confirmed tags, the more accurate the metrics. Tag speakers in several meetings
  before running metrics.
- SpeakerKit models will download automatically on first run (~33 MB).

## Step 1: Backfill

Populate voiceprints for existing meetings that do not have them yet.

```bash
# Preview what will be processed (no changes):
swift run --package-path Packages/BiscottiKit voiceprint-cli backfill --dry-run

# Run the backfill:
swift run --package-path Packages/BiscottiKit voiceprint-cli backfill
```

Options:
- `--store PATH` — directory containing `Biscotti.store` (default:
  `~/Library/Application Support/Biscotti`)
- `--limit N` — process at most N meetings
- `--meeting UUID` — process only one specific meeting
- `--json` — write a JSON summary to stdout

## Step 2: Metrics

Evaluate matching accuracy using leave-one-meeting-out cross-validation.

```bash
# Both kinds, with the full sweep table:
swift run --package-path Packages/BiscottiKit voiceprint-cli metrics --kind both --sweep

# Save JSON for analysis:
swift run --package-path Packages/BiscottiKit voiceprint-cli metrics --kind both --sweep --json > calibration.json
```

Options:
- `--kind plda|raw|both` — which embedding kind to evaluate (default: `both`)
- `--sweep` — show the full radius sweep table (FMR/MMR per radius)
- `--json` — output machine-readable JSON to stdout

## Step 3: Choose thresholds

From the metrics output, set per-kind values:

| Parameter | How to choose |
|---|---|
| `acceptRadius` (R) | Start from the Equal Error Radius (EER) in the sweep. Increase for more recall, decrease for more precision. |
| `highDistance` | The distance where accuracy at the `high` confidence level is near 100%. Must be well below R. |
| `mediumDistance` | Between `highDistance` and R. Where accuracy is still good but with less evidence. |
| Default `kind` | Compare PLDA vs raw top-1 accuracy and EER. PLDA is expected to do better for cross-recording matching (it separates speaker identity from channel variation). |

## Step 4: Update code and record results

1. Update `VoiceprintConfig` defaults in
   `Packages/BiscottiKit/Sources/VoiceprintMatching/VoiceprintConfig.swift`.
2. Record the chosen values and the reasoning below.

---

## Results

_To be filled after running the calibration pass._

### Data summary

- Meetings with preferred transcripts:
- Meetings with confirmed speaker tags:
- Distinct confirmed people:

### PLDA metrics

- Trials:
- Top-1 accuracy:
- EER radius:
- High accuracy:

### Raw metrics

- Trials:
- Top-1 accuracy:
- EER radius:
- High accuracy:

### Chosen thresholds

| Parameter | PLDA | Raw |
|---|---|---|
| `acceptRadius` | | |
| `highDistance` | | |
| `mediumDistance` | | |

Default kind:

### Reasoning

_Why these values were chosen._

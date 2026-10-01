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
- `--same-person "A,B,C"` — names or emails of Person records that are the same
  human (for example `"Steve,steve@kiln.tech,scosman@gmail.com"`). Repeatable.
  Without this option, alias records count as confusions and as false matches,
  and almost every match shows as `ambiguous`. Use it for every human with more
  than one record.

To run `metrics` while Biscotti is open, run it on a copy of the store. The
"quit Biscotti" guard applies only to the app's own store directory:

```bash
mkdir -p /tmp/biscotti_snapshot
sqlite3 "file:$HOME/Library/Application Support/Biscotti/Biscotti.store?mode=ro" \
  ".backup '/tmp/biscotti_snapshot/Biscotti.store'"
swift run --package-path Packages/BiscottiKit voiceprint-cli metrics \
  --store /tmp/biscotti_snapshot --kind both --sweep --same-person "..."
```

Before you choose values, look at **Suspect tags**. A confirmed voiceprint that
is far from the person's other voiceprints is usually a wrong tag (for example,
two speakers with swapped tags). Correct it in the app and run again.

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

Calibration pass run on 2026-10-01, on the developer's store (a snapshot, after
backfill).

### Data summary

- Voiceprints: 341 per kind, from 118 meetings.
- Tagged people: 61. Most tags are LLM-inferred (178 inferred voiceprints,
  17 confirmed, 146 untagged).
- Distinct confirmed people: 8, after merging aliases. Only one person (the
  user) has 3 or more confirmed meetings. Speech is longer than 300 s for 15 of
  17 confirmed voiceprints.
- Aliases merged with `--same-person`: the user (4 records: name, two work
  emails, personal email), Sam, Ellen, Leonard, and Mike (2 or 3 records each).
- One wrong tag was found (the suspect-tag list): speakers 0 and 1 in
  "Mike><Steve 1:1" had swapped tags. The developer corrected it before the
  final run.

**This is a small sample.** 16 trials, mostly the user's voice, mostly on one
audio setup. Run the pass again when more people have confirmed tags.

### Distances between confirmed voiceprints (different meetings)

| Kind | Same person p50 / p90 / max | Different people min / p10 |
|---|---|---|
| PLDA | 0.13 / 0.40 / 0.44 | 0.45 / 0.66 |
| Raw | 0.10 / 0.32 / 0.57 | 0.62 / 0.70 |

Inferred tags are much less clean. The LLM had put the user's voice on other
names: the inferred "Mike" and "Sam" clusters were 0.02–0.06 from the user's
voice.

### Metrics with the chosen values (16 trials, 1 skipped, aliases merged)

| Kind | Top-1 | high | medium | ambiguous | low | EER radius |
|---|---|---|---|---|---|---|
| PLDA | 15/16 | 7/7 | 5/5 | 3/3 | 0/1 | 0.45 |
| Raw | 14/16 | 7/7 | 6/6 | 1/1 | 0/2 | 0.60 |

The EER radius is from the leave-one-meeting-out sweep, which includes
inferred tags. Their label errors put a floor of about 7% under the false-match
rate at every radius, so EER is a weak guide here.

Before calibration (values from before calibration, aliases merged, swap fixed):
PLDA top-1 15/16 with 13 of 14 matches `ambiguous` and no `high`.

### Chosen thresholds

| Parameter | PLDA | Raw |
|---|---|---|
| `acceptRadius` | 0.45 | 0.50 |
| `highDistance` | 0.20 | 0.20 |
| `mediumDistance` | 0.30 | 0.30 |

Default kind: **raw**.

Other changes:

| Parameter | Before | After |
|---|---|---|
| `inferredTagWeight` | 0.4 | 0.2 |
| `ambiguityDistanceGap` | 0.05 | 0 (exact tie only) |
| Best-K selection | 5 nearest meetings | 5 meetings with the highest `tagW × speechW × closeness` |

### Reasoning

- **Default kind raw.** Top-1 is a tie within noise: PLDA's one extra hit is a
  4-second clip. Raw separates people better: the closest confirmed different
  person is 0.62, against 0.45 for PLDA, and its false-match rate was lower at
  every radius. The data has almost no channel variation, which is where PLDA
  is expected to help. Both kinds are still saved, so we can change back with a
  one-line config change.
- **R.** All clean same-person distances are inside R (except one raw 0.57
  outlier). The closest confirmed different person is outside R. There is a
  margin for shorter speech, which gives noisier voiceprints.
- **high 0.20 / medium 0.30.** Same-person p50 is 0.10–0.13, and the user's
  matches are 0.03–0.08. Every `high` and `medium` match in the trials is
  correct.
- **Best-K by contribution.** With "5 nearest", the user's near inferred
  meetings pushed out all but one confirmed meeting, so `high` (≥2 confirmed)
  could not occur. With "5 strongest", `high` occurs 7/7, all correct.
- **Inferred weight 0.2 and gap 0.** Inferred clusters that the LLM put on the
  user's voice were within 0.05 of the true match. This made almost every match
  `ambiguous`. With these values, `ambiguous` shows only when the scores are
  really close.

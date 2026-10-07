# PLDA LLR Benchmark Results

Date: 2026-10-07. Data: developer store snapshot (367 voiceprints per kind,
135 meetings, 89 persons, 18 confirmed-tag trials after alias merging and
trials-without-history skipping).

> **Correction (2026-10-07, after review):** the "swapped tags" diagnosis for
> the Mike/Steve 1:1 meeting below is wrong — the tags were checked by ear and
> are correct. The misses come from wrong LLM-inferred Mike/Steve tags in other
> meetings, and the nearest-neighbour top-1 here ignores tag kind, so it carries
> inferred-label noise. The verdict is unchanged. See
> `specs/projects/plda_v2/project_overview.md` for the corrections and the plan.

## Question

Does PLDA LLR (log-likelihood ratio) scoring beat cosine distance for
voiceprint matching? The prior calibration pass used plain cosine on PLDA
vectors and found raw cosine won. This benchmark applies the proper LLR
formula with per-dimension phi weighting that cosine ignores.

## Method

Python benchmark (`Tools/plda_benchmark.py`) over a read-only SQLite snapshot.
Leave-one-meeting-out cross-validation, same protocol as `voiceprint-cli
metrics` (trials-without-history are skipped). Aliases merged for six groups
(Steve/3 records, Sam/1, Ellen/1, Leonard+Leon/2, Mike/2, Daniel/1).

The benchmark uses simple nearest-neighbor matching (find the person with the
best single-voiceprint score). The production pipeline (`VoiceprintMatcher`)
is more sophisticated: best-K meetings by contribution, tag weights, and
multi-level confidence. Production baseline numbers from `voiceprint-cli` are
reported alongside for comparison.

### Scoring methods

| Method | Space | Input normalization | Scorer | n |
|---|---|---|---|---|
| raw_cosine | 256-d raw | unit L2 | cosine distance | -- |
| plda_cosine | 128-d PLDA | unit L2 | cosine distance | -- |
| plda_llr_stored_n1 | 128-d PLDA | as stored (norms 15--18) | wespeaker LLR | 1 |
| plda_llr_stored_nest | 128-d PLDA | as stored | wespeaker LLR | speaking duration |
| plda_llr_renorm_n1 | 128-d PLDA | sqrt(128) L2 | wespeaker LLR | 1 |
| plda_llr_renorm_nest | 128-d PLDA | sqrt(128) L2 | wespeaker LLR | speaking duration |
| plda_llr_centered_n1 | 128-d PLDA | as stored, minus corpus mean | wespeaker LLR | 1 |
| phi_weighted_cosine | 128-d PLDA | unit L2 | phi-weighted cosine | -- |

Phi (128 between-class eigenvalues, range 25.88--0.57) copied verbatim from
argmax `ClusteringAlgorithms.swift:532-559`. LLR formula from wespeaker
`TwoCovPLDA.log_likelihood_ratio`, verified against VBx
`PLDA_scoring_in_LDA_space` (numerical agreement to 10 decimal places at n=1).

Stored PLDA centroids have L2 norms 11.9--19.7 (median 16.2), larger than
sqrt(128)=11.31. They are mean(PLDA(x)), not PLDA(mean(x)) -- the non-linear
length normalization inside the CoreML pipeline causes this. The "as stored"
LLR variants use these vectors without re-normalization; the "renorm" variants
re-normalize to sqrt(128).

## Production baseline (voiceprint-cli, same snapshot)

The production matcher (`VoiceprintMatcher`) on the same snapshot with the same
aliases:

| Kind | Trials | Top-1 | Skipped | EER radius | Confused pair |
|---|---|---|---|---|---|
| PLDA cosine | 18 | 17/18 (94.4%) | 1 | 0.45 | LP -> G |
| Raw cosine | 18 | 16/18 (88.9%) | 1 | 0.60 | Mike -> Steve, LP -> G |

The production pipeline's multi-meeting best-K aggregation with tag weights
and confidence levels is responsible for the large accuracy gap between these
numbers and the nearest-neighbor benchmark below.

## Results: confirmed trials (18 trials, 6 alias groups)

| Method | Top-1 | Top-1% | EER |
|---|---|---|---|
| plda_cosine | 12/18 | 66.7% | 0.111 |
| plda_llr_stored_n1 | 12/18 | 66.7% | 0.111 |
| plda_llr_stored_nest | 12/18 | 66.7% | 0.111 |
| plda_llr_renorm_n1 | 12/18 | 66.7% | 0.111 |
| plda_llr_renorm_nest | 12/18 | 66.7% | 0.111 |
| phi_weighted_cosine | 12/18 | 66.7% | 0.111 |
| plda_llr_centered_n1 | 11/18 | 61.1% | 0.111 |
| raw_cosine | 11/18 | 61.1% | 0.111 |

EER is 0.111 for all methods -- quantized by the 18 confirmed trials, it has
no discriminating power. Top-1 is likewise quantized: the only values possible
near the observed range are 11/18 or 12/18 (5.6pp steps).

Six of seven PLDA methods produce 12/18; five have identical mismatch sets.
`plda_llr_stored_n1` also scores 12/18 but trades two errors for two different
ones. `plda_llr_centered_n1` and `raw_cosine` both score 11/18 (one additional
error each, different errors).

McNemar exact test on the one discordant pair (PLDA cosine vs raw cosine):
b=1, c=0, p=1.0. Not significant.

## Pairwise verification (confirmed voiceprints, cross-meeting)

Top-1 accuracy on 18 trials has almost no resolution. To test whether the
scoring functions separate speakers differently, this section computes scores
for **all pairs of confirmed voiceprints from different meetings** (39 same-
person pairs, 116 different-person pairs, aliases merged). Unlike top-1,
pairwise verification uses every confirmed voiceprint, not just one per
meeting.

| Method | Same | Diff | EER | AUC | d' | Same p50/p90/max | Diff min/p10 |
|---|---|---|---|---|---|---|---|
| raw_cosine | 39 | 116 | 0.000 | 1.000 | 6.54 | 0.10 / 0.30 / 0.57 | 0.60 / 0.71 |
| plda_cosine | 39 | 116 | 0.000 | 1.000 | 5.69 | 0.12 / 0.37 / 0.44 | 0.45 / 0.65 |
| plda_llr_renorm_n1 | 39 | 116 | 0.004 | 1.000 | 5.55 | 42.0 / 30.1 / 27.4 | 27.8 / 18.3 |
| plda_llr_stored_n1 | 39 | 116 | 0.004 | 1.000 | 5.36 | 54.3 / 32.0 / 26.1 | 27.2 / 8.8 |
| plda_llr_centered_n1 | 39 | 116 | 0.004 | 1.000 | 5.03 | 36.8 / 16.3 / 12.4 | 12.7 / -2.5 |
| phi_weighted_cosine | 39 | 116 | 0.021 | 0.999 | 4.97 | 0.08 / 0.30 / 0.35 | 0.30 / 0.48 |

For distance methods, "Same max" and "Diff min" are the hardest cases (closest
to confusion); for LLR methods, "Same min" (lowest positive LLR) and "Diff
max" (highest impostor LLR).

d' (d-prime) is a scale-free separation measure: (mu_target - mu_nontarget) /
sqrt(0.5 * (var_target + var_nontarget)). Higher = better separation. It is
comparable across methods regardless of score scale.

### Pairwise findings

**Raw cosine separates speakers best** (d' = 6.54), followed by PLDA cosine
(5.69). All LLR variants rank below both cosine methods. The phi-weighted
cosine is worst (4.97).

Raw cosine has the widest gap between worst same-person pair (0.57) and closest
different-person pair (0.60). PLDA cosine has a smaller gap (0.44 vs 0.45).
Both achieve perfect pairwise EER = 0.000 on confirmed data, but raw cosine's
larger margin makes it more robust to noisy voiceprints.

This confirms what the prior calibration pass found: with almost no channel
variation in the current data, the PLDA transform (which is designed to remove
channel effects) compresses the embedding space without benefit.

### Mean-centered LLR

The LLR different-speaker hypothesis assumes zero mean in PLDA space. The
stored corpus mean has norm 8.37 (not near zero). To test whether centering
helps, the `plda_llr_centered_n1` method subtracts the corpus mean from all
vectors before scoring.

Result: **centering hurts.** Top-1 drops from 12/18 to 11/18, and d' drops
from 5.36 (stored) to 5.03 (centered). The stored centroids are mean(PLDA(x))
after non-linear length normalization; their non-zero mean is structural, not
a bias to correct. Centering removes signal.

## Hand-reviewed mismatches (confirmed trials only)

All mismatches involve confirmed tags (userSet=True). No tag is LLM-inferred
in this set.

### Common to five PLDA methods (6 trials)

These six trials are wrong for plda_cosine, plda_llr_renorm_n1,
plda_llr_renorm_nest, plda_llr_stored_nest, and phi_weighted_cosine.

1. **Meeting 231, speakers 0+1** (Mike -> Steve, Steve -> Mike). Mutual swap
   consistent with swapped tags. The prior calibration doc identified a meeting
   with Mike and Steve tags on the wrong speakers and corrected it before that
   calibration run. This snapshot (2026-10-07) still has the swapped tags --
   the correction was either not persisted or tags were re-assigned later.
   This is a data fix to make. Deducting these 2 trials would make the five
   PLDA methods 12/16, raw 11/16.

2. **Meeting 226, speaker 5** (Sam -> Steve). Sam has only 2 confirmed meetings
   in the corpus; when this one is left out, Sam's remaining voiceprint may not
   be distinctive enough. The production matcher gets this right (multi-meeting
   aggregation resolves the ambiguity).

3. **Meeting 363, speaker 1** (LP -> G). Two colleagues with similar voice
   profiles on a single recording. The production matcher also gets this wrong
   (the only confusion pair in the production baseline). **Genuine hard case.**

4. **Meeting 391, speaker 1** (Steve -> Leonard). The production matcher gets
   this right. In nearest-neighbor mode, a single close Leonard voiceprint
   outscores the Steve voiceprints, but the production pipeline's multi-meeting
   aggregation resolves this.

5. **Meeting 225, speaker 2** (Mike -> Leonard in PLDA, Mike -> Steve in raw).
   Both spaces get the wrong answer, with different wrong answers. Could be a
   noisy voiceprint or a genuine hard case. The production matcher gets this
   right.

### plda_llr_stored_n1 variant (12/18, different errors)

`plda_llr_stored_n1` scores 12/18 like the five methods above, but trades
errors 1a (meeting 231 spk 0) and 4 (meeting 391 spk 1) for two different
errors: meeting 226 spk 1 (Steve -> Mike) and meeting 391 spk 0 (Daniel ->
Mike). No net improvement.

### plda_llr_centered_n1 (11/18)

Centering adds one error beyond the common six: meeting 226 spk 1 (Steve ->
Mike) and meeting 391 spk 0 (Daniel -> Mike), but resolves meeting 231 spk 0.
Net: 7 errors.

### raw_cosine only (1 additional error)

6. **Meeting 226, speaker 3** (Leonard -> Sam). Raw cosine matches this to Sam;
   all PLDA methods correctly match to Leonard. The PLDA space resolves this
   one genuine confusion.

### Summary of mismatches

| Category | Count | Notes |
|---|---|---|
| Likely swapped tags | 2 | Meeting 231 Mike/Steve swap (data fix needed) |
| Production matcher resolves | 3 | Meetings 225, 226/spk5, 391/spk1 |
| Genuine hard case | 1 | Meeting 363 LP/G (production also wrong) |
| Raw-only error (PLDA resolves) | 1 | Meeting 226/spk3 Leonard |

The production pipeline resolves 5 of the 7 nearest-neighbor errors through
multi-meeting aggregation. Only the LP/G confusion persists.

## Recommendation

The user's binary was: (1) PLDA helps -- do a fresh branch to implement
properly, or (2) PLDA doesn't help -- remove it. The evidence supports a
nuanced answer.

### Option 2 (recommended): Do not implement PLDA LLR. Keep current config.

**Verdict: PLDA LLR does not help. Do not implement it.**

The default kind is already raw, set during calibration. Both kinds are stored.
No code changes needed.

#### Evidence

1. **LLR produces zero improvement over cosine.** Five of six LLR variants
   produce 12/18 on confirmed trials -- the same score as plain PLDA cosine.
   The sixth (centered) scores 11/18. Per-dimension phi weighting does not
   resolve any trial that cosine gets wrong.

2. **Raw cosine separates speakers best.** Pairwise verification on confirmed
   voiceprints (39 same, 116 different) shows raw cosine has the highest d'
   (6.54 vs PLDA cosine 5.69, best LLR 5.55). Raw cosine also has the widest
   same/different gap (0.57 vs 0.60). With almost no channel variation in the
   current data, the PLDA transform compresses the space without benefit.

3. **The production pipeline's multi-meeting aggregation is what matters.** The
   production matcher gets 17/18 PLDA and 16/18 raw on the same data. The
   5-trial gap between nearest-neighbor (12/18) and production (17/18) comes
   from best-K aggregation, tag weights, and confidence levels -- not from the
   scoring function. Improving the scoring function yields zero benefit when
   the pipeline already resolves the ambiguity.

4. **Mean-centering the corpus makes it worse.** The corpus mean has norm 8.37,
   violating LLR's zero-mean assumption. But centering hurts (d' 5.03 vs 5.36
   uncorrected, top-1 11/18 vs 12/18). The non-zero mean is structural (from
   the non-linear length normalization inside the CoreML pipeline), not a bias
   to correct.

5. **LLR scores are poorly suited to the confidence system.** Biscotti uses
   distance thresholds (high/medium/low/ambiguous) calibrated to the 0--2
   cosine range. LLR scores range from -167 to +122 (as-stored) or -42 to +82
   (renorm), with no natural threshold structure. Integrating LLR would require
   score calibration, which is not justified when the ranking is identical.

### Why not Option 1 (implement PLDA LLR properly)

The pairwise evidence is the strongest signal: raw cosine already has better
speaker separation than any PLDA method on this data (d' 6.54 vs best PLDA
5.69). Implementing PLDA LLR would add complexity for a method that separates
speakers *less well* than what ships today.

### Why not Option 2b (remove PLDA vectors entirely)

Removing PLDA vectors is not justified yet. The one confirmed-trial advantage
PLDA has (meeting 226/spk3 Leonard, which raw gets wrong) shows the PLDA space
*can* resolve confusions that raw misses. With more channel variation (e.g.,
meetings on different devices), the PLDA transform may help. Keeping both
kinds stored costs ~50 bytes per voiceprint (128 x float32) and no runtime
overhead (only the default kind is queried).

### If the answer were to change

If more confirmed data (50+ trials across varied audio setups) showed a PLDA
advantage, the simplest path would be to switch the default kind back to PLDA
(one-line config change). Full LLR is not worth the complexity -- it produces
worse separation than cosine on every measure tested.

## Data notes

- **Phi source:** `argmax-oss-swift` revision `0475cca`, branch
  `biscotti/v1.1.0-plda-centroids`, file
  `Sources/SpeakerKit/Pyannote/ClusteringAlgorithms.swift` lines 532--559.
  128 float values, `private static let betweenClassCovariance`.

- **LLR formula:** wespeaker `TwoCovPLDA.log_likelihood_ratio` (Apache-2.0).
  Verified numerically against VBx `PLDA_scoring_in_LDA_space` for n=1.
  Self-test mode (`--self-test`) checks formula agreement and hand-computed
  values.

- **Aliases merged:** Steve (3 records), Sam (1), Ellen (1), Leonard+Leon (2),
  Mike (2), Daniel (1). 6 groups, matched by name and email local part.

- **Stored centroid norms:** 11.9--19.7 (median 16.2). Corpus mean norm 8.37.
  These are mean(PLDA(x)): the non-linear length normalization inside the
  CoreML pipeline means averaging after normalization gives norms above
  sqrt(128).

- **Trials skipped:** 1 (truth person had no tagged voiceprint in the rest
  corpus). Same count as voiceprint-cli.

- **Mike/Steve swap (meeting 231):** The tags in this snapshot are still
  swapped. The calibration pass (2026-10-01) notes the swap was corrected
  before that run. Either the correction was not persisted, or tags were
  re-assigned later. This should be investigated and fixed in the live store.

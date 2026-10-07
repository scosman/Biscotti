---
status: draft
---

# PLDA v2 — Parked Plan and Findings

**State: parked (2026-10-07).** PLDA voiceprints are being removed from main
(branch `remove_plda`). This branch (`plda_v2`) keeps the research and the
benchmark so we can test PLDA again later. Add PLDA back only if a future
benchmark shows it helps.

## Why we looked again

The calibration pass (`specs/projects/speaker_embeddings/calibration.md`)
compared raw and PLDA voiceprints with plain cosine distance, and raw won.
Cosine is the wrong comparison for PLDA vectors: PLDA space has a per-dimension
between-speaker variance `phi`, and the correct score is the PLDA
log-likelihood ratio (LLR). Andrey (argmax) said the same in
[argmax-oss-swift PR #540](https://github.com/argmaxinc/argmax-oss-swift/pull/540).

## Findings

- Research: `specs/research/plda_scoring/summary.md` (PLDA/LLR theory,
  VBx/pyannote reference code, argmax SpeakerKit internals, PR #540 review).
- Benchmark: `Tools/plda_benchmark.py` (`uv run --with numpy`, has
  `--self-test`) and `specs/research/plda_scoring/benchmark_results.md`.
- **Correct LLR does not help on current data.** All LLR variants (as stored /
  sqrt(128) re-norm × n=1 / n from speaking duration) give the same top-1 as
  PLDA cosine (12/18). Pairwise separation over confirmed voiceprints only
  (39 same / 116 different pairs): raw cosine d′ 6.54, PLDA cosine 5.69, best
  LLR 5.55. Production matcher: PLDA 17/18, raw 16/18 (noise).
- **Argmax exposes no PLDA tools.** Phi is a private 128-float constant
  (`ClusteringAlgorithms.swift`). The projection is a separate CoreML model
  (`PldaProjector.mlmodelc`, input raw 256-d, output 128-d). There is no
  scoring function. The fork only adds `speakerPLDACentroidEmbeddings`.
- **What we tested is the fork's `mean(PLDA(window))` centroid**, not
  `PLDA(mean(raw))`. The projection is non-linear (length norms), so these
  differ. `PLDA(mean(raw))` is the more standard method (Kaldi/pyannote average
  x-vectors, then transform) and was **not** benchmarked.

## Corrections to `benchmark_results.md`

- Mismatch #1 ("Mike><Steve 1:1" has swapped tags) is wrong. The developer
  listened and confirmed the tags are correct. The matcher found the correct
  voices; the nearest voiceprints carry **wrong LLM-inferred tags** in two
  other meetings (Mike and Steve inverted). With confirmed voiceprints only,
  Steve's voice matches Steve (0.084); Mike has only a 5 s confirmed clip
  elsewhere (0.567, a coverage gap, not a wrong match).
- The benchmark's nearest-neighbour top-1 ignores tag kind (confirmed and
  inferred weigh the same), so its top-1 numbers carry inferred-label noise.
  Production weights inferred tags at 0.2. The pairwise analysis uses confirmed
  tags only and is the cleaner evidence. The verdict does not change.

## Plan if we come back to PLDA

1. **Expose the tools upstream** (argmax PR): PLDA projection
   (`project(raw) -> plda`), `phi`, and an LLR compare function. Needed
   regardless — the current SDK exposes none of them.
2. **Backfill from stored raw voiceprints — no audio re-run.** Stored raw
   voiceprints are the unnormalized Float32 raw centroids, which is a valid
   input to the projector. Use one definition everywhere: `PLDA(mean(raw))`
   for new recordings and for backfill. The fork's
   `speakerPLDACentroidEmbeddings` is then not needed.
3. **Benchmark first:** add a `PLDA(mean(raw))` variant (load
   `PldaProjector.mlmodelc` with CoreML, run it on stored raw centroids, score
   with cosine and LLR), score with confirmed-only enrollment and with
   production-style tag weighting, and re-run when there is more confirmed data
   (50+ trials, several people, varied audio setups — PLDA is expected to help
   most with channel variation).
4. Ship only if it beats raw on the pairwise separation and the production
   matcher. Then calibrate LLR scores (logistic regression) to fit the
   confidence levels.

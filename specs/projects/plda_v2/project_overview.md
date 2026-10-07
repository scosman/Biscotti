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

## Cross-mic test (2026-10-07, "New Mic Test" meeting)

PLDA's main claim is robustness to mic/room (channel) changes, and the library
benchmark cannot test that: ~98% of recordings use the same mic and room. So we
recorded one meeting with a very different mic and room and scored the new
Steve print (19 s of speech) against the 10 confirmed Steve prints and 11
confirmed other-person prints from the usual setup.

| Method | d′ (Steve vs others) | Rank of best Steve print (confirmed) |
|---|---|---|
| Raw cosine | 1.64 | 1st (narrowly: 0.759 vs 0.761) |
| PLDA cosine | 0.41 | 3rd (nearest is another person, 0.656) |
| PLDA LLR (4 variants) | 0.17–0.39 | 3rd–4th |
| Phi-weighted cosine | 0.10 | 4th |
| Control: usual-room Steve prints | 7.4–11.1 (all methods) | 1st (all methods) |

- **PLDA is worse than raw in the new room, not better.** Neither recognizes the
  speaker: raw Steve↔Steve goes from ~0.10 (same room) to 0.76–0.81 (cross
  room), the same as other people. Both are far outside the accept radius, so
  production returns "no match" (the safe failure).
- **Short speech does not explain it:** a 5 s clip in the usual setup is still
  0.41–0.53 from the same person.
- **The channel dominates raw space:** the two different people in the new room
  are 0.41 apart in raw (nearer than Steve to himself across rooms). PLDA
  separates them more (0.57) — it suppresses the shared channel somewhat — but
  does not bring Steve's prints from different rooms together.
- Limits: one meeting, 19 s of speech, possible mixed content from diarization,
  and "different mic" may also mean a different capture path (VPIO or not).

## Summary and next test

- **Make a variety of recordings with different mics/rooms/capture paths and
  test there.** That is the real use case PLDA exists for, and it is the only
  test that can show a PLDA win. Include several people, several setups each,
  and enough speech per speaker.
- **The backfill and benchmark against the whole library are important but are
  not the whole signal**, because the library is heavily weighted to one mic.
  Report cross-setup results separately from the library-wide numbers.
- Until a cross-setup test shows a win, PLDA stays out of main. More enrollment
  (confirmed tags from each setup, picked up by best-K matching) is the likely
  fix for cross-setup matching, not PLDA.

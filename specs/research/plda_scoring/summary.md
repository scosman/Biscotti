# Research: PLDA Scoring for Voiceprint Matching

## Bottom Line

Biscotti's stored PLDA voiceprints (128-dim centroids in the diagonalized PLDA space) can be scored with a correct PLDA log-likelihood ratio. The formula is a per-dimension sum that weights each dimension by its between-class eigenvalue `phi_d`; it is well-established (Kaldi, VBx, wespeaker all agree) and straightforward to implement. `phi` (128 floats, descending from 25.88 to 0.57) is hardcoded in argmax's `ClusteringAlgorithms.swift` and must be copied verbatim -- it is not public API and not in any model file. SpeakerKit exposes no scoring or comparison function. The stored vectors are already in the correct space (post CoreML pipeline); no re-projection is needed. Plain cosine on PLDA vectors ignores the per-dimension weighting and is expected to underperform LLR by ~10% EER -- the calibration pass that declared "raw won" was comparing PLDA cosine against raw cosine, not PLDA LLR against raw cosine. The cheapest benchmark path is a Python + numpy script that reads phi from source and PLDA vectors from the SQLite store.

## Key Findings

- **The LLR formula is settled and code-ready.** All three subtopics converge on the same per-dimension formula. For enrollment centroid `e` (mean of `n` embeddings) and test vector `t`, each in 128-d diagonalized PLDA space: same-speaker mean = `n * phi_d / (n * phi_d + 1) * e_d`, same-speaker variance = `1 + phi_d / (n * phi_d + 1)`, different-speaker variance = `1 + phi_d`. LLR = sum over d of the Gaussian log-likelihood difference. The `2*pi` terms cancel. For single-enrollment (`n=1`), this simplifies to the VBx `PLDA_scoring_in_LDA_space` coefficients (Lambda, Gamma, k). ([theory](./plda-theory-llr/summary.md), [implementations](./vbx-pyannote-implementations/summary.md))

- **Phi must be copied from argmax source.** It is a `private static let` array of 128 floats in `ClusteringAlgorithms.swift:532-559`. Not in any model file, not public API, not accessible at runtime. The benchmark must embed a literal copy. ([argmax](./argmax-speakerkit-and-stored-vectors/summary.md))

- **No PLDA scoring function exists in SpeakerKit.** VBx uses phi internally for iterative speaker assignment (`calculateLogLikelihoods`), but that function is coupled to the clustering algorithm and does not produce pairwise scores. `DiarizationResult` exposes only `cosineDistance` (raw embeddings). The LLR must be implemented from scratch. ([argmax](./argmax-speakerkit-and-stored-vectors/summary.md))

- **Stored PLDA centroids are usable but are a different statistical object than single embeddings.** They are arithmetic means of per-window `pldaEmbedding` values (post CoreML pipeline, unnormalized). This works with the LLR formula if you pass `n` (the window count). However, `mean(PLDA(x))` differs from `PLDA(mean(x))` because of the non-linear length normalization inside the CoreML model (Andrey confirmed this in PR #540). Whether this matters empirically can only be determined by the benchmark. ([argmax](./argmax-speakerkit-and-stored-vectors/summary.md), [theory](./plda-theory-llr/summary.md))

- **The `n` parameter matters but must be estimated.** The store has `speakingDuration` (seconds) but not per-centroid window count. Rough estimate: ~1 window/second of speaking time (10 s windows with ~1 s stride, filtered by voice activity). For the benchmark, `n=1` is a safe fallback that treats each centroid as a single embedding -- conservative but avoids hallucinating a count. ([argmax](./argmax-speakerkit-and-stored-vectors/summary.md), [theory](./plda-theory-llr/summary.md))

- **Cosine on PLDA vectors is provably suboptimal.** Cosine treats all 128 dimensions equally. PLDA LLR weights by phi_d, which ranges 45x (25.88 to 0.57). Cosine is a special case of PLDA scoring where all phi_d = 1 (Peng et al. 2022). Diagonal PLDA beats cosine by ~10% EER in published comparisons (Wang et al. 2022). ([theory](./plda-theory-llr/summary.md))

- **Length normalization radius: sqrt(dim) is the convention.** pyannote, Kaldi, and wespeaker all scale l2-normalized vectors by `sqrt(dim)`. Original VBx normalizes to unit length without scaling. Both work because the PLDA model parameters absorb the scale difference -- but using a different convention than what the model was trained with could cause problems if applied after the fact. The stored centroids are NOT length-normalized (raw arithmetic means), so the benchmark should length-normalize them to `sqrt(128)` before scoring to match the training pipeline. ([implementations](./vbx-pyannote-implementations/summary.md), [argmax](./argmax-speakerkit-and-stored-vectors/summary.md))

## Implications

The prior calibration result ("raw cosine wins over PLDA") used plain cosine on PLDA vectors -- the wrong comparison metric. The benchmark should compare:

1. **Raw cosine** (256-d raw centroids, cosine similarity) -- the current winner
2. **PLDA LLR** (128-d PLDA centroids, the formula above with `n=1` and optionally estimated `n`) -- the correct PLDA comparison
3. Optionally, **phi-weighted cosine** (`sum(phi_d * e_d * t_d) / norms`) as a simpler middle ground

If PLDA LLR wins, the path forward is to add a phi-aware scorer to `VoiceprintMatching` and switch the default. If raw cosine still wins despite correct LLR scoring, the PLDA voiceprints can be removed (the `mean(PLDA(x))` non-linearity or the centroid averaging may be washing out the PLDA advantage).

Implementation for the benchmark: a Python script is cheapest. Read PLDA vectors from `ZVOICEPRINT` (little-endian Float32 blobs, `ZKINDRAW='plda'`), embed phi as a numpy array, length-normalize centroids to `sqrt(128)`, and score all same-person vs different-person pairs with the wespeaker-style LLR formula. The existing `voiceprint-cli metrics` Swift tool could also be extended.

## Conflicts and Uncertainty

- **Length normalization of stored centroids.** The stored PLDA centroids are unnormalized arithmetic means. Theory says vectors should be length-normalized before PLDA scoring (Garcia-Romero & Espy-Wilson 2011). But these centroids are means of vectors that were individually length-normalized inside the CoreML model, and their average is NOT length-normalized. The benchmark should try both: scoring the raw centroids as-is, and re-normalizing them to `sqrt(128)` before scoring. The theory subtopic says skipping length normalization degrades EER by 10-50% relative; the argmax subtopic says no normalization is applied to the stored values.

- **Whether LLR is invariant to normalization convention.** Kaldi uses a phi-weighted norm (`sqrt(D / sum(x^2 / (phi+1)))`) that differs from plain l2-norm and sqrt(dim) scaling. Whether using one convention on vectors trained under another affects the LLR is not settled by this research. The VBx implementations subtopic flagged this; theory did not address it.

- **mean(PLDA(x)) vs PLDA(mean(x)).** Andrey from argmax flagged that these differ because length normalization is non-linear. Our stored centroids are `mean(PLDA(x))`, not `PLDA(mean(x))`. Whether this degrades LLR scoring quality is an empirical question the benchmark must answer -- theory alone cannot resolve it.

- **The `n` parameter for centroids.** Using `n=1` is conservative (trusts the centroid less, wider posterior). Using an estimated `n` from `speakingDuration / 1.0` is aggressive (trusts the centroid more, tighter posterior). Theory says `n` adjusts within-class variance shrinkage and matters for calibrated scores. The benchmark should try both and compare.

## Gaps

- **Actual phi magnitudes from pyannote .npz files were not inspected.** The VBx/pyannote subtopic could not load binary NumPy archives. The argmax phi values are the same underlying model parameters (pyannote community-1), so this is not blocking.

- **Per-centroid segment count is not stored.** Only `speakingDuration` exists. The mapping from seconds to window count (~1/s) is a rough estimate. If `n` matters, a future code change should store the actual count.

- **Whether re-normalizing stored centroids helps or hurts is not known.** Theory says length-norm is essential, but the centroids are means of already-normalized vectors. The benchmark must test both paths.

- **Calibration data.** Raw PLDA LLR scores are poorly calibrated in practice (theory subtopic). Standard fix is logistic regression on labeled trials. The benchmark can compare ranking performance (EER, min-DCF) without calibration, but setting an operational threshold requires it.

## Subtopics

- [PLDA theory and LLR scoring](./plda-theory-llr/summary.md) -- The math: two-covariance model, simultaneous diagonalization, per-dimension LLR formula, multi-enrollment scoring (centroid + n is best), preprocessing pipeline, cosine vs PLDA, calibration. Code-ready formulas from Kaldi and the literature.
- [VBx and pyannote PLDA implementations](./vbx-pyannote-implementations/summary.md) -- Reference Python code: VBx `PLDA_scoring_in_LDA_space` (n=1), wespeaker `log_likelihood_ratio` (n>=1), the two-stage transform pipeline, how phi is computed and sorted, SpeechBrain's full-covariance alternative.
- [Argmax SpeakerKit code and our stored vectors](./argmax-speakerkit-and-stored-vectors/summary.md) -- Where phi lives (hardcoded, private, 128 floats), the CoreML PLDA transform pipeline, what our stored centroids contain (unnormalized means of per-window PLDA embeddings), SQLite schema, PR #540 feedback, and the cheapest benchmark path.

# VBx and pyannote PLDA Implementations

## Bottom Line

The PLDA scoring formula used across VBx, pyannote, wespeaker, and community-1 is a per-dimension log-likelihood ratio that weights each dimension by phi (between-class variance). Two production-ready scoring functions exist in source: VBx's `PLDA_scoring_in_LDA_space` (batch N x M matrix, single-enrollment only) and wespeaker's `TwoCovPLDA.log_likelihood_ratio` (supports multi-enrollment via parameter n). Both assume vectors are in the PLDA-diagonalized space (within-class cov = I, between-class cov = diag(phi)). The transform pipeline to reach that space is: center by mean, l2-normalize (optionally scale by sqrt(dim)), LDA project from 256-d to 128-d, re-center, l2-normalize, then center by PLDA mean and rotate by the PLDA eigenvectors. Phi is computed by solving the generalized eigenvalue problem B v = lambda W v (B = between-class, W = within-class covariance), sorted in descending order. In VBx clustering, phi is used as the prior variance of the speaker model, not for pairwise LLR scoring. SpeechBrain provides a full-covariance PLDA scoring function that generalizes to non-diagonal cases.

## Key Findings

- **VBx `PLDA_scoring_in_LDA_space` is the canonical diagonal-PLDA pairwise LLR** — Source: [BUTSpeechFIT/VBx diarization_lib.py](https://github.com/BUTSpeechFIT/VBx/blob/master/VBx/diarization_lib.py). Uses per-dimension coefficients Lambda, Gamma, k derived from phi. Operates on centered, LDA-space vectors. Produces an NxM score matrix. Single-enrollment only (n=1). Reference: Burget et al. ICASSP 2011 eqs (7-8).

- **wespeaker `log_likelihood_ratio` supports multi-enrollment** — Source: [wenet-e2e/wespeaker two_cov_plda.py](https://github.com/wenet-e2e/wespeaker/blob/master/wespeaker/utils/plda/two_cov_plda.py). Takes parameter n (number of enrollment utterances). The posterior mean shrinks toward zero as n increases: `mean_d = n * phi_d / (n * phi_d + 1) * e_d`. The posterior variance is `1 + phi_d / (n * phi_d + 1)`. For n=1, this produces the same LLR as the VBx formula.

- **The transform pipeline has two stages** — Stage 1 (x-vector transform): center, l2-norm, LDA project (256 to 128), re-center, l2-norm. Stage 2 (PLDA transform): center by PLDA mean, rotate by eigenvectors of the generalized eigenvalue problem, truncate to lda_dim. See [vbx-transform-pipeline.md](./vbx-transform-pipeline.md) for code and comparison.

- **pyannote uses Kaldi-style sqrt(dim) scaling; original VBx does not** — pyannote.audio (merged [PR #1894](https://github.com/pyannote/pyannote-audio/pull/1894), Jul 2025) scales l2-normalized vectors by sqrt(dim) after each normalization step. Original VBx normalizes to unit length without scaling. Both work because the PLDA model parameters absorb the scale difference. The community-1 model files expect Kaldi-style scaling.

- **Phi is re-derived from Kaldi PLDA parameters, not used directly** — Both VBx and pyannote recover the original-space W and B matrices from Kaldi's `(mu, tr, psi)` format, then solve `eigh(B, W)` to get eigenvalues (phi) sorted descending. This enables clean truncation of low-information dimensions. Phi is sorted largest-first.

- **Dimensionality: 256-d to 128-d** — The community-1 model (WeSpeaker ResNet34 embeddings) uses 256-d raw x-vectors, reduced to 128-d by LDA, with PLDA operating in 128-d. pyannote's `PLDA` class defaults `lda_dimension=128`.

- **SpeechBrain uses full-covariance PLDA** — Source: [speechbrain PLDA_LDA.py](https://github.com/speechbrain/speechbrain/blob/develop/speechbrain/processing/PLDA_LDA.py). Uses eigenvoice matrix F (D x rank) and full residual Sigma (D x D). Produces LLR via matrix operations. More general but computationally heavier. Not interchangeable with the diagonal implementations without converting F and Sigma to diagonal form.

- **VBx clustering uses phi as prior variance, not for scoring** — In the VBx HMM algorithm, phi controls how strongly each PLDA dimension influences speaker model estimation via `invL = 1/(1 + (Fa/Fb) * N * Phi)`. The Fa and Fb hyperparameters scale this influence.

## Details

- [vbx-transform-pipeline.md](./vbx-transform-pipeline.md) — The exact two-stage transform from raw x-vectors to PLDA space, comparing VBx, pyannote, and grikdotnet implementations. Code snippets for each step. Read when you need to know what normalization is applied and whether stored vectors match.
- [plda-scoring-functions.md](./plda-scoring-functions.md) — All five PLDA scoring functions found across VBx, grikdotnet, wespeaker, SpeechBrain, and VBx/Kaldi. Per-dimension formulas, multi-enrollment support, and a comparison table. Read when implementing a scoring function.
- [phi-computation-and-usage.md](./phi-computation-and-usage.md) — How phi is computed from Kaldi PLDA parameters (generalized eigenvalue problem), how it is sorted and truncated, and how it is used differently in VBx clustering (prior variance) vs pairwise scoring (dimension weights). Read when you need to load or interpret phi values.

## Open Questions / Gaps

- **Could not inspect actual phi values from community-1 `.npz` files.** The files are binary NumPy archives. To see the actual magnitudes, load them in Python: `np.load('plda.npz')['psi']` after the eigenvalue re-derivation. The argmax subtopic agent should inspect these from the downloaded model files.
- **Kaldi-style length normalization in `kaldi_ivector_plda_scoring_dense` uses a phi-weighted norm** (`sqrt(D / sum(x^2 / (phi+1)))`) that differs from both plain l2-norm and sqrt(dim) scaling. It is unclear whether this matters for scoring stored voiceprints that were normalized differently. The theory subtopic should clarify whether the LLR is invariant to normalization convention when the PLDA model was trained under a specific one.

## Sources

- [BUTSpeechFIT/VBx — diarization_lib.py](https://github.com/BUTSpeechFIT/VBx/blob/master/VBx/diarization_lib.py) — PLDA scoring function and Kaldi-compatible pipeline. Apache-2.0 license.
- [BUTSpeechFIT/VBx — vbhmm.py](https://github.com/BUTSpeechFIT/VBx/blob/master/VBx/vbhmm.py) — VBx diarization script showing transform pipeline and VBx invocation.
- [BUTSpeechFIT/VBx — VBx.py](https://github.com/BUTSpeechFIT/VBx/blob/master/VBx/VBx.py) — VBx clustering algorithm using phi as prior variance.
- [BUTSpeechFIT/VBx — kaldi_utils.py](https://github.com/BUTSpeechFIT/VBx/blob/master/VBx/kaldi_utils.py) — Kaldi PLDA file reader (mu, tr, psi format).
- [pyannote/pyannote-audio — core/plda.py](https://github.com/pyannote/pyannote-audio/blob/develop/src/pyannote/audio/core/plda.py) — PLDA class wrapping vbx_setup. Merged Jul 2025 via [PR #1894](https://github.com/pyannote/pyannote-audio/pull/1894).
- [pyannote/pyannote-audio — utils/vbx.py](https://github.com/pyannote/pyannote-audio/blob/develop/src/pyannote/audio/utils/vbx.py) — VBx setup, x-vector transform, PLDA transform, VBx clustering. Apache-2.0 (BUTSpeechFIT origin).
- [grikdotnet/pyannote-community1-plda-vbx — plda.py](https://github.com/grikdotnet/pyannote-community1-plda-vbx/blob/main/src/diarization/plda.py) — Independent re-implementation of VBx PLDA scoring (`score_in_lda_space`) with Kaldi-style normalization.
- [grikdotnet/pyannote-community1-plda-vbx — vbx.py](https://github.com/grikdotnet/pyannote-community1-plda-vbx/blob/main/src/diarization/vbx.py) — Full VBx clustering pipeline using `score_in_lda_space`.
- [wenet-e2e/wespeaker — two_cov_plda.py](https://github.com/wenet-e2e/wespeaker/blob/master/wespeaker/utils/plda/two_cov_plda.py) — Two-covariance PLDA with multi-enrollment LLR scoring. Apache-2.0 license.
- [wenet-e2e/wespeaker — plda_utils.py](https://github.com/wenet-e2e/wespeaker/blob/master/wespeaker/utils/plda/plda_utils.py) — PLDA utilities including Kaldi-style length normalization (`norm_embeddings`).
- [speechbrain/speechbrain — PLDA_LDA.py](https://github.com/speechbrain/speechbrain/blob/develop/speechbrain/processing/PLDA_LDA.py) — Full-covariance PLDA training and `fast_PLDA_scoring`. Apache-2.0 license.
- [pyannote-community/speaker-diarization-community-1 on HuggingFace](https://huggingface.co/pyannote-community/speaker-diarization-community-1) — Community-1 model including `plda/plda.npz` and `plda/xvec_transform.npz`. CC-BY-4.0.
- Landini F. et al., "Bayesian HMM clustering of x-vector sequences (VBx) in speaker diarization," Computer Speech & Language, 2022.
- Burget L. et al., "Discriminatively trained probabilistic linear discriminant analysis for speaker verification," ICASSP 2011.

# PLDA Theory and LLR Scoring

## Bottom Line

The PLDA LLR in diagonalized space is a per-dimension sum of Gaussian log-likelihood differences, with each dimension weighted by its between-class eigenvalue `psi_d`. The formula is code-ready and comes straight from Kaldi's `LogLikelihoodRatio` function: for each dimension, compute the predictive distribution under the same-speaker hypothesis (mean shrunk toward zero by factor `n*psi_d/(n*psi_d+1)`, variance `1 + psi_d/(n*psi_d+1)`) and the marginal under the different-speaker hypothesis (mean 0, variance `1+psi_d`), then take the log-likelihood difference. Multi-enrollment is handled correctly by passing the centroid and the segment count `n` -- this is mathematically equivalent to the full multi-session LLR under independence assumptions, and empirically outperforms score averaging and the full multi-session formula. Plain cosine on PLDA-space vectors is expected to underperform because it ignores per-dimension weighting; diagonal PLDA consistently beats cosine by ~10% EER. Length normalization is essential -- skipping it breaks the Gaussian assumptions that the LLR depends on.

## Key Findings

- **Exact per-dimension LLR formula** -- For dimension d with between-class eigenvalue `psi_d`, enrollment vector `u_enroll` (mean of n enrollment vectors), and test vector `u_test`: same-speaker mean = `n*psi_d/(n*psi_d+1) * u_enroll_d`, same-speaker variance = `1 + psi_d/(n*psi_d+1)`, different-speaker mean = 0, different-speaker variance = `1 + psi_d`. LLR = sum of per-dimension Gaussian log-likelihood differences. Code-ready pseudocode included in the detailed doc. Source: [Kaldi plda.cc](https://github.com/kaldi-asr/kaldi/blob/master/src/ivector/plda.cc)

- **Multi-enrollment: centroid + n is the correct and best approach** -- Averaging N enrollment vectors into a centroid and passing `n=N` to the scoring function is mathematically equivalent to the full multi-session LLR (Rajan et al. 2014). It is also the simplest and empirically best-performing method. The full multi-session LLR underperforms in practice due to the covariance shrinkage problem (enrollment embeddings are not truly independent). Source: [Rajan et al. 2014](http://www.cs.joensuu.fi/sipu/pub/Rajan_PLDA_Scoring_Variants.pdf)

- **Centroid inputs: within-class variance shrinks by 1/n in theory** -- When the input is a centroid of n embeddings, its within-class variance is I/n rather than I. The scoring function accounts for this through the `n` parameter. After length normalization, the magnitude information is partially lost, but passing `n` still adjusts the posterior shrinkage correctly. For stored length-normalized centroids without segment count, `n=1` is a conservative fallback. Source: [Kaldi plda.cc](https://github.com/kaldi-asr/kaldi/blob/master/src/ivector/plda.cc), `GetNormalizationFactor`

- **Preprocessing pipeline is critical: centering, whitening/LDA, length normalization to sqrt(dim)** -- Garcia-Romero & Espy-Wilson (2011) showed that whitening + length normalization makes Gaussian PLDA match heavy-tailed PLDA. Skipping length normalization degrades EER by 10-50% relative. The standard radius is sqrt(D). Source: [Garcia-Romero & Espy-Wilson 2011](https://www.isca-archive.org/interspeech_2011/garciaromero11_interspeech.html)

- **Cosine on PLDA-space vectors underperforms; phi-weighted cosine is partial improvement** -- Cosine treats all dimensions equally; PLDA LLR weights by psi_d. Diagonal PLDA beats cosine by ~10% EER (Wang et al. 2022). Phi-weighted cosine captures the weighting insight but misses self-terms, shrinkage, and log-determinant terms. It is a reasonable approximation for ranking but not for calibrated probabilities. Source: [Wang et al. 2022](https://arxiv.org/abs/2204.03965), [Peng et al. 2022](https://arxiv.org/abs/2204.10523)

- **LLR calibration: raw PLDA scores need affine correction** -- LLR is in nats; 0 = equal odds. Raw PLDA scores are usually poorly calibrated in practice. Standard fix: logistic regression with 2 parameters (scale alpha, offset beta), trained by minimizing binary cross-entropy on labeled trials. The threshold depends on the application's prior odds. Source: [Brümmer & Doddington 2013](https://arxiv.org/abs/1307.7981)

## Details

- [plda-model-and-llr-scoring.md](./plda-model-and-llr-scoring.md) -- The two-covariance PLDA model, simultaneous diagonalization, and the complete derivation of the per-dimension LLR formula with code-ready pseudocode. Read this for the exact implementation formula.
- [multi-enrollment-scoring.md](./multi-enrollment-scoring.md) -- Three strategies for multi-enrollment scoring (full multi-session, centroid+n, score averaging), why centroid+n wins, and how centroid inputs interact with variance shrinkage and length normalization. Read this for decisions about how to handle stored voiceprints.
- [preprocessing-pipeline.md](./preprocessing-pipeline.md) -- The required preprocessing steps (centering, whitening, length normalization, PLDA transform), why each matters, and the VBx pipeline specifics. Read this to verify that stored vectors have been correctly preprocessed.
- [cosine-vs-plda.md](./cosine-vs-plda.md) -- Why cosine underperforms in PLDA space, the proof that cosine is a special case of PLDA with psi=1, and analysis of phi-weighted cosine as an approximation. Read this for the decision on scoring method.
- [calibration-and-thresholding.md](./calibration-and-thresholding.md) -- LLR interpretation, the Bayes-optimal decision rule, standard logistic regression calibration, and practical thresholding advice. Read this for setting acceptance thresholds.

## Open Questions / Gaps

- **Brümmer's EM-for-PLDA notes** -- The direct PDF links on Brümmer's Google Sites page returned 404. The notes are cited extensively in the literature (Brümmer 2010a, 2010b) and their content is well-described in Ding 2018 and Ferrer et al. 2021, so the formulas are covered via secondary sources. The original PDFs may have moved.
- **Exact scaling of phi-weighted cosine cross-term** -- The analysis of phi-weighted cosine as an approximation is derived from the LLR formula expansion. I could not find a published paper that proposes or evaluates "phi-weighted cosine" as a named method; it may be novel. The analysis is inference from the math, not a cited finding.
- **Impact of segment count on length-normalized centroids** -- The interaction between length normalization and the `n` parameter when scoring pre-normalized centroids is discussed in Kaldi's `GetNormalizationFactor`, but I did not find a paper that specifically studies the error introduced by using `n=1` on centroids. The recommendation to use `n` when available is sound theory; the fallback to `n=1` is conservative but not empirically validated for this specific use case.

## Sources

- [Kaldi plda.cc](https://github.com/kaldi-asr/kaldi/blob/master/src/ivector/plda.cc) -- reference C++ implementation of PLDA scoring (2015+)
- [Kaldi plda.h](https://github.com/kaldi-asr/kaldi/blob/master/src/ivector/plda.h) -- class declarations and documentation
- [Ding 2018: "A Note on Kaldi's PLDA Implementation"](https://arxiv.org/abs/1804.00403) -- detailed explanation of the Kaldi formulas
- [Rajan et al. 2014: "From single to multiple enrollment i-vectors"](http://www.cs.joensuu.fi/sipu/pub/Rajan_PLDA_Scoring_Variants.pdf) -- DSP vol. 31, pp. 93-101; definitive multi-enrollment reference
- [Garcia-Romero & Espy-Wilson 2011: "Analysis of i-vector length normalization"](https://www.isca-archive.org/interspeech_2011/garciaromero11_interspeech.html) -- Interspeech 2011, pp. 249-252; introduced length normalization
- [Sizov et al. 2014: "Unifying PLDA Variants"](https://link.springer.com/chapter/10.1007/978-3-662-44415-3_47) -- LNCS 8621; three PLDA variants compared
- [Borgstrom 2020: "Discriminative PLDA"](https://www.ll.mit.edu/sites/default/files/publication/doc/discriminative-plda-speaker-verification-borgstrom-126429.pdf) -- closed-form LLR with P, Q matrices
- [Ferrer et al. 2021: "Robust Backend"](https://arxiv.org/abs/2102.01760) -- DCA-PLDA, calibration details
- [Peng et al. 2022: "Unifying Cosine and PLDA"](https://arxiv.org/abs/2204.10523) -- cosine as PLDA special case
- [Wang et al. 2022: "Cosine or PLDA?"](https://arxiv.org/abs/2204.03965) -- DPLDA vs cosine empirical comparison
- [Brümmer & Doddington 2013: "Calibration"](https://arxiv.org/abs/1307.7981) -- logistic regression calibration
- [Brümmer & van Leeuwen 2013: "Calibrated LR distributions"](https://arxiv.org/abs/1304.1199) -- Gaussian calibration theory
- [Landini et al. 2022: "VBx"](https://doi.org/10.1016/j.csl.2021.101254) -- Computer Speech & Language vol. 71; VBx diarization system
- [SpeechBrain PLDA_LDA module](https://speechbrain.readthedocs.io/en/0.5.7/API/speechbrain.processing.PLDA_LDA.html) -- Python PLDA scoring implementation

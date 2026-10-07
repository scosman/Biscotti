# Multi-Enrollment PLDA Scoring and Centroid Inputs

## The Three Multi-Enrollment Strategies

When N enrollment utterances are available for a speaker, three strategies exist for PLDA scoring (Rajan et al. 2014):

### 1. By-the-Book Multi-Session LLR

The theoretically optimal approach computes the full joint likelihood ratio over all N+1 vectors:

```
LLR = log p(w_1, ..., w_N, w_test | H_same) / p(w_1, ..., w_N | H_same) p(w_test)
```

Rajan et al. 2014 (eq. 11) give the closed form:

```
LLR = -delta(N+1) - (sum_i w_i + w_test)^T K_{N+1} (sum_i w_i + w_test)
      + delta(N) + (sum_i w_i)^T K_N (sum_i w_i)
      + delta(1) + 0.5 * w_test^T K_1 w_test + C

where:
  K_N = (Sigma + N * S * S^T)^{-1}
  delta(N) = log |Sigma + N * S * S^T|
```

In the **diagonalized space** (where within-class = I, between-class = diag(psi)), this simplifies enormously because K_N becomes diagonal:

```
K_N per dimension d = 1 / (1 + N * psi_d)
delta_d(N) = log(1 + N * psi_d)
```

### 2. Embedding Averaging (Centroid Scoring)

Average the N enrollment vectors into a single centroid, then score with the two-vector formula:

```
u_avg = (1/N) sum_{i=1}^N u_i
LLR = pldaLLR(u_avg, u_test, psi, n=1)    // WRONG: ignores N
LLR = pldaLLR(u_avg, u_test, psi, n=N)    // RIGHT: passes enrollment count
```

**Critical distinction:** simply averaging and scoring with `n=1` is *not* the same as the correct multi-enrollment formula. The parameter `n` controls the posterior shrinkage of the speaker mean, and passing `n=N` is essential.

In Kaldi's `LogLikelihoodRatio`, the `num_examples` parameter does exactly this. When you pass `n=N` and the averaged enrollment vector, the formula produces the same result as the full multi-session LLR (under the independence assumption).

**Proof of equivalence:** In the diagonalized space, the sufficient statistics for the speaker posterior are just the sum of the enrollment vectors. The mean of N vectors times N equals the sum, and the posterior formula uses `n * psi_d / (n * psi_d + 1) * u_avg_d`, which equals `psi_d * sum_d / (n * psi_d + 1)`. This is identical to the full multi-session posterior.

### 3. Score Averaging

Score each enrollment vector independently against the test vector, then average the scores:

```
LLR_avg = (1/N) sum_{i=1}^N pldaLLR(u_i, u_test, psi, n=1)
```

This is a heuristic. It does NOT correspond to the correct probabilistic model.

Source: [Rajan et al. 2014](http://www.cs.joensuu.fi/sipu/pub/Rajan_PLDA_Scoring_Variants.pdf), DSP vol. 31, pp. 93-101

---

## Practical Performance: Which Strategy Wins?

Rajan et al. 2014 compared all five methods experimentally on NIST SRE'10 and SRE'12:

**Key finding:** With length normalization enabled, **embedding averaging with correct n** is the most effective and simplest strategy. The full multi-session LLR tends to underperform in practice.

The reason: the full multi-session LLR assumes that enrollment embeddings are conditionally independent given the speaker. In practice, they are not (correlated recording conditions, phonetic content, etc.), which causes the posterior to be **overconfident** -- the variance shrinks too fast with N. This is called the **covariance shrinkage problem**.

From the [Interspeech 2022 paper by Wang et al.](https://arxiv.org/abs/2204.03965):
> "In light of reported results, the average of multiple speaker embeddings was adopted in baseline models due to its better performance."

**Recommendation for Biscotti:** Use embedding averaging with the correct `n` parameter (n = number of segments that contributed to the centroid). This matches the standard approach in the field.

---

## Centroid Inputs: Does Within-Class Variance Shrink by 1/n?

This is the question of what happens when the input is already a centroid (average) of multiple per-segment embeddings, rather than a single embedding.

### The Theory

If `u_avg = (1/n) sum_{i=1}^n u_i` where each `u_i` is an independent draw from `N(y, I)` (same speaker), then:

```
u_avg ~ N(y, I/n)
```

The within-class variance of the centroid is `I/n`, not `I`. The PLDA model assumes within-class variance = `I` (after diagonalization). A centroid with reduced variance is **not a valid single observation** under the standard PLDA model.

### Correct Handling: Use the n Parameter

The correct approach is exactly what Kaldi does: pass the centroid as the enrollment vector with `num_examples = n`. This tells the scoring function that the enrollment vector represents n observations, and the posterior shrinkage is adjusted accordingly.

From Kaldi's [plda.cc](https://github.com/kaldi-asr/kaldi/blob/master/src/ivector/plda.cc):
```cpp
mean(i) = n * psi_(i) / (n * psi_(i) + 1.0) * transformed_train_ivector(i);
variance(i) = 1.0 + psi_(i) / (n * psi_(i) + 1.0);
```

When `n` is large:
- `mean_d` approaches `u_enroll_d` (less shrinkage toward zero -- we're more confident about the speaker)
- `variance_d` approaches `1.0` (the predictive uncertainty is dominated by within-class noise of the test utterance alone)

When `n = 1`:
- Maximum shrinkage toward zero
- Maximum predictive variance

### The Length Normalization Complication

There is a subtlety: after length normalization, the centroid `u_avg` has been re-projected to unit length (or sqrt(D) length). This partially destroys the variance-shrinkage information. Kaldi handles this with its `GetNormalizationFactor`:

```cpp
// The normalization factor is sqrt(D / dot_prod) where:
// dot_prod = sum_d u_d^2 / (psi_d + 1/n)
```

This normalization ensures that the inner product `u^T (I/n + Psi)^{-1} u` equals the dimension D, which is the expected value under the model. It is **not** simple unit-length normalization -- it accounts for `n`.

### Should Scoring Account for Segment Count?

**Yes, if you have it.** Passing the segment count `n` to the scoring function is the theoretically correct thing to do. It adjusts:

1. The posterior mean (less shrinkage with more segments)
2. The predictive variance (less uncertainty with more segments)
3. The normalization factor (in Kaldi's implementation)

**If you don't have the segment count** (e.g., you only have the stored centroid), using `n=1` is a conservative fallback -- it applies maximum shrinkage and maximum variance, which is equivalent to treating the centroid as a single observation. This is suboptimal but not catastrophic.

---

## Interaction Between Centroid Inputs and Length Normalization

A stored centroid that was length-normalized after averaging has had its magnitude information erased. The magnitude of a pre-normalization centroid carries information about the speaker's consistency and the number of segments. After length normalization, all vectors have the same length, so the scoring function cannot recover this information.

**Practical impact for Biscotti:** If the stored PLDA centroids have been length-normalized (which they almost certainly have been, since VBx/SpeakerKit applies length normalization as part of the PLDA transform pipeline), then:

1. The actual within-class variance of the centroid is NOT `I/n` anymore -- length normalization has changed it
2. Passing `n` to the scoring function is still correct in principle (it adjusts the posterior), but the expected norm relationship assumed by Kaldi's normalization factor may not hold perfectly
3. For a practical system, using `n=1` on length-normalized centroids is the safest default. Using the true `n` may give modest improvements.

---

## Sources

- [Rajan et al. 2014: "From single to multiple enrollment i-vectors: Practical PLDA scoring variants"](http://www.cs.joensuu.fi/sipu/pub/Rajan_PLDA_Scoring_Variants.pdf) -- the definitive reference on multi-enrollment scoring strategies
- [Kaldi plda.cc](https://github.com/kaldi-asr/kaldi/blob/master/src/ivector/plda.cc) -- reference implementation with n parameter
- [Peng et al. 2022: "Unifying Cosine and PLDA Back-ends"](https://arxiv.org/abs/2204.10523) -- multi-enrollment cosine-PLDA relationship
- [Wang et al. 2022: "Scoring of Large-Margin Embeddings"](https://arxiv.org/abs/2204.03965) -- practical comparison

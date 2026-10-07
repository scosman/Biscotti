# Cosine Scoring vs PLDA LLR: When and Why They Differ

## Cosine is a Special Case of PLDA

Peng et al. (2022) proved that cosine scoring is a special case of PLDA scoring where both within-class and between-class covariances are identity matrices:

```
When W = B = I (precision matrices):
  Phi_w = I  (within-class covariance = identity)
  Phi_b = I  (between-class covariance = identity)
  psi_d = 1  for all dimensions

Then:
  Q = (I+2I)^{-1} - (I+I)^{-1} = (1/3 - 1/2)I = -1/6 I
  P = (I+2I)^{-1} = 1/3 I

  score = 0.5 * x1^T Q x1 + 0.5 * x2^T Q x2 + x1^T P x2
        = -1/12 ||x1||^2 - 1/12 ||x2||^2 + 1/3 x1^T x2
```

For unit-length-normalized vectors (`||x1|| = ||x2|| = 1`), the Q terms are constant, and the score reduces to:
```
score = 1/3 * x1^T x2 + const = 1/3 * cos(x1, x2) + const
```

This is monotonically equivalent to cosine similarity.

Source: [Peng et al. 2022: "Unifying Cosine and PLDA Back-ends"](https://arxiv.org/abs/2204.10523), Interspeech 2022

---

## Why Cosine on PLDA-Space Vectors Underperforms

When vectors are in the PLDA-transformed (diagonalized) space with non-uniform `psi`, plain cosine scoring **ignores the per-dimension weighting**. This is the central issue.

### The Dimensional Independence Problem

In the PLDA-diagonalized space:
- Dimension d has between-class variance `psi_d` and within-class variance `1`
- Dimension d's "discriminative power" (signal-to-noise ratio) is `psi_d`
- Dimensions with high `psi_d` are highly speaker-discriminative
- Dimensions with low `psi_d` are mostly noise

**Cosine treats all dimensions equally.** It computes `sum_d u1_d * u2_d / (||u1|| * ||u2||)`, giving equal weight to discriminative and noisy dimensions.

**PLDA LLR weights dimensions by their discriminative power.** The per-dimension LLR formula naturally gives more weight to dimensions with higher `psi_d`:

```
For dimension d with psi_d >> 1:
  variance_same ≈ 2 (numerically close)
  variance_diff ≈ psi_d (large)
  -> large contribution to LLR from agreement

For dimension d with psi_d ≈ 0:
  variance_same ≈ 1
  variance_diff ≈ 1
  -> negligible contribution regardless of values
```

### Empirical Evidence

Wang et al. (2022) found that for modern large-margin embeddings:

> "Simply discarding off-diagonal elements in the within-speaker covariance matrix of the PLDA model improved performance significantly with an average of 40.8% EER reduction and 35.1% minDCF reduction."

This diagonal PLDA (DPLDA) **outperforms cosine scoring consistently** with reductions of 10.9% EER and 4.9% minDCF, while being almost as simple to compute.

Source: [Wang et al. 2022](https://arxiv.org/abs/2204.03965)

### The Counterintuitive Observation

However, Wang et al. and Peng et al. also found cases where standard (full-covariance) PLDA underperforms cosine:

> "With the recently developed neural embeddings, the theoretically more appealing PLDA approach is found to have no advantage against or even be inferior to the simple cosine scoring."

The reason is **not** that PLDA scoring is wrong. It is that full-covariance PLDA overfits the off-diagonal correlations in the training data, while modern large-margin embeddings (AAM-Softmax, AM-Softmax) already produce embeddings with near-diagonal covariance structure. DPLDA (diagonal within-class) fixes this.

---

## Phi-Weighted Cosine: A Reasonable Approximation?

### Definition

A phi-weighted cosine would compute:
```
score = sum_d psi_d * u1_d * u2_d / (something)
```

This weights each dimension by its between-class variance, giving more importance to discriminative dimensions.

### Analysis

Let's compare this to the PLDA LLR for n=1. Expanding the LLR for a single dimension:

```
LLR_d = -0.5 * log((2*psi_d + 1) / (psi_d + 1)^2)
        - 0.5 * (u2_d - psi_d/(psi_d+1) * u1_d)^2 * (psi_d+1)/(2*psi_d+1)
        + 0.5 * u2_d^2 / (1 + psi_d)
```

This is a **quadratic** function of `u1_d` and `u2_d`, not a simple product. The cross-term (which is what phi-weighted cosine captures) is:

```
Cross-term coefficient for u1_d * u2_d:
  = psi_d / ((psi_d + 1) * (2*psi_d + 1))
```

This IS dimension-weighted, but by `psi_d / ((psi_d+1)(2*psi_d+1))`, not simply `psi_d`. For large `psi_d`, this weight goes as `1/(2*psi_d)` -- it actually *decreases* with very large psi, because highly discriminative dimensions saturate.

### Verdict: Phi-Weighted Cosine is a Partial Improvement

**Better than plain cosine:** Yes, it captures the essential insight that dimensions should be weighted differently.

**Worse than full PLDA LLR:** It misses:
1. The **self-terms** (`u1_d^2` and `u2_d^2`), which adjust for the vector's expected magnitude per dimension
2. The **shrinkage** toward zero in the same-speaker mean
3. The **log-determinant terms**, which are critical for correct LLR magnitude (calibration)
4. The correct **nonlinear weighting** function of psi_d

**A reasonable approximation** for *ranking* (deciding which speaker is closest) but not for *calibration* (interpreting the score as log-odds). If you only need to find the best match and don't need calibrated probabilities, phi-weighted cosine is a decent cheap proxy.

### What About Mahalanobis Distance?

A better approximation than phi-weighted cosine would be a **weighted Mahalanobis-like distance** in the PLDA space:

```
score = sum_d w_d * u1_d * u2_d - 0.5 * sum_d v_d * (u1_d^2 + u2_d^2)

where:
  w_d = psi_d / ((psi_d + 1)(2*psi_d + 1))     // cross-term weight
  v_d = psi_d^2 / ((psi_d + 1)^2 * (2*psi_d+1)) // self-term weight
```

This captures the quadratic form of the LLR but still drops the constant/log-det terms (acceptable for ranking).

---

## PLDA vs Cosine: Summary Table

| Property | Cosine | Phi-weighted cosine | PLDA LLR |
|----------|--------|-------------------|----------|
| Dimension weighting | None (uniform) | By psi_d | By f(psi_d), nonlinear |
| Self-terms (u_d^2) | No | No | Yes |
| Shrinkage toward prior | No | No | Yes |
| Calibrated output | No | No | Yes (in theory) |
| Multi-enrollment aware | Average only | Average only | Full posterior with n |
| Computational cost | O(D) | O(D) | O(D) |
| Training required | No | Needs psi | Needs full PLDA model |

---

## Sources

- [Peng et al. 2022: "Unifying Cosine and PLDA Back-ends"](https://arxiv.org/abs/2204.10523)
- [Wang et al. 2022: "Scoring of Large-Margin Embeddings: Cosine or PLDA?"](https://arxiv.org/abs/2204.03965)

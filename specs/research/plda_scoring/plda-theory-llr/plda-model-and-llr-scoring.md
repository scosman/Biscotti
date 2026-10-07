# PLDA Model and LLR Scoring: The Complete Derivation

## The Two-Covariance PLDA Model

The two-covariance PLDA model (Brümmer 2010, Sizov et al. 2014) is a hierarchical Gaussian generative model for speaker embeddings:

1. **Generate a speaker mean** from a prior:
   - `y ~ N(mu, Phi_b)` where `Phi_b` is the between-speaker covariance

2. **Generate an observation** (embedding) given the speaker:
   - `x | y ~ N(y, Phi_w)` where `Phi_w` is the within-speaker covariance

Equivalently, the marginal distribution of an observation is:
```
x ~ N(mu, Phi_b + Phi_w)
```

The model parameters are `theta = {mu, Phi_b, Phi_w}`, estimated via EM (Brümmer 2010a "EM for Probabilistic LDA"; Brümmer 2010b "EM for simplified PLDA").

Sources:
- Brümmer 2010: "EM for probabilistic LDA," tech report, https://sites.google.com/site/nikobrummer/
- Ding 2018: "A Note on Kaldi's PLDA Implementation," [arXiv:1804.00403](https://arxiv.org/abs/1804.00403)
- Sizov et al. 2014: "Unifying PLDA Variants," [Springer LNCS 8621](https://link.springer.com/chapter/10.1007/978-3-662-44415-3_47)

### Relationship to Other PLDA Variants

Three PLDA variants exist in the literature (Sizov et al. 2014):

| Variant | Model | Notes |
|---------|-------|-------|
| Standard PLDA (Ioffe 2006) | `x = mu + Fy + Gz + eps` | Factor model with speaker/channel subspaces |
| Simplified PLDA (Prince & Elder 2007) | `x = mu + Fy + eps` | Drops channel subspace G |
| Two-covariance PLDA (Brümmer 2010) | `x = y + eps`, `y ~ N(mu, Phi_b)` | Full-rank; equivalent to simplified when F is full-rank |

When the factor-loading matrix F has full rank, simplified PLDA and two-covariance PLDA are equivalent (Sizov et al. 2014). Modern speaker verification systems universally use the two-covariance form.

---

## Simultaneous Diagonalization

The key computational insight: `Phi_w` and `Phi_b` can be **simultaneously diagonalized**. There exists a non-singular matrix `V` such that:

```
V^T Phi_w V = I       (within-class covariance becomes identity)
V^T Phi_b V = Psi     (between-class covariance becomes diagonal)
```

where `Psi = diag(psi_1, psi_2, ..., psi_D)` with `psi_d >= 0`.

This is found by solving the generalized eigenvalue problem `Phi_b v = lambda Phi_w v`, or equivalently:

1. Compute the Cholesky (or eigendecomposition-based) whitening transform `S` such that `S^T Phi_w S = I`
2. In the whitened space, eigendecompose the projected between-class covariance: `S^T Phi_b S = U Psi U^T`
3. The full transform is `V = S U`

In Kaldi's implementation ([plda.h](https://github.com/kaldi-asr/kaldi/blob/master/src/ivector/plda.h)), this is stored as:
- `transform_`: the matrix V (called the diagonalizing transform)
- `psi_`: the vector of eigenvalues (between-class variances), sorted in decreasing order
- `mean_`: the global mean mu
- `offset_`: precomputed `-transform_ * mean_`

Source: [Kaldi plda.h](https://github.com/kaldi-asr/kaldi/blob/master/src/ivector/plda.h), [Ding 2018](https://arxiv.org/abs/1804.00403)

### Transformed Vectors

After applying the transform, a centered embedding in the diagonalized space is:
```
u = V^T (x - mu)
```

In this space:
- Within-class covariance = `I` (identity)
- Between-class covariance = `Psi = diag(psi_1, ..., psi_D)`
- Each dimension is **independent** of all others
- The marginal variance per dimension d is `1 + psi_d`

---

## The Closed-Form LLR: General Matrix Form

Given two embeddings `x_1` and `x_2`, the log-likelihood ratio for "same speaker" (H_s) versus "different speaker" (H_d) is:

```
LLR(x_1, x_2) = log p(x_1, x_2 | H_s) - log p(x_1, x_2 | H_d)
```

where:
- Under H_s: both come from the same (unknown) speaker, so `(x_1, x_2)` is jointly Gaussian with shared speaker mean
- Under H_d: independent draws from the marginal

The **general matrix form** (Ferrer et al. 2021, Borgstrom 2020, Rajan et al. 2014):

```
LLR = 2 w_1^T Lambda w_2 + w_1^T Gamma w_1 + w_2^T Gamma w_2 + w_1^T c + w_2^T c + k
```

where `w_i = x_i - mu` are centered embeddings, and:

```
Sigma_t = Phi_b + Phi_w              (total covariance)
Lambda  = Sigma_t^{-1} Phi_b (Sigma_t - Phi_b Sigma_t^{-1} Phi_b)^{-1}
Gamma   = Sigma_t^{-1} - (Sigma_t - Phi_b Sigma_t^{-1} Phi_b)^{-1}
```

Equivalently (SpeechBrain notation, from [PLDA_LDA.py](https://speechbrain.readthedocs.io/en/0.5.7/API/speechbrain.processing.PLDA_LDA.html)):
```
Phi = Sigma_t^{-1} - Tmp           (the Q matrix)
Psi_score = Sigma_t^{-1} Phi_b Tmp  (the P matrix, cross-term)
where Tmp = (Sigma_t - Phi_b Sigma_t^{-1} Phi_b)^{-1}
```

And the score is:
```
score = 0.5 * x_1^T Phi x_1 + 0.5 * x_2^T Phi x_2 + x_1^T Psi_score x_2^T + const
```

Sources:
- Borgstrom 2020: "Discriminative PLDA for Speaker Verification," [MIT Lincoln Lab](https://www.ll.mit.edu/sites/default/files/publication/doc/discriminative-plda-speaker-verification-borgstrom-126429.pdf)
- Ferrer et al. 2021: "A Speaker Verification Backend with Robust Performance," [arXiv:2102.01760](https://arxiv.org/abs/2102.01760)
- SpeechBrain: [PLDA_LDA module](https://speechbrain.readthedocs.io/en/0.5.7/API/speechbrain.processing.PLDA_LDA.html)

---

## The Closed-Form LLR: Per-Dimension Formulas in Diagonalized Space

**This is the code-ready version.** After simultaneous diagonalization, all matrices become diagonal and the LLR decomposes into a sum over independent dimensions.

Given two vectors `u_1` and `u_2` in the diagonalized space (after `u = V^T(x - mu)`), the LLR is:

```
LLR(u_1, u_2) = loglike_same(u_1, u_2) - loglike_diff(u_1, u_2)
```

### Kaldi's Exact Implementation

From [plda.cc](https://github.com/kaldi-asr/kaldi/blob/master/src/ivector/plda.cc) `LogLikelihoodRatio`, with `n` enrollment utterances that produced the enrollment vector:

**Same-speaker (given-class) log-likelihood**, per dimension d:
```
mean_d     = n * psi_d / (n * psi_d + 1.0) * u_enroll_d
variance_d = 1.0 + psi_d / (n * psi_d + 1.0)
```

The test vector `u_test` is evaluated under `N(mean, diag(variance))`:
```
loglike_same = -0.5 * sum_d [ log(variance_d) + (u_test_d - mean_d)^2 / variance_d ]
             - 0.5 * D * log(2*pi)
```

**Different-speaker (without-class) log-likelihood**, per dimension d:
```
variance_d = 1.0 + psi_d
```

The test vector is evaluated under `N(0, diag(1 + psi))`:
```
loglike_diff = -0.5 * sum_d [ log(1 + psi_d) + u_test_d^2 / (1 + psi_d) ]
             - 0.5 * D * log(2*pi)
```

**Final LLR** (the `log(2*pi)*D` terms cancel):
```
LLR = loglike_same - loglike_diff
    = sum_d [ -0.5 * log(variance_same_d / variance_diff_d)
              - 0.5 * (u_test_d - mean_d)^2 / variance_same_d
              + 0.5 * u_test_d^2 / variance_diff_d ]
```

### Derivation of the Per-Dimension Formulas

The math behind `mean_d` and `variance_d` comes from the posterior distribution of the speaker mean given the enrollment data.

In the diagonalized space, per dimension d, the model is:
```
y_d ~ N(0, psi_d)           (speaker prior, centered)
u_{i,d} | y_d ~ N(y_d, 1)   (observations given speaker)
```

Given n enrollment observations with sum `S_d = sum_{i=1}^n u_{enroll_i,d}`, the posterior of the speaker mean is:
```
y_d | data ~ N(mu_post_d, sigma_post_d^2)

where:
  mu_post_d    = psi_d / (1/n + psi_d) * (S_d/n)
               = n * psi_d / (n * psi_d + 1) * mean_enroll_d
  sigma_post_d^2 = psi_d / (n * psi_d + 1)
```

The predictive distribution for a new test observation `u_test_d` from the same speaker is:
```
u_test_d | data ~ N(mu_post_d, 1 + sigma_post_d^2)
                = N(mu_post_d, 1 + psi_d / (n * psi_d + 1))
```

This is the `variance_same_d = 1 + psi_d / (n*psi_d + 1)`.

For the different-speaker hypothesis, the test vector is from a random speaker:
```
u_test_d ~ N(0, 1 + psi_d)
```

This is `variance_diff_d = 1 + psi_d`.

**Important note on n:** When `n = 1` (single enrollment utterance), Kaldi passes the single transformed enrollment vector as `u_enroll`. When `n > 1`, the caller should pass the **average** of the n transformed enrollment vectors. The parameter `n` controls the posterior shrinkage. See multi-enrollment discussion in [multi-enrollment-scoring.md](./multi-enrollment-scoring.md).

### Compact Per-Dimension Formula

Combining and simplifying, the per-dimension LLR contribution is:

```
LLR_d = -0.5 * log((n*psi_d + 1 + psi_d) / ((n*psi_d + 1) * (1 + psi_d)))
        - 0.5 * (u_test_d - n*psi_d/(n*psi_d+1) * u_enroll_d)^2 / (1 + psi_d/(n*psi_d+1))
        + 0.5 * u_test_d^2 / (1 + psi_d)
```

For **n = 1** (pairwise scoring), this simplifies to:

```
alpha_d = psi_d / (psi_d + 1)           -- shrinkage factor
var_same_d = 1 + psi_d / (psi_d + 1)    -- = (2*psi_d + 1) / (psi_d + 1)
var_diff_d = 1 + psi_d                  -- = (psi_d + 1)

LLR_d = -0.5 * log(var_same_d / var_diff_d)
        - 0.5 * (u_test_d - alpha_d * u_enroll_d)^2 / var_same_d
        + 0.5 * u_test_d^2 / var_diff_d
```

Total: `LLR = sum_{d=1}^{D} LLR_d`

### Code-Ready Swift/Python Pseudocode

```swift
/// Compute PLDA LLR score between two vectors in the diagonalized space.
/// - u1, u2: transformed, centered vectors (dim D)
/// - psi: between-class variance per dimension (dim D)
/// - n: number of enrollment utterances that u1 represents (u1 is their mean)
func pldaLLR(u1: [Double], u2: [Double], psi: [Double], n: Int = 1) -> Double {
    var score = 0.0
    for d in 0..<u1.count {
        let nPsi = Double(n) * psi[d]
        
        // Same-speaker predictive distribution
        let meanSame = nPsi / (nPsi + 1.0) * u1[d]
        let varSame  = 1.0 + psi[d] / (nPsi + 1.0)
        
        // Different-speaker marginal distribution
        let varDiff = 1.0 + psi[d]
        
        // Per-dimension LLR contribution
        let diff = u2[d] - meanSame
        score += -0.5 * log(varSame) + 0.5 * log(varDiff)
        score += -0.5 * diff * diff / varSame
        score +=  0.5 * u2[d] * u2[d] / varDiff
    }
    return score
}
```

### Symmetry Note

The score `LLR(u_1, u_2)` is **not** symmetric in general when `n != 1`. When `n = 1`, the score IS symmetric (both vectors are treated as single observations). Kaldi's implementation treats u_1 as the enrollment (with n enrollment vectors averaged) and u_2 as the test. For symmetric pairwise scoring (e.g., in diarization clustering), use `n = 1` on both sides.

---

## Sources

- [Kaldi plda.cc source](https://github.com/kaldi-asr/kaldi/blob/master/src/ivector/plda.cc) -- the reference implementation
- [Kaldi plda.h header](https://github.com/kaldi-asr/kaldi/blob/master/src/ivector/plda.h) -- class documentation
- [Ding 2018: "A Note on Kaldi's PLDA Implementation"](https://arxiv.org/abs/1804.00403)
- [Borgstrom 2020: Discriminative PLDA](https://www.ll.mit.edu/sites/default/files/publication/doc/discriminative-plda-speaker-verification-borgstrom-126429.pdf)
- [Rajan et al. 2014: PLDA Scoring Variants](http://www.cs.joensuu.fi/sipu/pub/Rajan_PLDA_Scoring_Variants.pdf) (DSP vol. 31)
- [Ferrer et al. 2021: Robust Backend](https://arxiv.org/abs/2102.01760)
- [Sizov et al. 2014: Unifying PLDA Variants](https://link.springer.com/chapter/10.1007/978-3-662-44415-3_47)

# PLDA Pairwise Scoring Functions Across Implementations

This document catalogs every PLDA pairwise log-likelihood-ratio (LLR) scoring function found in VBx, pyannote, wespeaker, SpeechBrain, and the grikdotnet community-1 implementation. All operate on vectors already transformed into the PLDA space (within-class covariance = I, between-class covariance = diag(phi)).

## 1. VBx: `PLDA_scoring_in_LDA_space`

Source: [BUTSpeechFIT/VBx diarization_lib.py](https://github.com/BUTSpeechFIT/VBx/blob/master/VBx/diarization_lib.py)

```python
def PLDA_scoring_in_LDA_space(Fe, Ft, diagAC):
    """
    Fe     - NxD enrollment vectors (centered, in LDA space)
    Ft     - MxD test vectors (centered, in LDA space)
    diagAC - D-dimensional diagonal of across-class covariance (= phi)
    Returns NxM LLR score matrix
    """
    iTC = 1.0 / (1 + diagAC)              # 1/(1 + phi_d)
    iWC2AC = 1.0 / (1 + 2*diagAC)         # 1/(1 + 2*phi_d)
    ldTC = np.sum(np.log(1 + diagAC))      # log det(I + diag(phi))
    ldWC2AC = np.sum(np.log(1 + 2*diagAC)) # log det(I + 2*diag(phi))
    Gamma = -0.25 * (iWC2AC + 1 - 2*iTC)  # quadratic (self) coefficient
    Lambda = -0.5 * (iWC2AC - 1)           # cross-term coefficient
    k = -0.5 * (ldWC2AC - 2*ldTC)          # constant
    return np.dot(Fe * Lambda, Ft.T) + (Fe**2).dot(Gamma)[:, np.newaxis] + (Ft**2).dot(Gamma) + k
```

**Reference:** Burget et al., "Discriminatively trained probabilistic linear discriminant analysis for speaker verification," ICASSP 2011, equations (7-8).

### Per-dimension formula (unpacked)

For enrollment vector e and test vector t, both D-dimensional:

```
LLR = sum_d [Lambda_d * e_d * t_d + Gamma_d * (e_d^2 + t_d^2)] + k
```

Where:
```
Lambda_d = -0.5 * (1/(1 + 2*phi_d) - 1) = 0.5 * (1 - 1/(1 + 2*phi_d))
         = phi_d / (1 + 2*phi_d)

Gamma_d  = -0.25 * (1/(1 + 2*phi_d) + 1 - 2/(1 + phi_d))
         = 0.25 * (2/(1 + phi_d) - 1 - 1/(1 + 2*phi_d))

k = -0.5 * (sum_d log(1 + 2*phi_d) - 2 * sum_d log(1 + phi_d))
  = sum_d [log(1 + phi_d) - 0.5 * log(1 + 2*phi_d)]
```

This is a single-enrollment, single-test LLR. The assumption is n_enroll = 1 (one enrollment vector per speaker).

### Usage context

`PLDA_scoring_in_LDA_space` is called from `kaldi_ivector_plda_scoring_dense`, which applies its own transform pipeline (PCA + Kaldi-style length norm + PLDA eigendecomposition) before scoring. It produces an NxN similarity matrix for AHC clustering. It is NOT used by VBx clustering — VBx uses Phi differently (see phi-computation-and-usage.md).

## 2. grikdotnet: `score_in_lda_space`

Source: [grikdotnet/pyannote-community1-plda-vbx plda.py](https://github.com/grikdotnet/pyannote-community1-plda-vbx/blob/main/src/diarization/plda.py)

```python
def score_in_lda_space(enroll: np.ndarray, test: np.ndarray, psi: np.ndarray) -> np.ndarray:
    inverse_total = 1 / (1 + psi)
    inverse_twice = 1 / (1 + 2 * psi)
    gamma = -0.25 * (inverse_twice + 1 - 2 * inverse_total)
    cross = -0.5 * (inverse_twice - 1)
    offset = -0.5 * (np.log1p(2 * psi).sum() - 2 * np.log1p(psi).sum())
    return (enroll * cross) @ test.T + (enroll**2 @ gamma)[:, None] + (test**2 @ gamma) + offset
```

**Identical formula to VBx's `PLDA_scoring_in_LDA_space`.** Uses `np.log1p` instead of `np.log(1 + ...)` for numerical stability. Variable naming differs (`cross` = Lambda, `gamma` = Gamma, `offset` = k).

This function is actively used by the grikdotnet pipeline's `cluster_embeddings` for assigning unmatched speakers (called from `vbx.py`).

## 3. wespeaker: `TwoCovPLDA.log_likelihood_ratio`

Source: [wenet-e2e/wespeaker two_cov_plda.py](https://github.com/wenet-e2e/wespeaker/blob/master/wespeaker/utils/plda/two_cov_plda.py)

```python
def log_likelihood_ratio(self, transformed_train_embedding,
                         transformed_test_embedding, n):
    # --- log p(test | same speaker, given n enrollment utterances) ---
    mean = n * self.psi / (n * self.psi + 1.0) * transformed_train_embedding
    variance = 1.0 + self.psi / (n * self.psi + 1.0)
    logdet = np.sum(np.log(variance))
    sqdiff = transformed_test_embedding - mean
    sqdiff = np.power(sqdiff, 2.0)
    variance = 1.0 / variance
    loglike_given_class = -0.5 * (logdet + M_LOG_2PI * self.dim +
                                  np.dot(sqdiff, variance))

    # --- log p(test | different speaker) ---
    sqdiff = transformed_test_embedding
    sqdiff = np.power(sqdiff, 2.0)
    variance = self.psi + 1.0
    logdet = np.sum(np.log(variance))
    variance = 1.0 / variance
    loglike_without_class = -0.5 * (logdet + M_LOG_2PI * self.dim +
                                    np.dot(sqdiff, variance))

    loglike_ratio = loglike_given_class - loglike_without_class
    return loglike_ratio
```

### Key features

- **Supports multi-enrollment (n > 1).** The parameter `n` is the number of enrollment utterances. When `n = 1`, this reduces to the same formula as VBx's `PLDA_scoring_in_LDA_space` (after simplification; the constant terms cancel differently because wespeaker computes full log-likelihoods including the `M_LOG_2PI` terms, but the LLR is the same).
- **Operates on single vectors, not matrices.** It scores one enrollment-test pair at a time.
- **The enrollment vector is the average** of the n enrollment utterances (see `eval_sv` method).

### Per-dimension formula for multi-enrollment

Given enrollment centroid e (average of n utterances) and test vector t:

```
Same-speaker hypothesis:
  posterior_mean_d = n * phi_d / (n * phi_d + 1) * e_d
  posterior_var_d  = 1 + phi_d / (n * phi_d + 1)
  log p(t|same)   = -0.5 * sum_d [log(var_d) + (t_d - mean_d)^2 / var_d] - D/2 * log(2*pi)

Different-speaker hypothesis:
  marginal_var_d   = phi_d + 1
  log p(t|diff)    = -0.5 * sum_d [log(var_d) + t_d^2 / var_d] - D/2 * log(2*pi)

LLR = log p(t|same) - log p(t|diff)
```

The `D/2 * log(2*pi)` terms cancel in the ratio. What remains depends on phi and n.

### wespeaker transform pipeline

Before calling `log_likelihood_ratio`, wespeaker transforms embeddings via:

```python
def transform_embedding(self, embedding):
    transformed = self.transform @ embedding + self.offset
    # offset = -transform @ mu
    if self.normalize_length:
        transformed *= sqrt(dim) / norm(transformed)
    return transformed
```

This is: center by mu, apply transform, optionally Kaldi-style length normalize.

## 4. SpeechBrain: `fast_PLDA_scoring`

Source: [speechbrain/speechbrain PLDA_LDA.py](https://github.com/speechbrain/speechbrain/blob/develop/speechbrain/processing/PLDA_LDA.py)

SpeechBrain uses a **full-covariance** PLDA parametrization (not diagonal), making it fundamentally different from the other implementations.

```python
def fast_PLDA_scoring(enroll, test, ndx, mu, F, Sigma, ...):
    # Center
    enroll_ctr.center_stat1(mu)
    test_ctr.center_stat1(mu)

    # Precompute matrices
    invSigma = linalg.inv(Sigma)
    K = F.T @ (invSigma * scaling_factor) @ F
    K1 = linalg.inv(K + I)
    K2 = linalg.inv(2 * K + I)

    # Gaussian constant
    plda_cst = slogdet(K2)[1] / 2.0 - slogdet(K1)[1]

    # Score matrices
    Sigma_ac = F @ F.T
    Sigma_tot = Sigma_ac + Sigma
    Sigma_tot_inv = linalg.inv(Sigma_tot)
    Tmp = linalg.inv(Sigma_tot - Sigma_ac @ Sigma_tot_inv @ Sigma_ac)
    Phi_matrix = Sigma_tot_inv - Tmp
    Psi_matrix = Sigma_tot_inv @ Sigma_ac @ Tmp

    model_part = 0.5 * einsum('ij,ji->i', enroll @ Phi_matrix, enroll.T)
    seg_part = 0.5 * einsum('ij,ji->i', test @ Phi_matrix, test.T)
    scoremat = model_part[:, None] + seg_part + plda_cst + enroll @ Psi_matrix @ test.T
```

### Key differences from diagonal implementations

- **F** is the eigenvoice matrix (D x rank_f), not a diagonal
- **Sigma** is a full D x D residual covariance, not identity
- Uses matrix inverses and products, not element-wise operations
- Equivalent to the diagonal case when F is chosen so that F @ F.T = diag(phi) and Sigma = I

This is the most general formulation but is computationally heavier.

**References cited in code:**
- Garcia-Romero et al., "Analysis of i-vector length normalization," Interspeech 2011
- Weiwei-LIN et al., "Fast Scoring for PLDA with Uncertainty Propagation," Odyssey 2016
- Kong Aik Lee et al., "Multi-session PLDA Scoring of I-vector," Interspeech 2013

## 5. VBx `kaldi_ivector_plda_scoring_dense` (Kaldi-compatible pipeline)

Source: [BUTSpeechFIT/VBx diarization_lib.py](https://github.com/BUTSpeechFIT/VBx/blob/master/VBx/diarization_lib.py)

This is NOT a separate scoring function—it's a complete pipeline that includes PCA, Kaldi-style length normalization, and then calls `PLDA_scoring_in_LDA_space`.

```python
def kaldi_ivector_plda_scoring_dense(kaldi_plda, x, target_energy=0.1, pca_dim=None):
    plda_mu, plda_tr, plda_psi = kaldi_plda
    
    # PCA on test data (optional dimensionality reduction)
    energy, PCA = spl.eigh(np.cov(x.T, bias=True))
    PCA = PCA[:, :-pca_dim-1:-1]
    
    # Compute PLDA eigendecomposition in PCA-reduced space
    plda_tr_inv_pca = PCA.T @ np.linalg.inv(plda_tr)
    W = plda_tr_inv_pca @ plda_tr_inv_pca.T
    B = (plda_tr_inv_pca * plda_psi) @ plda_tr_inv_pca.T
    acvar, wccn = spl.eigh(B, W)
    
    # Transform and Kaldi-style length normalization
    x = (x - plda_mu) @ PCA @ wccn
    x *= np.sqrt(x.shape[1] / np.dot(x**2, 1.0 / (acvar + 1.0)))[:, np.newaxis]
    
    return PLDA_scoring_in_LDA_space(x, x, acvar)
```

The Kaldi-style length normalization here is:
```
x *= sqrt(D / sum_d(x_d^2 / (phi_d + 1)))
```

This is NOT simple l2-normalization. It weights each dimension by `1/(phi_d + 1)`, which is the inverse of the total (within + between) class variance. This normalization is specific to the Kaldi PLDA scoring recipe and ensures that the length of the vector reflects the PLDA model's expected scale.

## Comparison table

| Implementation | Function | Multi-enroll | Input space | Formula basis |
|---|---|---|---|---|
| VBx | `PLDA_scoring_in_LDA_space` | No (n=1) | Diagonal PLDA (W=I, B=diag(phi)) | Burget ICASSP 2011 |
| grikdotnet | `score_in_lda_space` | No (n=1) | Diagonal PLDA | Same as VBx |
| wespeaker | `TwoCovPLDA.log_likelihood_ratio` | Yes (n param) | Diagonal PLDA | Full LLR with n |
| SpeechBrain | `fast_PLDA_scoring` | No (single enrollment) | Full-covariance PLDA | Garcia-Romero 2011, Lee 2013 |
| VBx (Kaldi compat) | `kaldi_ivector_plda_scoring_dense` | No (n=1) | PCA-reduced + Kaldi length-norm | Burget ICASSP 2011 |

## Which to use for Biscotti's benchmark

The **wespeaker formula** is the most directly useful because:
1. It supports multi-enrollment (n > 1), which matters when matching against stored voiceprints built from multiple segments
2. It uses the diagonal PLDA parametrization (phi = psi), matching what argmax/pyannote produce
3. It is a clean, per-pair function rather than requiring matrix precomputation

The **VBx formula** (`PLDA_scoring_in_LDA_space`) is the right choice for batch scoring (NxM matrix), but is limited to n=1.

For the n=1 case, both formulas produce the same LLR value.

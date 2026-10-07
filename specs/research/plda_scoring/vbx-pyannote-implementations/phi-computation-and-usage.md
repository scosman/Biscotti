# Phi: Computation, Storage, and Usage in VBx and Related Systems

## What phi is

Phi (also called `psi`, `plda_psi`, `acvar`, or `diagAC` depending on the codebase) is the diagonal of the between-class (across-speaker) covariance matrix in the PLDA space. In this space:

- Within-class covariance = I (identity)
- Between-class covariance = diag(phi)

Each element `phi_d` represents how much variance in dimension d is explained by speaker identity versus noise. Higher phi_d means dimension d carries more speaker-discriminative information.

## How phi is computed from a Kaldi PLDA model

The Kaldi PLDA model stores three arrays:
- `mu` — mean vector
- `tr` — transform matrix that whitens within-class and diagonalizes between-class covariance
- `psi` — diagonal of between-class covariance in Kaldi's internal space

VBx and pyannote **re-derive** phi from these Kaldi parameters rather than using `psi` directly.

Source: [VBx vbhmm.py](https://github.com/BUTSpeechFIT/VBx/blob/master/VBx/vbhmm.py) and [pyannote vbx.py](https://github.com/pyannote/pyannote-audio/blob/develop/src/pyannote/audio/utils/vbx.py)

```python
# Step 1: Recover original-space covariance matrices from Kaldi format
# In Kaldi's space: within_kaldi = I, between_kaldi = diag(psi)
# Going back to original space:
#   tr.T @ within_kaldi @ tr = tr.T @ tr  =>  W_original = inv(tr.T @ tr)
#   tr.T @ between_kaldi @ tr = tr.T @ diag(psi) @ tr  =>  B_original = inv((tr.T / psi) @ tr)
W = np.linalg.inv(plda_tr.T.dot(plda_tr))
B = np.linalg.inv((plda_tr.T / plda_psi).dot(plda_tr))

# Step 2: Solve generalized eigenvalue problem
# Find eigenvectors v such that B @ v = lambda * W @ v
# This simultaneously whitens W and diagonalizes B
acvar, wccn = scipy.linalg.eigh(B, W)

# Step 3: Sort descending (eigh returns ascending order)
plda_psi = acvar[::-1]      # phi = eigenvalues = between-class variance per dimension
plda_tr = wccn.T[::-1]      # rotation matrix (eigenvectors as rows)
```

### Why re-derive instead of using Kaldi's psi directly?

1. **Sorting.** `scipy.linalg.eigh` returns eigenvalues in ascending order. Reversing puts the most discriminative dimensions first, enabling clean truncation.
2. **Numerical stability.** Re-solving the generalized eigenvalue problem can produce a cleaner decomposition than inverting and multiplying Kaldi's transform.
3. **Truncation.** The `lda_dim` parameter truncates `phi[:lda_dim]` and `plda_tr[:lda_dim, :]` to discard the least discriminative dimensions.

### Is phi sorted/truncated?

**Yes.** Phi is always sorted in descending order (largest eigenvalues first). Truncation is applied when `lda_dim < full_dim`:

```python
# VBx vbhmm.py
fea = (x - plda_mu).dot(plda_tr.T)[:, :args.lda_dim]
# ...
q, sp, L = VBx(fea, plda_psi[:args.lda_dim], ...)
```

```python
# pyannote PLDA class
@property
def phi(self):
    return self._plda_psi[:self.lda_dimension]
```

In practice, for the community-1 model, `lda_dim = 128` and `full_dim = 128`, so no dimensions are dropped. But the infrastructure supports it.

## How phi is used in VBx clustering

In VBx clustering (HMM-based), phi is NOT used for pairwise LLR scoring. Instead, it parameterizes the generative model's prior over speaker models.

Source: [VBx VBx.py](https://github.com/BUTSpeechFIT/VBx/blob/master/VBx/VBx.py)

```python
def VBx(X, Phi, loopProb=0.9, Fa=1.0, Fb=1.0, ...):
    D = X.shape[1]
    V = np.sqrt(Phi)                # between eqs (5) and (6)
    rho = X * V                     # eq (18): scale features by sqrt(phi)

    for ii in range(maxIters):
        # Speaker model posterior precision (eq 17):
        invL = 1.0 / (1 + Fa/Fb * gamma.sum(axis=0, keepdims=True).T * Phi)

        # Speaker model posterior mean (eq 16):
        alpha = Fa/Fb * invL * gamma.T.dot(rho)

        # Per-frame log-likelihood for each speaker (eq 23):
        log_p_ = Fa * (rho.dot(alpha.T)
                        - 0.5 * (invL + alpha**2).dot(Phi)
                        + G)
```

Key roles of Phi in VBx:
- **`V = sqrt(Phi)`** — scaling factor applied to feature vectors
- **`rho = X * V`** — phi-scaled features (eq 18), used as sufficient statistics
- **`invL = 1/(1 + (Fa/Fb) * N * Phi)`** — posterior precision of speaker model; Phi acts as the prior variance
- **`alpha`** — posterior mean of speaker model; shrunk toward zero proportional to 1/Phi

The `Fa` and `Fb` hyperparameters control how strongly the PLDA model influences clustering:
- `Fa` scales the sufficient statistics (larger Fa = data matters more)
- `Fb` controls speaker regularization (larger Fb = fewer speakers, stronger prior)
- Typical values: `Fa=0.4, Fb=17` for AMI dataset (from VBx paper Table 5)

## How phi is used in PLDA LLR scoring

In pairwise scoring (VBx `PLDA_scoring_in_LDA_space`, wespeaker `log_likelihood_ratio`), phi defines the per-dimension weights of the score:

- Dimensions with large phi (high between-class variance) contribute strongly to the LLR
- Dimensions with phi near zero (no speaker information) contribute almost nothing
- This is what makes PLDA scoring better than unweighted cosine — it knows which dimensions are speaker-discriminative

### The n=1 LLR decomposed by phi

For a single enrollment and single test vector:

```
Lambda_d = phi_d / (1 + 2*phi_d)
Gamma_d  = 0.25 * (2/(1 + phi_d) - 1 - 1/(1 + 2*phi_d))
k_d      = log(1 + phi_d) - 0.5 * log(1 + 2*phi_d)

LLR = sum_d [Lambda_d * e_d * t_d + Gamma_d * (e_d^2 + t_d^2) + k_d]
```

For typical phi values:
- phi_d = 10 (highly discriminative): Lambda ~ 0.48, strong cross-term weight
- phi_d = 1 (moderate): Lambda ~ 0.33
- phi_d = 0.01 (not discriminative): Lambda ~ 0.005, nearly ignored

## Phi magnitudes in community-1

I could not load the actual `.npz` files (binary NumPy format, not text-fetchable). Based on the code, phi values are the eigenvalues of the generalized eigenvalue problem B v = lambda W v, where B is the between-class covariance and W is the within-class covariance. They represent "how many within-class standard deviations the between-class spread covers" per dimension.

In typical speaker recognition systems using 128-d PLDA:
- The first few dimensions have phi >> 1 (highly speaker-discriminative)
- The last dimensions have phi near 0 (carry little speaker info)
- The distribution is roughly exponentially decaying

Source for typical values: Landini et al., "Bayesian HMM clustering of x-vector sequences (VBx)," Computer Speech & Language, 2022.

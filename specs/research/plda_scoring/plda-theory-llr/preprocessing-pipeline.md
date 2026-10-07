# Preprocessing Pipeline for PLDA Scoring

## The Standard Pipeline

The preprocessing steps before PLDA scoring are well-established and critical for correct operation. Skipping or reordering them breaks the LLR interpretation. The standard pipeline is:

```
Raw embedding -> Centering -> Whitening -> Length Normalization -> PLDA Transform -> Score
```

Some implementations merge steps (e.g., Kaldi combines centering + whitening + diagonalization into a single transform).

---

## Step 1: Centering (Mean Subtraction)

Subtract the global mean `mu` (estimated from training data) from each embedding:

```
x_centered = x - mu
```

**Why:** The PLDA model assumes the prior on speaker means is zero-centered (after centering). Skipping this biases the LLR.

**Source:** All implementations do this. In Kaldi, it is part of `TransformIvector` via the precomputed `offset_ = -transform_ * mean_`.

---

## Step 2: Whitening

Apply a linear transform to make the total covariance (approximately) identity:

```
x_whitened = W_whiten * x_centered
```

where `W_whiten` is typically derived from the eigendecomposition of the training covariance: `Sigma = U D U^T`, and `W_whiten = D^{-1/2} U^T`.

**Why:** Whitening is a prerequisite for length normalization to work correctly. Without it, length normalization distorts the distribution unevenly across dimensions.

**Note:** In many implementations (including Kaldi), this step is folded into the PLDA transform matrix or done as a separate LDA preprocessing step. VBx, for example, applies LDA (which includes whitening) before PLDA.

---

## Step 3: Length Normalization

Project the whitened vector onto a hypersphere:

```
x_normalized = x_whitened * (target_norm / ||x_whitened||)
```

### The sqrt(dim) Radius

The standard radius is `sqrt(D)` where D is the embedding dimension. This is because for a vector drawn from `N(0, I_D)`, the expected squared norm is D, so the expected norm is approximately `sqrt(D)`.

In Kaldi's `TransformIvector`, the `simple_length_norm` option does exactly this:

```cpp
normalization_factor = sqrt(transformed_ivector->Dim()) / transformed_ivector->Norm(2.0);
```

The more sophisticated normalization (Kaldi's default, `simple_length_norm = false`) uses `GetNormalizationFactor`, which accounts for the number of enrollment examples:

```cpp
// Computes sqrt(Dim / dot_prod) where
// dot_prod = sum_d u_d^2 / (psi_d + 1/num_examples)
```

This ensures the inner product with the model's inverse covariance has the expected value equal to the dimension.

### Why Length Normalization Matters

Garcia-Romero and Espy-Wilson (2011) showed that raw i-vectors (and by extension, x-vectors/speaker embeddings) have heavy-tailed, non-Gaussian distributions. PLDA assumes Gaussian distributions. Length normalization is a nonlinear transform that "Gaussianizes" the distribution by projecting to a spherical surface.

**Key result from Garcia-Romero & Espy-Wilson:** Simple whitening + length normalization makes Gaussian PLDA perform as well as the much more complex Heavy-Tailed PLDA (HT-PLDA) of Kenny (2010), while being far simpler to implement and faster to train.

> "This nonlinear transformation allows the use of probabilistic models with Gaussian assumptions that yield equivalent performance to that of more complicated systems based on Heavy-Tailed assumptions."

Source: [Garcia-Romero & Espy-Wilson 2011](https://www.isca-archive.org/interspeech_2011/garciaromero11_interspeech.html), Interspeech 2011, pp. 249-252

### Does Skipping Length Normalization Break LLR?

**Yes, significantly.** Without length normalization:

1. The Gaussian assumption of the PLDA model is violated -- embeddings have heavy tails
2. The between-class and within-class covariance estimates are biased by outliers
3. The LLR values are poorly calibrated -- their magnitude is not interpretable as log odds
4. Empirical EER degrades substantially (10-50% relative, depending on the system)

From [Wang et al. 2022](https://arxiv.org/abs/2204.03965):
> "Length normalization reduces both EER and minDCF in almost all systems."

Rajan et al. 2014 also confirmed that length normalization helps all scoring variants except one (the multi-session LLR, which is already problematic for other reasons).

---

## Step 4: PLDA Transform (Diagonalization)

Apply the diagonalizing transform to produce vectors in the PLDA space:

```
u = V^T (x_preprocessed - mu_plda)
```

where V is the transform that simultaneously diagonalizes Phi_w to I and Phi_b to diag(psi).

**Important:** The PLDA mean `mu_plda` may differ from the centering mean in step 1, depending on the implementation. In Kaldi, they are the same (the global mean). In VBx/pyannote, centering, LDA, and length normalization are applied *before* the PLDA model's own centering.

The typical VBx pipeline (Landini et al. 2022) is:

```
Raw x-vector
  -> subtract training mean
  -> apply LDA matrix (reduces dimension, e.g., 512 -> 128)
  -> L2 normalize to sqrt(dim) radius
  -> subtract PLDA mean
  -> apply PLDA transform (diagonalization)
  -> (optional) L2 normalize in PLDA space
```

---

## Complete Pipeline in VBx/pyannote

From examining the VBx implementation ([BUTSpeechFIT/VBx](https://github.com/BUTSpeechFIT/VBx)), the preprocessing is stored in a `transform.h5` or `xvec_transform.npz` file and applied as:

1. `x -= xvec_mean` (centering)
2. `x = lda_matrix @ x` (LDA projection, typically 512 -> 128 dimensions)
3. `x *= sqrt(x.shape[-1]) / norm(x)` (length normalization to sqrt(dim) radius)
4. Apply PLDA model: `x -= plda_mean`, then use `plda_psi` for scoring

The PLDA model itself stores `plda_mean` and `plda_psi` (the between-class eigenvalues in the diagonalized space). The diagonalization is already folded into the LDA matrix in some implementations.

---

## Summary of Requirements

| Step | Required? | Impact of Skipping |
|------|-----------|-------------------|
| Centering | Yes | Biases all scores |
| Whitening/LDA | Yes (for full PLDA) | Breaks diagonalization assumption |
| Length normalization | Yes | Heavy-tailed violations, poor calibration |
| PLDA centering | Yes | Biases same-speaker mean |
| Diagonalization | No (can use full-matrix scoring) | Loses per-dimension efficiency |

**The stored PLDA vectors in Biscotti** should already have centering, LDA, and length normalization applied (SpeakerKit does this as part of its PLDA pipeline). The question is whether the diagonalization transform has also been applied, or whether the stored vectors are in the post-LDA/pre-PLDA space. This is answered by the Argmax subtopic.

---

## Sources

- [Garcia-Romero & Espy-Wilson 2011](https://www.isca-archive.org/interspeech_2011/garciaromero11_interspeech.html) -- introduced length normalization for PLDA
- [Kaldi plda.cc](https://github.com/kaldi-asr/kaldi/blob/master/src/ivector/plda.cc) -- TransformIvector and GetNormalizationFactor
- [Wang et al. 2022: "Scoring of Large-Margin Embeddings"](https://arxiv.org/abs/2204.03965) -- length normalization with modern embeddings
- [Rajan et al. 2014](http://www.cs.joensuu.fi/sipu/pub/Rajan_PLDA_Scoring_Variants.pdf) -- length normalization across scoring methods
- [Landini et al. 2022](https://doi.org/10.1016/j.csl.2021.101254) -- VBx preprocessing pipeline
- [BUTSpeechFIT/VBx GitHub](https://github.com/BUTSpeechFIT/VBx) -- reference code for the pipeline

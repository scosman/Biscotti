# VBx and pyannote: X-vector to PLDA Space Transform Pipeline

This document traces the exact sequence of operations from raw x-vectors to the PLDA-space vectors that VBx clustering (and PLDA scoring) consume. It compares three implementations that share a common lineage.

## Overview

The pipeline has two stages:

1. **X-vector transform** — centering, LDA projection, re-centering, length normalization. Stored in `xvec_transform.npz` (or `.h5`). Reduces 256-d x-vectors to 128-d.
2. **PLDA transform** — centering by PLDA mean, rotation by eigenvectors of the generalized eigenvalue problem. Uses `plda.npz` (or Kaldi binary `plda`). Produces vectors in a space where within-class covariance = I and between-class covariance = diag(phi).

## Stage 1: X-vector Transform

### VBx (BUTSpeechFIT/VBx `vbhmm.py`)

Source: [BUTSpeechFIT/VBx vbhmm.py](https://github.com/BUTSpeechFIT/VBx/blob/master/VBx/vbhmm.py)

```python
with h5py.File(args.xvec_transform, 'r') as f:
    mean1 = np.array(f['mean1'])
    mean2 = np.array(f['mean2'])
    lda = np.array(f['lda'])
    x = l2_norm(lda.T.dot((l2_norm(x - mean1)).transpose()).transpose() - mean2)
```

Steps (unpacked):
1. Center: `x - mean1` (subtract global x-vector mean; shape: N x 256)
2. L2-normalize to unit length (each row)
3. Apply LDA: `lda.T @ x.T` then transpose (lda is 256 x 128, so result is N x 128)
4. Re-center: `- mean2` (subtract post-LDA mean; shape: N x 128)
5. L2-normalize to unit length

**No sqrt(dim) scaling.** Each vector has norm = 1.0 after this stage.

### pyannote.audio (`utils/vbx.py`)

Source: [pyannote/pyannote-audio utils/vbx.py](https://github.com/pyannote/pyannote-audio/blob/develop/src/pyannote/audio/utils/vbx.py), merged in [PR #1894](https://github.com/pyannote/pyannote-audio/pull/1894) (Jul 2025).

```python
xvec_tf = lambda x: np.sqrt(lda.shape[1]) * l2_norm(
    lda.T.dot(np.sqrt(lda.shape[0]) * l2_norm(x - mean1).T).T - mean2
)
```

Steps:
1. Center: `x - mean1`
2. L2-normalize to unit length
3. **Scale by sqrt(256)** — Kaldi-style length normalization
4. Apply LDA: `lda.T @ x.T` then transpose
5. Re-center: `- mean2`
6. L2-normalize to unit length
7. **Scale by sqrt(128)**

**Kaldi-style scaling.** Each vector has norm = sqrt(128) after this stage. This follows the Garcia-Romero & Espy-Wilson 2011 convention where length normalization projects to a sphere of radius sqrt(dim).

### grikdotnet/pyannote-community1-plda-vbx (`src/diarization/plda.py`)

Source: [grikdotnet/pyannote-community1-plda-vbx plda.py](https://github.com/grikdotnet/pyannote-community1-plda-vbx/blob/main/src/diarization/plda.py)

```python
centered = l2_normalize(embeddings - self.mean1) * np.sqrt(256)
projected = centered @ self.lda - self.mean2
normalized = l2_normalize(projected) * np.sqrt(128)
```

Same steps as pyannote, written more explicitly.

### Discrepancy: VBx vs pyannote

VBx uses plain l2-normalization (norm=1). pyannote and grikdotnet use Kaldi-style normalization (norm=sqrt(dim)). **The difference is a constant scaling factor.** Since the PLDA model parameters (mu, tr, psi) were trained on a particular normalization, the model files must match the transform. The community-1 PLDA model files (`plda.npz`, `xvec_transform.npz`) from BUT Speech@FIT are designed for the Kaldi-style normalization.

The VBx repo loads Kaldi-format `.plda` files (binary) via `read_plda`, and those Kaldi models would have been trained on Kaldi-normalized x-vectors (sqrt(dim)). The VBx `vbhmm.py` code uses unit-norm instead, but this works because:
- For cosine-based AHC (the first step), normalization to unit vs sqrt(dim) does not change the cosine distance.
- For VBx clustering, the PLDA transform (stage 2) re-derives the eigenvalue decomposition from the Kaldi PLDA model, so absolute scale is absorbed.

## Stage 2: PLDA Transform

### Loading Kaldi PLDA model

The Kaldi PLDA model contains three arrays (source: [VBx kaldi_utils.py](https://github.com/BUTSpeechFIT/VBx/blob/master/VBx/kaldi_utils.py)):

- `mu` — mean vector (128-d)
- `tr` — transform matrix (128 x 128) that whitens within-class and diagonalizes between-class covariance
- `psi` — diagonal of between-class covariance in Kaldi's transformed space (128-d)

### Re-derivation of eigendecomposition

Both VBx and pyannote re-derive the PLDA space from Kaldi parameters rather than using `tr` and `psi` directly.

From `vbhmm.py` and pyannote's `vbx.py` (identical logic):

```python
# Recover original-space covariance matrices from Kaldi parametrization
W = np.linalg.inv(plda_tr.T.dot(plda_tr))      # within-class covariance
B = np.linalg.inv((plda_tr.T / plda_psi).dot(plda_tr))  # between-class covariance

# Solve generalized eigenvalue problem: B v = lambda W v
acvar, wccn = eigh(B, W)

# Reverse to descending order
plda_psi = acvar[::-1]    # = phi (between-class eigenvalues, largest first)
plda_tr = wccn.T[::-1]    # = rotation matrix
```

**Why re-derive?** The Kaldi parametrization stores the full-rank transform and eigenvalues, but VBx needs to truncate to `lda_dim` dimensions (typically 128 out of 128, but can be less). Re-solving the generalized eigenvalue problem guarantees the eigenvalues are sorted by descending magnitude, which allows clean truncation.

### Applying the PLDA transform

From `vbhmm.py`:

```python
fea = (x - plda_mu).dot(plda_tr.T)[:, :args.lda_dim]
```

From pyannote's `vbx.py`:

```python
plda_tf = lambda x0, lda_dim=lda.shape[1]: (x0 - plda_mu).dot(plda_tr.T)[:, :lda_dim]
```

Steps:
1. Center by PLDA mean: `x - plda_mu`
2. Rotate by eigenvectors: `@ plda_tr.T` (each row of plda_tr is an eigenvector)
3. Truncate to `lda_dim` dimensions

The result is a vector in a space where:
- Within-class covariance = I (identity)
- Between-class covariance = diag(phi[:lda_dim])

## Dimensionality

| Stage | Input dim | Output dim | Notes |
|-------|-----------|------------|-------|
| Raw x-vector | 256 | 256 | WeSpeaker ResNet34 embedding |
| X-vector transform | 256 | 128 | LDA from 256 to 128 |
| PLDA transform | 128 | lda_dim (default 128) | Can truncate further |

The community-1 model uses 256-d WeSpeaker embeddings reduced to 128 by LDA, then the PLDA model operates in 128-d. The `lda_dimension` parameter in pyannote's `PLDA` class defaults to 128.

Source for dimensions: [xvec_transform.npz on HuggingFace](https://huggingface.co/pyannote-community/speaker-diarization-community-1/blob/main/plda/xvec_transform.npz), confirmed by grikdotnet assertion: `self.mean1.shape == (256,)`, `self.lda.shape == (256, 128)`, `self.mean2.shape == (128,)`.

## The complete pipeline in one listing

Combining both stages (pyannote variant with Kaldi-style normalization):

```python
# --- Stage 1: x-vector transform ---
# x: (N, 256) raw x-vectors
x1 = l2_norm(x - mean1) * sqrt(256)      # center, normalize, Kaldi-scale
x2 = x1 @ lda - mean2                     # LDA project (256→128), re-center
x3 = l2_norm(x2) * sqrt(128)              # normalize, Kaldi-scale

# --- Stage 2: PLDA transform ---
fea = (x3 - plda_mu) @ plda_tr.T          # center, rotate into PLDA space
fea = fea[:, :lda_dim]                     # truncate (usually 128→128)

# fea is now in PLDA space where:
#   within-class cov = I
#   between-class cov = diag(phi[:lda_dim])
```

## Model file formats

| Repo | X-vec transform | PLDA model |
|------|----------------|------------|
| VBx (BUTSpeechFIT) | HDF5 `.h5` with keys `mean1`, `mean2`, `lda` | Kaldi binary with `<Plda>` header (mu, tr, psi) |
| pyannote community-1 | NumPy `.npz` with keys `mean1`, `mean2`, `lda` | NumPy `.npz` with keys `mu`, `tr`, `psi` |

The `.npz` files are NumPy-serialized equivalents of the same arrays. The community-1 `.npz` files were published by BUT Speech@FIT under CC-BY-4.0.

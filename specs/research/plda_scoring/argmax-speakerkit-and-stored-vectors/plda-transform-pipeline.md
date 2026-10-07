# PLDA Transform Pipeline in SpeakerKit

Where and how the PLDA projection happens, traced from source code and the
CoreML model's MIL intermediate representation.

---

## The CoreML model does the entire transform

The PLDA projection lives entirely inside `PldaProjector.mlmodelc`, a CoreML
model downloaded from HuggingFace. There is **no Swift-side math** for the
transform; Swift only feeds the raw embeddings in and reads the PLDA embeddings
out.

- **Model path on disk:**
  `~/Library/Application Support/Biscotti/models/argmaxinc/speakerkit-coreml/speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/`
- **Model info:** `ModelInfo.plda()` returns version `"pyannote-v4"`,
  variant `"W32A32"`, compute unit `.cpuOnly`
  (source: `PyannoteConfig.swift:33-36`)
- **Input:** `embeddings [1, 64, 256]` Float16 (raw speaker embeddings)
- **Output:** `plda_embeddings [1, 64, 128]` Float16
  (source: `PldaProjector.mlmodelc/metadata.json`)

## Exact transform steps (from `model.mil`)

The MIL intermediate representation
(`PldaProjector.mlmodelc/model.mil`) reveals six
operations, all running in Float32 internally:

| Step | Operation | Learned parameters | Description |
|---|---|---|---|
| 1 | **Center** | `xvectors_mean [256]` | Subtract the global x-vector mean |
| 2 | **Length normalize** | -- | `x / sqrt(mean(x^2) + eps)` per sample. Equivalent to L2 normalization scaled by sqrt(256) |
| 3 | **LDA projection** | `lda_proj_weight [128, 256]` + `bias [128]` | Linear projection 256 -> 128 dimensions |
| 4 | **Length normalize** | -- | Same operation: `x / sqrt(mean(x^2) + eps)`. Equivalent to L2 norm scaled by sqrt(128) |
| 5 | **Center** | `plda_mean [128]` | Subtract the PLDA-space mean |
| 6 | **PLDA rotation** | `plda_proj_weight [128, 128]` (no bias) | Rotation/whitening that diagonalizes the PLDA model |

### Length normalization detail

The normalization in steps 2 and 4 is:

```
inputs_sq = x * x                          # element-wise square
variance  = reduce_mean(inputs_sq, axis=feature_dim)  # scalar per sample
x_normed  = x * rsqrt(variance + 1e-6)     # per-sample scaling
```

Since `mean(x^2) = ||x||^2 / dim`, this equals `x * sqrt(dim) / ||x||`, which
is L2 normalization to radius `sqrt(dim)`. This matches the standard
VBx/pyannote convention of length-normalizing to `sqrt(dim)`.

### Correspondence to VBx/pyannote pipeline

This is the standard pipeline from pyannote/VBx:

1. Center (subtract xvector mean)
2. LDA projection (with bias = affine transform)
3. Length normalize to sqrt(dim)
4. Center (subtract PLDA-space mean)
5. PLDA diagonalization (rotation)

Step 2 in the CoreML model (length normalize BEFORE LDA) is an extra pre-LDA
normalization. The standard pyannote pipeline does not include this step, but
the CoreML model adds it. The effect is that input embeddings are
direction-normalized before the LDA projection.

## Swift code path

```
SpeakerEmbedderModel.processChunk()          (SpeakerEmbedderModel.swift:207-311)
  -> raw embeddings from SpeakerEmbedder model  (line 270)
  -> if pldaModel != nil:                        (line 273)
       SpeakerPLDAEmbedderInput(embedderOutput:)  (line 274)
       pldaModelInstance.asyncPrediction(...)      (line 276)
       -> pldaEmbeddingsOutput                    (line 278)
  -> SpeakerEmbedding(embedding:, pldaEmbedding:) (line 296-303)
```

The PLDA embedding is computed per (window, speaker) pair and stored as
`SpeakerEmbedding.pldaEmbedding: [Float]?` (optional; nil when no PLDA model
is loaded).

## Learned parameters are baked into the CoreML model

The four learned parameter tensors (`xvectors_mean`, `lda_proj_weight` + bias,
`plda_mean`, `plda_proj_weight`) are stored as constants in the model's
`weights/weight.bin` file. They are not separately accessible as numpy arrays
or Swift constants. To extract them, you would need to deserialize the CoreML
model weights (coremltools can do this in Python).

However, for a **benchmark that compares already-projected PLDA vectors**, these
parameters are NOT needed. The stored voiceprints have already been through the
full pipeline. What IS needed is `phi` (the between-class covariance diagonal),
which is a separate parameter used in VBx scoring.

---

## Sources

- `SpeakerEmbedderModel.swift` lines 207-311 (process chunk, PLDA model call)
  Path: `.build/checkouts/argmax-oss-swift/Sources/SpeakerKit/Pyannote/SpeakerEmbedderModel.swift`
- `PldaProjector.mlmodelc/model.mil` (MIL intermediate representation with
  exact operations and parameter shapes)
  Path: `~/Library/Application Support/Biscotti/models/argmaxinc/speakerkit-coreml/speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/model.mil`
- `PldaProjector.mlmodelc/metadata.json` (model I/O shapes)
- `PyannoteConfig.swift:33-36` (ModelInfo.plda() defaults)

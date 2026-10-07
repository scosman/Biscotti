# Phi (Between-Class Covariance) and VBx Scoring

Where `phi` lives in SpeakerKit, how it is used in VBx, and whether any
pairwise scoring function is exposed.

---

## Phi is a hardcoded Swift constant

`phi` lives as `betweenClassCovariance`, a `private static let` on
`VariationalBayesHiddenMarkovModel` in `ClusteringAlgorithms.swift:532-559`.

128 Float values, sorted descending (largest eigenvalue first):

```swift
private static let betweenClassCovariance: [Float] = [
    25.8823843, 10.64654768, 7.09749664, 5.70842102, 5.27071843,
    4.99630206, 4.25741596, 4.07776313, 3.89517645, 3.69594798,
    3.64910204, 3.4740059,  3.1161406,  2.89308777, 2.85235283,
    2.74298281, 2.69856644, 2.54895349, 2.49312298, 2.35923547,
    2.31617442, 2.25039797, 2.20650582, 2.11553732, 2.08046971,
    2.04438817, 1.99983924, 1.94495688, 1.90123046, 1.86979365,
    1.84888933, 1.81611504, 1.76659227, 1.73939854, 1.71681168,
    1.68313843, 1.63579985, 1.6291736,  1.58139228, 1.53777309,
    1.52376318, 1.50576921, 1.4852546,  1.46273286, 1.46112849,
    1.43902254, 1.41162633, 1.40358761, 1.38767215, 1.35415771,
    1.34320055, 1.31804126, 1.29211534, 1.26927315, 1.25277974,
    1.23694313, 1.21484673, 1.21013266, 1.20138393, 1.19199542,
    1.17204403, 1.14954023, 1.14245929, 1.122949,   1.11425141,
    1.09640355, 1.08456146, 1.0667317,  1.05513591, 1.04003146,
    1.02566902, 1.02010552, 1.01099642, 0.99231797, 0.98069675,
    0.97343907, 0.95881054, 0.95197792, 0.9462381,  0.92696959,
    0.91914417, 0.9136186,  0.90647712, 0.90414186, 0.8860543,
    0.88015839, 0.87319719, 0.86870833, 0.86731253, 0.85900931,
    0.84836197, 0.83159452, 0.82433101, 0.81734176, 0.80188412,
    0.79747487, 0.79064521, 0.78698437, 0.78016046, 0.76995838,
    0.76739477, 0.76181261, 0.7557517,  0.74880944, 0.73518941,
    0.73211398, 0.7256853,  0.72203483, 0.70633259, 0.70241969,
    0.69792648, 0.68882402, 0.67445369, 0.67196181, 0.66614225,
    0.65970189, 0.65231306, 0.6459088,  0.64389891, 0.63339111,
    0.62995437, 0.62304199, 0.61221797, 0.61031214, 0.60488038,
    0.6014566,  0.58401099, 0.56960536,
]
```

### Access constraints

- Visibility: **`private static`** — not accessible outside
  `VariationalBayesHiddenMarkovModel`.
- Not in any model file — not in `PldaProjector.mlmodelc` or any config file.
- Not in any HuggingFace repo resource; it is compiled into the Swift binary.
- A benchmark must **copy these 128 values** from source.

### Where phi came from

These are the eigenvalues of the between-class covariance matrix after the PLDA
diagonalization. In the diagonalized PLDA space (after the full CoreML
transform), within-class covariance = I (identity) and between-class
covariance = diag(phi). The values were trained on pyannote's speaker
verification training data.

---

## How VBx uses phi

`VariationalBayesHiddenMarkovModel.vbx()` at `ClusteringAlgorithms.swift:564-716`
uses phi in three places:

### 1. Scaling embeddings (line 615-619)

```swift
let embeddingScalingFactors = betweenClassCovarianceDiag.map { sqrt($0) }
let scaledEmbeddings = pldaEmbeddings.map { embedding in
    zip(embedding, embeddingScalingFactors).map { $0 * $1 }
}
```

Each PLDA embedding is multiplied element-wise by `sqrt(phi)`. This scales the
embeddings into a space where the between-class covariance is proportional to
the identity, making dot products meaningful as similarity measures.

### 2. Speaker precision inverse (lines 629-634)

```swift
let speakerPrecisionInverse = (0..<numClusters).map { clusterIdx in
    betweenClassCovarianceDiag.map { covDiag in
        1.0 / (1 + speakerRelevanceFactorA / speakerRelevanceFactorB
                * speakerAssignmentSums[clusterIdx] * covDiag)
    }
}
```

This is the posterior precision of the speaker mean estimate, using the number
of assigned embeddings and phi as the prior variance. The formula is
`1 / (1 + (Fa/Fb) * N_k * phi_d)` per dimension, where `N_k` is the soft
count of embeddings assigned to speaker k.

### 3. Log-likelihood computation (lines 718-776)

`calculateLogLikelihoods()` computes per-embedding, per-speaker log-likelihoods
using the scaled embeddings, speaker model parameters, precision inverse, and
phi. This is the core PLDA scoring used inside the VB iterations. It is NOT a
standalone pairwise scoring function.

---

## No pairwise scoring function exists

SpeakerKit exposes only these comparison functions:

| Function | Location | Does |
|---|---|---|
| `MathOps.cosineDistance(_:_:)` | MathOps.swift:86-111 | Plain cosine distance, `[0, 2]` |
| `DiarizationResult.centroidCosineDistance(between:and:)` | DiarizationResult.swift:158-163 | Wraps cosineDistance for raw centroids within ONE result |
| `DiarizationResult.nearestSpeakerCentroid(to:)` | DiarizationResult.swift:173-188 | Nearest-neighbor over raw centroids only |

None of these:
- Uses phi
- Computes an LLR
- Operates on PLDA embeddings
- Scores across independent diarization runs

The VBx log-likelihood computation (`calculateLogLikelihoods`) is the closest
thing to PLDA scoring, but it is designed for iterative speaker assignment
within a single diarization run, not for pairwise comparison of centroids from
different runs.

---

## Benchmark-relevant code to copy

For a benchmark that computes PLDA LLR, copy:

1. **The phi array** (128 floats) from `ClusteringAlgorithms.swift:532-559`
2. **`MathOps.cosineDistance`** from `MathOps.swift:86-111` (for baseline
   comparison)
3. **The LLR formula itself** is NOT in argmax code. Implement it from the
   PLDA theory (see theory subtopic). The VBx log-likelihood code is too
   tightly coupled to the iterative algorithm to extract as a pairwise scorer.

### Dependencies of the code to copy

- `MathOps.cosineDistance` depends only on `Accelerate` (vDSP).
- The phi array has no dependencies; it is a literal.
- A Python benchmark can embed both as numpy arrays with no Swift dependency.

---

## Sources

- `ClusteringAlgorithms.swift` lines 530-810
  Path: `.build/checkouts/argmax-oss-swift/Sources/SpeakerKit/Pyannote/ClusteringAlgorithms.swift`
- `MathOps.swift` lines 86-111
  Path: `.build/checkouts/argmax-oss-swift/Sources/SpeakerKit/Pyannote/MathOps.swift`
- `DiarizationResult.swift` lines 144-188
  Path: `.build/checkouts/argmax-oss-swift/Sources/SpeakerKit/DiarizationResult.swift`

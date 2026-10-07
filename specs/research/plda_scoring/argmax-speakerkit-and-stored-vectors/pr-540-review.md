# PR #540: Add PLDA Centroid Embeddings to DiarizationResult

Analysis of the upstream PR, its review, and implications for the benchmark.

- PR: https://github.com/argmaxinc/argmax-oss-swift/pull/540
- Author: scosman
- Reviewer: a2they (Andrey, argmax engineer)
- Opened and closed: 2026-10-07
- Status: **Closed without merge** (author decided to redesign)

---

## What the PR did

The PR threaded PLDA centroid embeddings through the diarization pipeline,
mirroring the existing raw centroid path. This is the same change our fork
(`scosman/argmax-oss-swift` @ `0475cca` on branch
`biscotti/v1.1.0-plda-centroids`) already contains.

### Changes

1. **`VBxClustering.swift`** -- Generalized `centroidsFromFinalAssignments` with
   a `vector:` closure parameter. Called twice: once for raw (default), once
   with `{ $0.pldaEmbedding }`. `cluster()` returns a 4-tuple including
   `pldaCentroids`.

2. **`SpeakerClustering.swift`** -- `ClusteringResult` gained
   `speakerPLDACentroids: [Int: [Float]]`.

3. **`PyannoteDiarizer.swift`** -- Threaded PLDA centroids through `postProcess`.

4. **`DiarizationResult.swift`** -- Added
   `speakerPLDACentroidEmbeddings: [Int: [Float]]` with docstring.

5. **Tests** -- Five unit tests validating the PLDA centroid path.

---

## Key review feedback from a2they (Andrey)

### 1. Cosine distance is wrong for PLDA vectors

> "VBx weights PLDA vectors by `phi` (`betweenClassCovariance`), which plain
> cosine distance omits."

Andrey confirmed that plain cosine distance on PLDA vectors omits the
per-dimension weighting by phi. The correct comparison uses the
between-class covariance (phi) to weight dimensions differently. This is the
core motivation for this research task.

### 2. mean(PLDA(x)) != PLDA(mean(x))

> "mean(PLDA(x)) and PLDA(mean(x)) come out different"

The length normalization inside the PLDA transform is non-linear. Averaging
per-window PLDA embeddings (as `centroidsFromFinalAssignments` does) produces a
different result than projecting the averaged raw embeddings. Andrey suggested
exposing a projection function (`pldaEmbeddings(for:)`) so callers could
project raw centroids themselves. This is a fundamental limitation of the
stored PLDA centroids.

### 3. No way to compare PLDA vectors

> "`nearestSpeakerCentroid(to:)` only looks at raw centroids ... passing it a
> PLDA vector just returns `nil`"

The existing comparison functions only operate on raw embeddings. There is no
PLDA-aware comparison in SpeakerKit. Andrey requested "some way to compare
PLDA vectors too."

### 4. Missing comparison method

No PLDA scoring function, LLR computation, or phi-weighted distance was
proposed or requested in the PR. The review noted the gap but did not specify
what the right comparison method would be.

---

## Implications for the benchmark

### What we have (via the fork)

Our fork already contains the PR's changes. PLDA centroids are computed and
stored. The fork is pinned at `0475cca`, which is `v1.1.0` plus the one
PLDA-centroids commit.

### What the review tells us

1. **Cosine on PLDA is expected to underperform.** Andrey confirmed that VBx
   uses phi-weighted scoring, not cosine. This explains the calibration pass
   result where PLDA cosine showed a "slight regression" vs raw cosine.

2. **The stored PLDA centroids are an approximation.** They are
   mean(PLDA(x_per_window)), not PLDA(mean(x)). For a proper comparison,
   we would need either:
   - Re-project raw centroids through the CoreML model (but that requires
     loading and running the model -- not a simple benchmark operation)
   - Use the stored PLDA centroids as-is, accepting the approximation
   - Use per-window PLDA embeddings (not stored; would need re-diarization)

3. **No upstream scoring function exists or is planned.** The benchmark must
   implement PLDA LLR scoring independently, using phi extracted from source.

### Cheapest path forward

Use the stored PLDA centroids with proper LLR scoring (using phi). The
mean(PLDA(x)) vs PLDA(mean(x)) difference is a second-order effect --
centroids pool hundreds of windows, so the mean is close to the true speaker
direction. The primary improvement comes from using phi-weighted scoring
instead of naive cosine, not from changing how centroids are computed.

If PLDA LLR with stored centroids outperforms raw cosine on the calibration
data, we have a strong result. If it does not, the mean(PLDA(x)) approximation
may be a contributing factor, but the simpler explanation is that PLDA does not
help on this data (mostly same-setup recordings, where PLDA's channel
normalization adds no value).

---

## Sources

- PR page: https://github.com/argmaxinc/argmax-oss-swift/pull/540
- PR diff: https://github.com/argmaxinc/argmax-oss-swift/pull/540.diff
- Issue comments: https://api.github.com/repos/argmaxinc/argmax-oss-swift/issues/540/comments
- All fetched 2026-10-07

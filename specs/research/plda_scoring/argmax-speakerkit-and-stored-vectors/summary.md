# Argmax SpeakerKit Code and Our Stored Vectors

## Bottom Line

The PLDA transform is entirely inside a CoreML model (`PldaProjector.mlmodelc`)
-- there is no Swift-side math to copy for the projection. The critical
parameter for scoring, `phi` (between-class covariance), is a **128-float
private constant** hardcoded in `ClusteringAlgorithms.swift:532-559`; it must be
copied verbatim for a benchmark. SpeakerKit exposes **no PLDA scoring or LLR
function** -- VBx uses phi internally for iterative speaker assignment, but
nothing does pairwise comparison. Our stored PLDA voiceprints (128-dim,
unnormalized centroids in the diagonalized PLDA space) carry enough information
to compute a correct LLR with phi, with one caveat: they are centroids (means
of N windows), so the LLR formula must account for per-centroid sample count
(estimable from `speakingDuration`). Andrey from argmax confirmed in PR #540
that cosine distance on PLDA vectors omits the phi weighting and is expected to
underperform. The cheapest benchmark path is a Python script reading phi from
source and PLDA vectors from a SQLite snapshot.

## Key Findings

- **(a) PLDA transform location** -- Entirely in
  `PldaProjector.mlmodelc` (CoreML model). Steps: center (subtract
  `xvectors_mean`), length-normalize to `sqrt(256)`, LDA project (256->128
  with bias), length-normalize to `sqrt(128)`, center (subtract `plda_mean`),
  PLDA rotation (128->128, no bias). Matches the VBx/pyannote pipeline with an
  additional pre-LDA normalization step.
  Source: `model.mil` in `~/Library/Application Support/Biscotti/models/argmaxinc/speakerkit-coreml/speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/`

- **(b) Phi location** -- Hardcoded as `private static let
  betweenClassCovariance` in `VariationalBayesHiddenMarkovModel`
  (`ClusteringAlgorithms.swift:532-559`). 128 Float values, descending from
  25.88 to 0.57. NOT public API. NOT in any model file or bundled resource. A
  benchmark must copy the literal array. Models live at
  `~/Library/Application Support/Biscotti/models/argmaxinc/speakerkit-coreml/`.
  Source: `.build/checkouts/argmax-oss-swift/Sources/SpeakerKit/Pyannote/ClusteringAlgorithms.swift`

- **(c) No scoring function** -- SpeakerKit has only `MathOps.cosineDistance`
  (plain cosine) and `DiarizationResult.nearestSpeakerCentroid(to:)` (raw
  centroids only). No PLDA comparison, no LLR, no phi-weighted distance. VBx
  uses phi in `calculateLogLikelihoods` (`ClusteringAlgorithms.swift:718-776`),
  but that function is designed for iterative speaker assignment, not pairwise
  scoring.

- **(d) What speakerPLDACentroidEmbeddings returns** -- The arithmetic mean of
  per-window `SpeakerEmbedding.pldaEmbedding` values (CoreML model output)
  under final post-reassignment labels, filtered by `centroidSource`. 128-dim.
  No normalization, no phi scaling. Computed in
  `VBxClustering.centroidsFromFinalAssignments` with `vector: { $0.pldaEmbedding }`.
  Source: `VBxClustering.swift:144-150,229-264`

- **(e) SQLite storage** -- Table `ZVOICEPRINT` with columns: `ZSPEAKERID`
  (int), `ZKINDRAW` ("raw"/"plda"), `ZEMBEDDINGSPACE` (version string),
  `ZDIMENSION` (256/128), `ZVECTORDATA` (little-endian Float32 blob),
  `ZSPEAKINGDURATION` (float seconds), `ZTRANSCRIPT` (FK to transcript).
  Speaker-to-person link is via JSON in `ZTRANSCRIPTRECORD` (field
  `speakerAssignmentsData`: `{speakerID: {personID, userSet}}`). Person records
  in `ZPERSON` (name, email, UUID). Current store: 367 voiceprints per kind,
  135 transcripts, 89 persons. No segment/window count stored; only speaking
  duration.

- **(f) Stored PLDA vectors are sufficient for LLR** -- The vectors are in the
  correct diagonalized PLDA space (post full CoreML pipeline). Combined with
  phi, they carry enough information for LLR. **Caveats**: (1) centroids are
  means of N windows, so within-class variance is I/N, not I -- the formula
  must scale by N (estimate ~1 window/second from speakingDuration);
  (2) mean(PLDA(x)) differs from PLDA(mean(x)) due to non-linear length
  normalization in the CoreML model (Andrey noted this in PR #540); (3) no
  information is "lost" -- just a different statistical object than a single
  embedding. Raw vectors cannot be re-projected to PLDA space without running
  the CoreML model.

- **(g) Cheapest benchmark path** -- **Python + numpy over SQLite export.**
  Copy phi (128 floats from ClusteringAlgorithms.swift), read PLDA vectors from
  `ZVOICEPRINT` (decode Float32 blobs with `np.frombuffer(blob, '<f4')`), join
  to speaker assignments and persons, implement the LLR formula from the theory
  subtopic. Alternatively, a Swift benchmark could extend `voiceprint-cli
  metrics` (VoiceprintEvaluator.swift) with a phi-weighted scorer, copying phi
  from argmax source. Python is faster to iterate; Swift reuses the existing
  evaluation framework.

- **(PR #540)** -- Opened and closed same day (2026-10-07). Andrey (a2they)
  confirmed cosine is wrong for PLDA (VBx weights by phi); noted
  mean(PLDA(x)) != PLDA(mean(x)); requested a projection function and a PLDA
  comparison method. Neither was added. The PR's code changes are already in
  our fork. See [pr-540-review.md](./pr-540-review.md).

## Benchmark code to copy from argmax (exact paths and line ranges)

| What | File | Lines | Dependencies |
|---|---|---|---|
| phi (128 floats) | `Sources/SpeakerKit/Pyannote/ClusteringAlgorithms.swift` | 532-559 | None (literal array) |
| `MathOps.cosineDistance` | `Sources/SpeakerKit/Pyannote/MathOps.swift` | 86-111 | `Accelerate` (vDSP) |
| `centroidsFromFinalAssignments` (reference for how centroids are built) | `Sources/SpeakerKit/Pyannote/VBxClustering.swift` | 229-264 | `SpeakerEmbedding` (internal type) |

All paths relative to `.build/checkouts/argmax-oss-swift/`.

The LLR formula itself is NOT in argmax code. Implement from PLDA theory
(see theory subtopic). The VBx `calculateLogLikelihoods` function
(ClusteringAlgorithms.swift:718-776) is too coupled to the iterative algorithm
to serve as a pairwise scorer.

## Details

- [plda-transform-pipeline.md](./plda-transform-pipeline.md) -- The exact
  CoreML model operations with parameter shapes. Read for the full transform
  math and how it maps to VBx/pyannote conventions.
- [phi-and-vbx-scoring.md](./phi-and-vbx-scoring.md) -- The full phi array,
  how VBx uses it (scaling, precision, log-likelihoods), and why no pairwise
  scorer exists. Read to extract phi for the benchmark.
- [stored-voiceprints.md](./stored-voiceprints.md) -- SQLite schema, vector
  encoding (Python decode snippet), store statistics, embedding space
  versioning. Read to write the benchmark's data loading code.
- [pr-540-review.md](./pr-540-review.md) -- Upstream PR review with Andrey's
  feedback on PLDA scoring and the mean(PLDA(x)) issue. Read for the argmax
  team's perspective on correct PLDA comparison.

## Open Questions / Gaps

- **Segment/window count per centroid**: the store has `speakingDuration` but
  not the number of per-window embeddings that were averaged. For a
  multi-enrollment LLR that adjusts within-class variance by 1/N, N must be
  estimated. Rough estimate: ~1 active window per second of speaking time
  (10 s windows with ~1 s stride, filtered by activity). The theory subtopic
  should clarify whether this adjustment matters in practice.
- **Whether mean(PLDA(x)) vs PLDA(mean(x)) matters empirically**: Andrey
  flagged this as a concern. If LLR with stored centroids still loses to raw
  cosine, this non-linearity could be a factor. Only a benchmark can tell.
- **The PLDA projection learned parameters** (xvectors_mean, lda weights, etc.)
  are baked into the CoreML model binary. Extracting them for a Python
  re-projection requires `coremltools`. Not needed for the benchmark (stored
  vectors are already projected), but would be needed to project raw centroids.

## Sources

- argmax-oss-swift fork checkout at `.build/checkouts/argmax-oss-swift/` (revision `0475cca`, branch `biscotti/v1.1.0-plda-centroids`)
- `PldaProjector.mlmodelc` model files at `~/Library/Application Support/Biscotti/models/argmaxinc/speakerkit-coreml/speaker_clusterer/pyannote-v4/W32A32/`
- SQLite store snapshot (read-only, 2026-10-07)
- PR #540 discussion: https://github.com/argmaxinc/argmax-oss-swift/pull/540 (fetched 2026-10-07)
- `specs/projects/speaker_embeddings/sdk_findings.md` (prior verified SDK analysis)
- `specs/projects/speaker_embeddings/calibration.md` (calibration pass results)

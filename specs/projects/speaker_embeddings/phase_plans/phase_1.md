---
status: complete
---

# Phase 1: SpeakerKit Fork — Add PLDA Centroid Embeddings

## Overview

Add `speakerPLDACentroidEmbeddings` to SpeakerKit via the developer's fork of
`argmax-oss-swift`. This exposes per-speaker PLDA-projected centroid vectors
alongside the existing raw centroids, giving downstream voiceprint matching two
embedding spaces to compare. The fork is synced, renamed, branched, and pinned
in the Transcription package.

## Steps

1. **Sync and rename the fork.** Reset the fork's `main` to upstream, push
   upstream tags, rename `scosman/WhisperKit` to `scosman/argmax-oss-swift`.
   (Sync blocked by OAuth workflow scope; developer handles the main sync.
   Rename done. Tags fetched locally.)

2. **Create `biscotti/v1.1.0-plda-centroids` branch from tag `v1.1.0`.** Make
   the SDK changes on this branch:

   a. `Sources/SpeakerKit/Pyannote/VBxClustering.swift` — generalize
      `centroidsFromFinalAssignments` with a `vector:` closure parameter
      (default `{ $0.embedding }`). Call it twice in `cluster(...)`: once for
      raw centroids, once with `{ $0.pldaEmbedding }` for PLDA centroids.
      Return both maps (4-tuple).

   b. `Sources/SpeakerKit/Pyannote/SpeakerClustering.swift` — add
      `speakerPLDACentroids: [Int: [Float]]` to `ClusteringResult` (defaulted
      `[:]`).

   c. `Sources/SpeakerKit/Pyannote/PyannoteDiarizer.swift` — pass PLDA
      centroids from `ClusteringResult` through `postProcess` to
      `DiarizationResult`.

   d. `Sources/SpeakerKit/DiarizationResult.swift` — add
      `speakerPLDACentroidEmbeddings: [Int: [Float]]` property. Both inits
      accept it (defaulted `[:]`).

3. **Write tests** in
   `Tests/SpeakerKitTests/SpeakerCentroidEmbeddingsTests.swift`:
   - `testPLDACentroidsFromFinalAssignments_honoursCentroidSource`
   - `testPLDACentroidsFromFinalAssignments_omitsClusterWithNoTrainableMembers`
   - `testPLDACentroidsFromFinalAssignments_nilPldaEmbeddingSkipped`
   - `testPLDACentroidsFromFinalAssignments_valueEqualsMemberMean`
   - `testGenericInitAcceptsPLDACentroidEmbeddings`

4. **Run SDK tests** (SpeakerKitTests, synthetic-data only).

5. **Create `plda-centroid-embeddings` branch from upstream `main`.** Cherry-pick
   or rebase the same change.

6. **Push both branches** to `scosman/argmax-oss-swift`.

7. **Pin `Packages/Transcription/Package.swift`** to the fork commit on
   `biscotti/v1.1.0-plda-centroids`. Re-resolve `Package.resolved`.

8. **Add CLAUDE.md gotcha** about the SpeakerKit fork pin.

9. **Build Transcription** via `hooks-mcp` to verify resolution.

## Tests

- `testPLDACentroidsFromFinalAssignments_honoursCentroidSource`: `.trainableOnly`
  filters overlap-flagged embeddings from PLDA centroids.
- `testPLDACentroidsFromFinalAssignments_omitsClusterWithNoTrainableMembers`:
  cluster with no trainable members produces no PLDA centroid key.
- `testPLDACentroidsFromFinalAssignments_nilPldaEmbeddingSkipped`: members with
  nil `pldaEmbedding` are excluded from the PLDA centroid mean.
- `testPLDACentroidsFromFinalAssignments_valueEqualsMemberMean`: PLDA centroid
  value equals the arithmetic mean of members' `pldaEmbedding`.
- `testGenericInitAcceptsPLDACentroidEmbeddings`: generic `DiarizationResult`
  init round-trips the new field.

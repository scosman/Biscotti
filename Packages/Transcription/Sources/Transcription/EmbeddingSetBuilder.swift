import SpeakerKit

/// Builds `SpeakerEmbeddingSet` arrays from a diarization result.
enum EmbeddingSetBuilder {
    /// Builds [raw, plda] embedding sets from a diarization result.
    ///
    /// - Drops vectors that are empty or contain non-finite values.
    /// - Omits a set entirely when it has no valid vectors.
    static func build(from diarization: DiarizationResult) -> [SpeakerEmbeddingSet] {
        var sets: [SpeakerEmbeddingSet] = []

        let rawVectors = filterValid(diarization.speakerCentroidEmbeddings)
        if !rawVectors.isEmpty {
            sets.append(SpeakerEmbeddingSet(
                kind: .raw,
                space: SpeakerEmbeddingSpace.current(.raw),
                vectors: rawVectors
            ))
        }

        let pldaVectors = filterValid(diarization.speakerPLDACentroidEmbeddings)
        if !pldaVectors.isEmpty {
            sets.append(SpeakerEmbeddingSet(
                kind: .plda,
                space: SpeakerEmbeddingSpace.current(.plda),
                vectors: pldaVectors
            ))
        }

        return sets
    }

    /// Keeps only vectors that are non-empty and all-finite.
    private static func filterValid(_ vectors: [Int: [Float]]) -> [Int: [Float]] {
        vectors.filter { _, vector in
            !vector.isEmpty && vector.allSatisfy(\.isFinite)
        }
    }
}

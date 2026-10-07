import SpeakerKit

/// Builds `SpeakerEmbeddingSet` arrays from a diarization result.
enum EmbeddingSetBuilder {
    /// Builds a raw embedding set from a diarization result.
    ///
    /// - Drops vectors that are empty or contain non-finite values.
    /// - Returns an empty array when no valid vectors exist.
    static func build(from diarization: DiarizationResult) -> [SpeakerEmbeddingSet] {
        let rawVectors = filterValid(diarization.speakerCentroidEmbeddings)
        guard !rawVectors.isEmpty else { return [] }

        return [SpeakerEmbeddingSet(
            kind: .raw,
            space: SpeakerEmbeddingSpace.current(),
            vectors: rawVectors
        )]
    }

    /// Keeps only vectors that are non-empty and all-finite.
    private static func filterValid(_ vectors: [Int: [Float]]) -> [Int: [Float]] {
        vectors.filter { _, vector in
            !vector.isEmpty && vector.allSatisfy(\.isFinite)
        }
    }
}

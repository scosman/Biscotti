import Foundation
import SpeakerKit
import Testing
@testable import Transcription

/// Helper to build a minimal `DiarizationResult` for embedding tests.
private func makeDiarization(
    speakerCount: Int = 0,
    raw: [Int: [Float]] = [:],
    plda: [Int: [Float]] = [:]
) -> DiarizationResult {
    DiarizationResult(
        speakerCount: speakerCount,
        totalFrames: 0,
        frameRate: 1.0,
        segments: [],
        speakerCentroidEmbeddings: raw,
        speakerPLDACentroidEmbeddings: plda
    )
}

@Suite("EmbeddingSetBuilder")
struct EmbeddingSetBuilderTests {
    @Test("Both raw and PLDA sets present when diarization has both")
    func bothSetsPresent() {
        let diarization = makeDiarization(
            speakerCount: 2,
            raw: [0: [0.1, 0.2, 0.3], 1: [0.4, 0.5, 0.6]],
            plda: [0: [0.7, 0.8], 1: [0.9, 1.0]]
        )

        let sets = EmbeddingSetBuilder.build(from: diarization)

        #expect(sets.count == 2)
        let rawSet = sets.first { $0.kind == .raw }
        let pldaSet = sets.first { $0.kind == .plda }
        #expect(rawSet != nil)
        #expect(rawSet?.vectors.count == 2)
        #expect(pldaSet != nil)
        #expect(pldaSet?.vectors.count == 2)
    }

    @Test("Empty vectors are dropped")
    func emptyVectorsDropped() throws {
        let diarization = makeDiarization(
            speakerCount: 2,
            raw: [0: [0.1, 0.2], 1: []],
            plda: [0: [0.3, 0.4], 1: [0.5, 0.6]]
        )

        let sets = EmbeddingSetBuilder.build(from: diarization)

        #expect(sets.count == 2)
        let rawSet = try #require(sets.first { $0.kind == .raw })
        #expect(rawSet.vectors.count == 1)
        #expect(rawSet.vectors[0] != nil)
        #expect(rawSet.vectors[1] == nil)
    }

    @Test("Kind with no valid vectors is omitted")
    func kindWithNoVectorsOmitted() {
        let diarization = makeDiarization(
            speakerCount: 1,
            raw: [:],
            plda: [0: [0.1, 0.2]]
        )

        let sets = EmbeddingSetBuilder.build(from: diarization)

        #expect(sets.count == 1)
        #expect(sets[0].kind == .plda)
    }

    @Test("Non-finite vectors are dropped")
    func nonFiniteVectorsDropped() throws {
        let diarization = makeDiarization(
            speakerCount: 2,
            raw: [0: [0.1, Float.nan, 0.3], 1: [0.4, 0.5, 0.6]],
            plda: [0: [Float.infinity, 0.2], 1: [0.3, 0.4]]
        )

        let sets = EmbeddingSetBuilder.build(from: diarization)

        let rawSet = try #require(sets.first { $0.kind == .raw })
        #expect(rawSet.vectors.count == 1)
        #expect(rawSet.vectors[0] == nil)
        #expect(rawSet.vectors[1] != nil)

        let pldaSet = try #require(sets.first { $0.kind == .plda })
        #expect(pldaSet.vectors.count == 1)
        #expect(pldaSet.vectors[0] == nil)
        #expect(pldaSet.vectors[1] != nil)
    }

    @Test("Both empty diarization gives no sets")
    func bothEmptyGivesNoSets() {
        let diarization = makeDiarization()

        let sets = EmbeddingSetBuilder.build(from: diarization)
        #expect(sets.isEmpty)
    }

    @Test("Each set has the correct space key")
    func correctSpaceKeys() throws {
        let diarization = makeDiarization(
            speakerCount: 1,
            raw: [0: [1.0]],
            plda: [0: [2.0]]
        )

        let sets = EmbeddingSetBuilder.build(from: diarization)

        let rawSet = try #require(sets.first { $0.kind == .raw })
        let pldaSet = try #require(sets.first { $0.kind == .plda })

        #expect(rawSet.space == SpeakerEmbeddingSpace.current(.raw))
        #expect(pldaSet.space == SpeakerEmbeddingSpace.current(.plda))
    }
}

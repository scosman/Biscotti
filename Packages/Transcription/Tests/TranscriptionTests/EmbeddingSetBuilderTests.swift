import Foundation
import SpeakerKit
import Testing
@testable import Transcription

/// Helper to build a minimal `DiarizationResult` for embedding tests.
private func makeDiarization(
    speakerCount: Int = 0,
    raw: [Int: [Float]] = [:]
) -> DiarizationResult {
    DiarizationResult(
        speakerCount: speakerCount,
        totalFrames: 0,
        frameRate: 1.0,
        segments: [],
        speakerCentroidEmbeddings: raw
    )
}

@Suite("EmbeddingSetBuilder")
struct EmbeddingSetBuilderTests {
    @Test("Raw set present when diarization has vectors")
    func rawSetPresent() {
        let diarization = makeDiarization(
            speakerCount: 2,
            raw: [0: [0.1, 0.2, 0.3], 1: [0.4, 0.5, 0.6]]
        )

        let sets = EmbeddingSetBuilder.build(from: diarization)

        #expect(sets.count == 1)
        let rawSet = sets.first { $0.kind == .raw }
        #expect(rawSet != nil)
        #expect(rawSet?.vectors.count == 2)
    }

    @Test("Empty vectors are dropped")
    func emptyVectorsDropped() throws {
        let diarization = makeDiarization(
            speakerCount: 2,
            raw: [0: [0.1, 0.2], 1: []]
        )

        let sets = EmbeddingSetBuilder.build(from: diarization)

        #expect(sets.count == 1)
        let rawSet = try #require(sets.first { $0.kind == .raw })
        #expect(rawSet.vectors.count == 1)
        #expect(rawSet.vectors[0] != nil)
        #expect(rawSet.vectors[1] == nil)
    }

    @Test("No valid vectors gives empty result")
    func noVectorsGivesEmpty() {
        let diarization = makeDiarization(
            speakerCount: 1,
            raw: [:]
        )

        let sets = EmbeddingSetBuilder.build(from: diarization)
        #expect(sets.isEmpty)
    }

    @Test("Non-finite vectors are dropped")
    func nonFiniteVectorsDropped() throws {
        let diarization = makeDiarization(
            speakerCount: 2,
            raw: [0: [0.1, Float.nan, 0.3], 1: [0.4, 0.5, 0.6]]
        )

        let sets = EmbeddingSetBuilder.build(from: diarization)

        let rawSet = try #require(sets.first { $0.kind == .raw })
        #expect(rawSet.vectors.count == 1)
        #expect(rawSet.vectors[0] == nil)
        #expect(rawSet.vectors[1] != nil)
    }

    @Test("Empty diarization gives no sets")
    func emptyGivesNoSets() {
        let diarization = makeDiarization()

        let sets = EmbeddingSetBuilder.build(from: diarization)
        #expect(sets.isEmpty)
    }

    @Test("Set has the correct space key")
    func correctSpaceKey() throws {
        let diarization = makeDiarization(
            speakerCount: 1,
            raw: [0: [1.0]]
        )

        let sets = EmbeddingSetBuilder.build(from: diarization)

        let rawSet = try #require(sets.first { $0.kind == .raw })
        #expect(rawSet.space == SpeakerEmbeddingSpace.current())
    }
}

import Foundation
import SpeakerFusion
import Testing
import Transcription
@testable import AppCore

/// Converting fused lines back to a transcript.
@MainActor
struct SpeakerNamingTests {
    static func word(_ text: String, _ start: Double, cluster: Int) -> FusionWord {
        FusionWord(text: " \(text)", start: start, end: start + 0.4, clusterID: cluster)
    }

    static let original = TranscriptResult(
        transcriptionMethodId: "v1", language: "en", speakerCount: 3, segments: [],
        embeddingSets: [SpeakerEmbeddingSet(kind: .raw, space: "test", vectors: [0: [1, 0], 1: [0, 1], 2: [1, 1]])],
        processingDuration: 1
    )

    @Test func userAndNamedPeopleGetIDsNamesAndTheirVoiceprints() {
        let fusion = FusionResult(
            segments: [
                FusedSegment(speaker: .user, words: (0 ..< 5).map { Self.word("me", Double($0), cluster: 0) }),
                FusedSegment(speaker: .person("Jamie Ford"), words: (5 ..< 10).map { Self.word("jamie", Double($0), cluster: 1) }),
                FusedSegment(speaker: .cluster(2), words: [Self.word("who", 11, cluster: 2)])
            ],
            report: FusionReport(hadLevels: true, hadCapture: true, participantsSeen: [])
        )
        let refined = AppCore.refined(from: fusion, original: Self.original, userName: "Sam Carter")

        #expect(refined.speakerNames == [0: "Sam Carter", 1: "Jamie Ford"])
        #expect(refined.result.segments.map(\.speakerID) == [0, 1, 2])
        #expect(refined.result.segments[1].text == "jamie jamie jamie jamie jamie")
        let vectors: [Int: [Float]]? = refined.result.embeddingSets.first?.vectors
        #expect(vectors?[0] == [1, 0])
        #expect(vectors?[1] == [0, 1])
        #expect(vectors?[2] == [1, 1])
    }

    @Test func aVoiceSplitBetweenTwoPeopleLendsItsVoiceprintToNeither() {
        let fusion = FusionResult(
            segments: [
                FusedSegment(speaker: .user, words: (0 ..< 5).map { Self.word("me", Double($0), cluster: 0) }),
                FusedSegment(speaker: .person("Nora Hale"), words: (5 ..< 8).map { Self.word("nora", Double($0), cluster: 1) }),
                FusedSegment(speaker: .user, words: (8 ..< 11).map { Self.word("me", Double($0), cluster: 1) })
            ],
            report: FusionReport(hadLevels: true, hadCapture: true, participantsSeen: [])
        )
        let refined = AppCore.refined(from: fusion, original: Self.original, userName: "Sam Carter")
        let vectors = refined.result.embeddingSets.first?.vectors ?? [:]
        // Sam: 5 of 8 words from cluster 0 (63%): mixed, no voiceprint.
        #expect(vectors[0] == nil)
        // Nora: all his words are cluster 1, but cluster 1 is only 50% Nora.
        #expect(vectors[1] == nil)
    }
}

/// When a re-listened line replaces the original. Cases from
/// a test call.
@MainActor
struct RelistenAcceptanceTests {
    static func line(_ texts: [String], _ probability: Float) -> FusedSegment {
        FusedSegment(speaker: .cluster(1), words: words(texts, probability))
    }

    static func words(_ texts: [String], _ probability: Float) -> [FusionWord] {
        texts.enumerated().map { FusionWord(text: $1, start: Double($0), end: Double($0) + 0.3, probability: probability, clusterID: 1) }
    }

    @Test func fixesLanguageDriftAndUnintelligibleLines() {
        let german = Self.line([" Das", " ist", " das", " und", " verletzt."], 0.25)
        #expect(AppCore.acceptRelisten(old: german, new: Self.words([" it", " nodeware", " and", " blocked", " it."], 0.83)))
        let drift = Self.line([" Der", " Rest", " of", " diese", " sind", " alle", " Lateral-Movement", " auf", " dem"], 0.66)
        #expect(AppCore.acceptRelisten(old: drift, new: Self.words([" the", " rest", " of", " these", " are", " all"], 0.91)))
        let gap = Self.line([" [unintelligible]"], 0)
        #expect(AppCore.acceptRelisten(old: gap, new: Self.words([" I'm", " seeing", " 1670", " entries."], 0.95)))
    }

    @Test func keepsAnOkayLineEvenIfTheClipIsMoreConfident() {
        let okay = Self.line([" What", " happened", " to", " my", " glasses?"], 0.66)
        #expect(!AppCore.acceptRelisten(old: okay, new: Self.words([" Was", " I", " have", " in", " my", " glasses?"], 0.91)))
    }

    @Test func rejectsSmallGainsSingleWordsAndForeignResults() {
        let poor = Self.line([" and", " my", " staff?"], 0.47)
        #expect(!AppCore.acceptRelisten(old: poor, new: Self.words([" off", " the", " half", " we've"], 0.57)))
        #expect(!AppCore.acceptRelisten(old: poor, new: Self.words([" okay"], 0.95)))
        #expect(!AppCore.acceptRelisten(old: poor, new: Self.words([" das", " ist", " nicht", " der", " Fall"], 0.9)))
    }
}

import Foundation
import Testing
@testable import SpeakerFusion

/// Captions correct words Whisper wasn't sure of, nothing else.
struct CaptionRefinementTests {
    private func words(_ spec: [(String, Float)]) -> [FusionWord] {
        spec.enumerated().map { index, item in
            FusionWord(text: " " + item.0, start: 10 + Double(index) * 0.4, end: 10.3 + Double(index) * 0.4, probability: item.1, clusterID: 2)
        }
    }

    private let caption = CaptionLine(name: "Nora Hale", text: "Nora needs to update the firewall rules.", start: 13, end: 14)

    @Test func lowConfidenceWordsTakeTheCaptionsWords() {
        let heard = words([("Nora", 0.95), ("needs", 0.95), ("to", 0.9), ("up", 0.3), ("date", 0.3),
                           ("the", 0.9), ("far", 0.2), ("wall", 0.3), ("rules", 0.9)])
        let result = CaptionAligner.refine(heard, captions: [caption])
        #expect(result.words.map { $0.text.trimmingCharacters(in: .whitespaces) }
            == ["Nora", "needs", "to", "update", "the", "firewall", "rules"])
        #expect(result.replaced == 4)
        #expect(result.words.allSatisfy { $0.clusterID == 2 })
        #expect(zip(result.words, result.words.dropFirst()).allSatisfy { $0.start <= $1.start })
    }

    @Test func confidentWordsAreNeverChanged() {
        let heard = words([("Nora", 0.95), ("needs", 0.95), ("to", 0.9), ("up", 0.9), ("date", 0.9),
                           ("the", 0.9), ("far", 0.9), ("wall", 0.9), ("rules", 0.9)])
        let result = CaptionAligner.refine(heard, captions: [caption])
        #expect(result.replaced == 0)
        #expect(result.words.count == heard.count)
    }

    @Test func aCaptionThatDoesntMatchChangesNothing() {
        let heard = words([("completely", 0.2), ("different", 0.2), ("words", 0.2)])
        #expect(CaptionAligner.refine(heard, captions: [caption]).replaced == 0)
    }
}

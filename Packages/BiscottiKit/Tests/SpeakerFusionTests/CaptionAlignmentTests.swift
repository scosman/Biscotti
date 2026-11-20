import Foundation
import Testing
@testable import SpeakerFusion

/// Caption text decides who said which words.
struct CaptionAlignmentTests {
    private func word(_ text: String, _ start: Double, cluster: Int) -> FusionWord {
        FusionWord(text: " " + text, start: start, end: start + 0.3, clusterID: cluster)
    }

    /// 1:17 of the 2026-11-19 meeting: Sam said "You're muted, Chris." and
    /// diarization split it across two voices.
    @Test func aSplitPhraseGoesBackToOneSpeaker() {
        let words = [word("You're", 77.0, cluster: 0), word("muted,", 77.4, cluster: 4), word("Chris.", 77.8, cluster: 4)]
        let captions = [CaptionLine(name: "Sam Carter", text: "You're muted, Chris.", start: 78.6, end: 79.0)]
        let assigned = CaptionAligner.assign(words, captions: captions)
        #expect(assigned == [0: "Sam Carter", 1: "Sam Carter", 2: "Sam Carter"])

        let result = SpeakerFuser.fuse(
            words: words, levels: nil,
            timeline: ParticipantTimeline(intervals: [], participants: [], captions: captions),
            userName: "Sam Carter"
        )
        #expect(result.segments.count == 1)
        #expect(result.segments.first?.speaker == .user)
    }

    @Test func wordsBetweenMatchesBelongToTheSameCaption() {
        // Whisper heard "Pen test" where the caption says "pentest".
        let words = [word("The", 10, cluster: 1), word("pen", 10.4, cluster: 1), word("test", 10.8, cluster: 2),
                     word("isn't", 11.2, cluster: 1), word("a", 11.6, cluster: 1), word("change", 12.0, cluster: 1)]
        let captions = [CaptionLine(name: "Lee Morgan", text: "The pentest isn't a change", start: 12.5, end: 13)]
        let assigned = CaptionAligner.assign(words, captions: captions)
        #expect(assigned.count == 6)
        #expect(Set(assigned.values) == ["Lee Morgan"])
    }

    @Test func aCaptionWithTooFewMatchesIsIgnored() {
        let words = [word("Completely", 10, cluster: 1), word("different", 10.4, cluster: 1), word("words", 10.8, cluster: 1)]
        let captions = [CaptionLine(name: "Lee Morgan", text: "nothing in common here at all", start: 11, end: 12)]
        #expect(CaptionAligner.assign(words, captions: captions).isEmpty)
    }

    @Test func aCaptionFarFromTheWordsIsIgnored() {
        let words = [word("You're", 10, cluster: 0), word("muted", 10.4, cluster: 0)]
        let captions = [CaptionLine(name: "Sam Carter", text: "You're muted", start: 60, end: 61)]
        #expect(CaptionAligner.assign(words, captions: captions).isEmpty)
    }

    @Test func aVoiceTakesTheNameMostOfItsCaptionedWordsCarry() {
        var words: [FusionWord] = []
        var assigned: [Int: String] = [:]
        for index in 0 ..< 10 {
            words.append(word("w", Double(index), cluster: 3))
            assigned[index] = index < 8 ? "Lee Morgan" : "Chris Doyle"
        }
        #expect(CaptionAligner.clusterNames(words, assigned: assigned).mapValues(\.name) == [3: "Lee Morgan"])
    }

    @Test func twoSpellingsOfOnePersonClaimOneVoice() {
        var words: [FusionWord] = []
        var assigned: [Int: String] = [:]
        for index in 0 ..< 14 {
            let cluster = index < 6 ? 2 : 5
            words.append(word("w", Double(index), cluster: cluster))
            assigned[index] = cluster == 2 ? "Carter, Sam" : "Sam Carter"
        }
        // Voice 5 has more matched words (8 vs 6): it keeps the person.
        #expect(CaptionAligner.clusterNames(words, assigned: assigned).mapValues(\.name) == [5: "Sam Carter"])
    }

    @Test func namesInEitherOrderMatch() {
        #expect(PersonName.same("Carter, Sam", "Sam Carter"))
        #expect(!PersonName.same("Sam Carter", "Nora Hale"))
    }
}

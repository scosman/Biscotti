import Foundation
import Testing
@testable import SpeakerFusion

/// Confidence grows with each turn the screen agrees with.
struct TurnEvidenceTests {
    /// Three words filling one second from `start`.
    private func turn(_ start: Double, cluster: Int) -> [FusionWord] {
        (0 ..< 3).map { index in
            let wordStart = start + Double(index) * 0.35
            return FusionWord(text: " word", start: wordStart, end: wordStart + 0.3, clusterID: cluster)
        }
    }

    @Test func manyAgreeingTurnsAreStrongAndConflictsAreCounted() {
        let henryTurns = [0.0, 4, 8, 12, 16, 20]
        var words = henryTurns.flatMap { turn($0, cluster: 1) }
        words += turn(2, cluster: 2) + turn(6, cluster: 2)
        var intervals = henryTurns.map { SpeakingInterval(name: "Nora Hale", start: $0, end: $0 + 1) }
        intervals.append(SpeakingInterval(name: "Mike Brooks", start: 2, end: 3))
        // At 6 s the screen showed Nora, not whoever voice 2 is.
        intervals.append(SpeakingInterval(name: "Nora Hale", start: 6, end: 7))
        let timeline = ParticipantTimeline(intervals: intervals, participants: ["Nora Hale", "Mike Brooks"])

        let result = SpeakerFuser.fuse(words: words, levels: nil, timeline: timeline, userName: "Sam Carter")

        let nora = try? #require(result.evidence["Nora Hale"])
        #expect(nora?.turns == 6)
        #expect(nora?.agreeingTurns == 6)
        #expect(nora?.strength == .strong)
        #expect(nora?.summary == "Highlighted on screen in 6 of 6 turns")

        let mike = try? #require(result.evidence["Mike Brooks"])
        #expect(mike?.turns == 2)
        #expect(mike?.agreeingTurns == 1)
        #expect(mike?.conflictingTurns == 1)
        #expect(mike?.strength == .weak)
    }

    @Test func fewTurnsCanOnlyReachModerate() {
        let evidence = NameEvidence(turns: 2, agreeingTurns: 2, conflictingTurns: 0)
        #expect(evidence.strength == .moderate)
        #expect(NameEvidence(turns: 3, agreeingTurns: 3, conflictingTurns: 0).strength == .strong)
        #expect(NameEvidence(turns: 20, agreeingTurns: 6, conflictingTurns: 10).strength == .weak)
    }

    @Test func noCaptureMeansNoEvidence() {
        let words = turn(0, cluster: 1)
        let result = SpeakerFuser.fuse(words: words, levels: nil, timeline: nil, userName: "Sam Carter")
        #expect(result.evidence.isEmpty)
    }

    @Test func turnsSplitOnSilenceAndOnOtherVoices() {
        let words = turn(0, cluster: 1) + turn(3, cluster: 1) + turn(4.1, cluster: 2)
        let sources = Array(repeating: WordSource.system, count: words.count)
        let found = SpeakerFuser.turns(words.sorted { $0.start < $1.start }, sources: sources, gap: 1.0)
        #expect(found.map(\.cluster) == [1, 1, 2])
    }
}

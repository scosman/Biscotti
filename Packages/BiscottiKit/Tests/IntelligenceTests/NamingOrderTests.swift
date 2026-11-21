import Foundation
import Testing
import VoiceprintMatching
@testable import Intelligence

/// Voice evidence before AI; the AI only where nothing else is.
struct NamingOrderTests {
    private func match(_ speakerID: Int, _ level: MatchLevel, _ people: [(UUID, Float)]) -> SpeakerMatch {
        SpeakerMatch(
            speakerID: speakerID, level: level,
            candidates: people.map {
                PersonCandidate(
                    personID: $0.0, score: $0.1, reportedDistance: 0,
                    countedMeetings: 2, confirmedCountedMeetings: 1, isInvitee: false
                )
            },
            unnamedMeetingCount: 0
        )
    }

    @Test func strongVoiceMatchesNameSpeakersOncePerPerson() {
        let nora = UUID()
        let pat = UUID()
        let voice = MeetingAnalyzer.voiceAssignments([
            4: match(4, .medium, [(nora, 0.46)]),
            5: match(5, .medium, [(nora, 0.53)]),
            6: match(6, .high, [(pat, 2.1)]),
            7: match(7, .low, [(pat, 0.2)])
        ])
        #expect(voice[5]?.personID == nora)
        #expect(voice[4] == nil)
        #expect(voice[6]?.personID == pat)
        #expect(voice[6]?.provenance.source == .voice)
        #expect(voice[7] == nil)
    }

    @Test func theAIOnlyNamesVoicesWithoutEvidence() {
        let alex = UUID()
        let other = UUID()
        #expect(MeetingAnalyzer.allowsAIPick(personID: alex, match: nil))
        #expect(MeetingAnalyzer.allowsAIPick(personID: alex, match: match(1, .none, [])))
        #expect(MeetingAnalyzer.allowsAIPick(personID: alex, match: match(1, .low, [(alex, 0.2)])))
        #expect(!MeetingAnalyzer.allowsAIPick(personID: other, match: match(1, .low, [(alex, 0.2)])))
        #expect(!MeetingAnalyzer.allowsAIPick(personID: alex, match: match(1, .high, [(alex, 2)])))
    }
}

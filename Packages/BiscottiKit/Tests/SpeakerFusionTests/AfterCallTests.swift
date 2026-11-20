import Foundation
import Testing
import UICapture
@testable import SpeakerFusion

/// Talk after you leave a call isn't part of the meeting.
struct AfterCallTests {
    private func words(at times: [Double]) -> [FusionWord] {
        times.map { FusionWord(text: " w", start: $0, end: $0 + 0.3, clusterID: nil) }
    }

    /// 40 frames of 1 s: call audio loud until `quietFrom`, then silent.
    private func levels(quietFrom: Int) -> LevelTrack {
        LevelTrack(
            frameSeconds: 1,
            micDB: Array(repeating: -30, count: 40),
            systemDB: (0 ..< 40).map { $0 < quietFrom ? -30 : -90 }
        )
    }

    @Test func wordsAfterASilentEndAreDropped() {
        let result = AfterCall.trim(words(at: [5, 10, 19, 25, 30]), callEndedAt: 20, levels: levels(quietFrom: 20))
        #expect(result.words.map(\.start) == [5, 10, 19])
        #expect(result.dropped == 2)
    }

    @Test func aLeaveChimeDoesntCount() {
        // One loud second (the chime) right after the call, then silence.
        var track = levels(quietFrom: 20)
        track.systemDB[21] = -30
        let result = AfterCall.trim(words(at: [5, 25, 30]), callEndedAt: 20, levels: track)
        #expect(result.dropped == 2)
    }

    @Test func nothingIsDroppedWhileCallAudioContinues() {
        let result = AfterCall.trim(words(at: [5, 25, 30]), callEndedAt: 20, levels: levels(quietFrom: 35))
        #expect(result.dropped == 0)
    }

    @Test func nothingIsDroppedWithoutEvidence() {
        #expect(AfterCall.trim(words(at: [5, 25]), callEndedAt: nil, levels: levels(quietFrom: 20)).dropped == 0)
        #expect(AfterCall.trim(words(at: [5, 25]), callEndedAt: 20, levels: nil).dropped == 0)
    }

    @Test func callTimerAndWindowTitles() {
        #expect(ParticipantTimelineBuilder.isCallTimer("31:33"))
        #expect(ParticipantTimelineBuilder.isCallTimer("1:02:07"))
        #expect(!ParticipantTimelineBuilder.isCallTimer("Yesterday"))
        #expect(ParticipantTimelineBuilder.isNonMeetingWindow("Chat | Fabrikam & Contoso Field Team (External)"))
        #expect(!ParticipantTimelineBuilder.isNonMeetingWindow("Fabrikam Holdings IT Project"))
        #expect(PersonName.parse("Mentioned Owen Price") == nil)
    }
}

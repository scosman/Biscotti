import Foundation
import Testing
@testable import SpeakerFusion

/// 11:19 Teams meeting: the user (AirPods), remote1 and remote3 remote.
/// Private recording; see `PrivateFixtures`.
struct Meeting1119Tests {
    static func fused() throws -> FusionResult {
        let raw = try JSONDecoder().decode(
            [SpeakerFusionTests.RawWord].self,
            from: Data(contentsOf: SpeakerFusionTests.fixture("1119-words.json"))
        )
        let levels = try JSONDecoder().decode(
            SpeakerFusionTests.RawLevels.self,
            from: Data(contentsOf: SpeakerFusionTests.fixture("1119-levels.json"))
        )
        let start = try #require(ISO8601DateFormatter().date(from: "2026-11-18T17:19:43Z"))
        let timeline = try ParticipantTimelineBuilder.build(
            captureFile: SpeakerFusionTests.fixture("capture-1116.jsonl"),
            recordingStartedAt: start.addingTimeInterval(0.567)
        )
        return SpeakerFuser.fuse(
            words: raw.map { FusionWord(text: $0.w, start: $0.s, end: $0.e, clusterID: $0.spk) },
            levels: LevelTrack(frameSeconds: levels.frameSeconds, micDB: levels.micDB, systemDB: levels.systemDB),
            timeline: timeline,
            userName: SpeakerFusionTests.name("user")
        )
    }

    /// Answer key from the recording: the user opens and closes, remote3 has
    /// the long stretches, remote1 speaks at ~40 s and ~67 s. An older
    /// transcript wrongly named remote1 as "wrongGuess".
    @Test(.enabled(if: PrivateFixtures.available))
    func everyoneIsNamedCorrectly() throws {
        let result = try Self.fused()
        func speaker(at second: Double) -> FusedSpeaker? {
            result.segments.first { segment in segment.words.contains { abs($0.start - second) < 0.6 } }?.speaker
        }
        let first = FusedSpeaker.person(SpeakerFusionTests.name("remote1"))
        let third = FusedSpeaker.person(SpeakerFusionTests.name("remote3"))
        #expect(speaker(at: 0.3) == .user)
        #expect(speaker(at: 21.2) == .user)
        #expect(speaker(at: 26) == third)
        #expect(speaker(at: 35) == third)
        #expect(speaker(at: 42.5) == first)
        #expect(speaker(at: 46.5) == .user)
        #expect(speaker(at: 55) == third)
        #expect(speaker(at: 67.9) == first)
        #expect(speaker(at: 75) == third)
        #expect(speaker(at: 89.2) == .user)
        #expect(!result.report.namedPeople.contains(SpeakerFusionTests.name("wrongGuess")))
    }
}

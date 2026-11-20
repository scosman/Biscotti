import Foundation
import Testing
@testable import SpeakerFusion

/// Words the engine gave no real timestamps.
struct TimingTests {
    /// 10 s of audio: mic loud from 0 to 5 s, system loud from 5 to 10 s.
    static let levels = LevelTrack(
        frameSeconds: 0.05,
        micDB: Array(repeating: -20, count: 100) + Array(repeating: -90, count: 100),
        systemDB: Array(repeating: -90, count: 100) + Array(repeating: -20, count: 100)
    )

    @Test func collapsedWordsFollowTheirVoiceNotTheLoudnessAtOneInstant() {
        var words: [FusionWord] = []
        // Voice 1 talks clearly from 5 to 9 s (remote).
        for index in 0 ..< 8 {
            let start = 5.0 + Double(index) * 0.5
            words.append(FusionWord(text: " remote", start: start, end: start + 0.4, clusterID: 1))
        }
        // Six more voice-1 words, all stamped at 1.0 s with zero length,
        // where the mic happens to be loud.
        for _ in 0 ..< 6 {
            words.append(FusionWord(text: " lost", start: 1.0, end: 1.0, clusterID: 1))
        }
        let result = SpeakerFuser.fuse(words: words, levels: Self.levels, timeline: nil, userName: "Sam Carter")
        let lost = result.segments.filter { $0.words.contains { $0.text == " lost" } }
        #expect(!lost.isEmpty)
        #expect(lost.allSatisfy { $0.speaker == .cluster(1) })
        #expect(result.report.userWords == 0)
    }

    @Test func collapsedWordsInAMixedVoiceAreNotGivenToTheUser() {
        var words: [FusionWord] = []
        for index in 0 ..< 4 {
            let start = Double(index) * 0.5
            words.append(FusionWord(text: " me", start: start, end: start + 0.4, clusterID: 2))
        }
        for index in 0 ..< 4 {
            let start = 5.0 + Double(index) * 0.5
            words.append(FusionWord(text: " them", start: start, end: start + 0.4, clusterID: 2))
        }
        for _ in 0 ..< 5 {
            words.append(FusionWord(text: " lost", start: 2.0, end: 2.0, clusterID: 2))
        }
        let result = SpeakerFuser.fuse(words: words, levels: Self.levels, timeline: nil, userName: "Sam Carter")
        for segment in result.segments where segment.words.contains(where: { $0.text == " lost" }) {
            #expect(segment.speaker != .user)
        }
    }
}

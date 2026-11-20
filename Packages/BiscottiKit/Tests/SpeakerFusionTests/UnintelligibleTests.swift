import Foundation
import Testing
@testable import SpeakerFusion

/// Speech diarization heard but Whisper couldn't transcribe.
struct UnintelligibleTests {
    /// 30 s: the system track (remote) is loud from 21 to 27.5 s, the mic
    /// is loud from 28 to 29.5 s, both quiet otherwise.
    static let levels: LevelTrack = {
        var mic = [Float](repeating: -80, count: 600)
        var system = [Float](repeating: -80, count: 600)
        for frame in 420 ..< 550 {
            system[frame] = -25
        }
        for frame in 560 ..< 590 {
            mic[frame] = -22
        }
        return LevelTrack(frameSeconds: 0.05, micDB: mic, systemDB: system)
    }()

    static func words(_ cluster: Int, from start: Double, count: Int) -> [FusionWord] {
        (0 ..< count).map {
            FusionWord(text: " word", start: start + Double($0) * 0.4, end: start + Double($0) * 0.4 + 0.3, clusterID: cluster)
        }
    }

    @Test func uncoveredRemoteSpeechBecomesAnUnintelligibleLineForThatVoice() {
        // Voice 3 talks 21-27.5 s; words only from 22.5 to 25.3 s.
        let words = Self.words(3, from: 22.5, count: 7)
        let result = SpeakerFuser.fuse(
            words: words, levels: Self.levels, timeline: nil, userName: "Sam Carter",
            voiceSpans: [VoiceSpan(cluster: 3, start: 21.0, end: 27.5)]
        )
        let marked = result.segments.filter { $0.text == "[unintelligible]" }
        #expect(marked.count == 2)
        #expect(marked.allSatisfy { $0.speaker == .cluster(3) })
        #expect(marked.first.map { abs($0.start - 21.0) < 0.01 } == true)
        #expect(result.report.unintelligibleLines == 2)
        // The real words stay one line between the two gaps.
        #expect(result.segments.map(\.text) == ["[unintelligible]", Array(repeating: "word", count: 7).joined(separator: " "), "[unintelligible]"])
    }

    @Test func aNamedVoiceGivesTheGapItsName() {
        let words = Self.words(3, from: 22.5, count: 7)
        let timeline = ParticipantTimeline(
            intervals: [SpeakingInterval(name: "Nora Hale", start: 22, end: 26)], participants: ["Nora Hale"]
        )
        let result = SpeakerFuser.fuse(
            words: words, levels: Self.levels, timeline: timeline, userName: "Sam Carter",
            voiceSpans: [VoiceSpan(cluster: 3, start: 21.0, end: 27.5)]
        )
        #expect(result.segments.filter { $0.text == "[unintelligible]" }.allSatisfy { $0.speaker == .person("Nora Hale") })
    }

    @Test func quietOrShortOrUnmeasurableGapsAreIgnored() {
        let spans = [
            VoiceSpan(cluster: 1, start: 2, end: 6), // both tracks quiet: noise, not speech
            VoiceSpan(cluster: 3, start: 26.8, end: 27.4) // under a second
        ]
        let quiet = SpeakerFuser.fuse(words: [], levels: Self.levels, timeline: nil, userName: "Sam", voiceSpans: spans)
        // Neither span becomes a line of its own (the loud stretch from 21 s
        // is reported once, as an unidentified voice).
        #expect(!quiet.segments.contains { $0.speaker == .cluster(1) || $0.speaker == .cluster(3) })
        let noLevels = SpeakerFuser.fuse(
            words: [], levels: nil, timeline: nil, userName: "Sam",
            voiceSpans: [VoiceSpan(cluster: 3, start: 21, end: 27)]
        )
        #expect(noLevels.segments.isEmpty)
    }

    @Test func soundsOnTheUsersOwnMicAreNotReported() {
        let result = SpeakerFuser.fuse(
            words: [], levels: Self.levels, timeline: nil, userName: "Sam Carter",
            voiceSpans: [VoiceSpan(cluster: 0, start: 28, end: 29.5)]
        )
        #expect(!result.segments.contains { $0.speaker == .user })
    }

    @Test func remoteSoundNoOneWasHeardSayingIsAnUnidentifiedVoice() {
        // No diarization span at all, no words: like Nora's garbled audio
        // at 0:21 on a test call.
        let result = SpeakerFuser.fuse(words: [], levels: Self.levels, timeline: nil, userName: "Sam Carter")
        let lines = result.segments.filter { $0.text == "[unintelligible]" }
        #expect(lines.count == 1)
        #expect(lines.first?.speaker == .cluster(Unintelligible.unidentifiedCluster))
        #expect(lines.first.map { abs($0.start - 21) < 0.06 && abs($0.end - 27.5) < 0.06 } == true)
    }
}

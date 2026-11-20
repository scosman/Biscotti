import Foundation
import Testing
@testable import SpeakerFusion

/// Fixes from the 2026-11-20 11:08 test call, where three
/// stray voices showed up as "Speaker 3" and "Speaker 4".
struct EchoAndDigitsTests {
    private static func words(_ text: String, from start: Double, step: Double = 0.3, cluster: Int) -> [FusionWord] {
        text.split(separator: " ").enumerated().map { offset, token in
            let begin = start + Double(offset) * step
            return FusionWord(text: " " + token, start: begin, end: begin + step * 0.9, clusterID: cluster)
        }
    }

    /// The mic is loud in `mic` ranges, the meeting audio in `system` ranges.
    private static func levels(mic: [ClosedRange<Double>], system: [ClosedRange<Double>]) -> LevelTrack {
        let frames = 800
        func track(_ ranges: [ClosedRange<Double>]) -> [Float] {
            (0 ..< frames).map { frame in ranges.contains { $0.contains(Double(frame) * 0.1) } ? -20 : -80 }
        }
        return LevelTrack(frameSeconds: 0.1, micDB: track(mic), systemDB: track(system))
    }

    @Test func spokenDigitsMatchACaptionWrittenInDigits() {
        let spoken = Self.words("Testing, testing. One, two, one, two.", from: 36, cluster: 3)
        let captions = [CaptionLine(name: "Owen Price", text: "Testing testing 1212.", start: 35.7, end: 37.7)]
        let assigned = CaptionAligner.assign(spoken, captions: captions)
        #expect(assigned.count == spoken.count)
        #expect(Set(assigned.values) == ["Owen Price"])
    }

    @Test func aLongerCaptionMatchBeatsAShortEarlierOne() {
        // The user said "Can't hear you." and Owen answered "Yeah, I can't
        // hear you either." Both captions fit Owen's words; his is longer.
        let owen = Self.words("Yeah, I can't hear you either.", from: 49.5, step: 0.15, cluster: 2)
        let captions = [
            CaptionLine(name: "Sam Carter", text: "Can't hear you.", start: 45.9, end: 47.9),
            CaptionLine(name: "Owen Price", text: "Yeah, I can't hear you either.", start: 47.9, end: 48.8)
        ]
        let assigned = CaptionAligner.assign(owen, captions: captions)
        #expect(assigned.count == owen.count)
        #expect(Set(assigned.values) == ["Owen Price"])
    }

    private static func echoMeeting() -> (words: [FusionWord], levels: LevelTrack) {
        let said = words("I still can't hear you.", from: 60.6, cluster: 2)
        let echoed = words("I still can't hear you.", from: 62.2, step: 0.15, cluster: 2)
        return (said + echoed, levels(mic: [60.5 ... 62.1], system: [62.2 ... 63.0]))
    }

    @Test func yourVoiceEchoedBackIsDroppedWhenCaptionsVouchForIt() {
        let meeting = Self.echoMeeting()
        let captions = [CaptionLine(name: "Sam Carter", text: "I still can't hear you", start: 60.3, end: 60.3)]
        let result = SpeakerFuser.fuse(
            words: meeting.words, levels: meeting.levels,
            timeline: ParticipantTimeline(intervals: [], participants: [], captions: captions),
            userName: "Sam Carter"
        )
        #expect(result.report.echoWords == 5)
        #expect(result.segments.map(\.text) == ["I still can't hear you."])
        #expect(result.report.summary.contains("dropped 5 words echoing you"))
    }

    @Test func withoutCaptionsNothingIsDroppedAsAnEcho() {
        let meeting = Self.echoMeeting()
        let result = SpeakerFuser.fuse(words: meeting.words, levels: meeting.levels, timeline: nil, userName: "Sam Carter")
        #expect(result.report.echoWords == 0)
    }

    @Test func aRepeatSomeoneElseWasCaptionedSayingIsKept() {
        let meeting = Self.echoMeeting()
        let captions = [
            CaptionLine(name: "Sam Carter", text: "I still can't hear you", start: 60.3, end: 60.3),
            CaptionLine(name: "Owen Price", text: "I still can't hear you", start: 62.5, end: 63.0)
        ]
        let result = SpeakerFuser.fuse(
            words: meeting.words, levels: meeting.levels,
            timeline: ParticipantTimeline(intervals: [], participants: [], captions: captions),
            userName: "Sam Carter"
        )
        #expect(result.report.echoWords == 0)
    }

    @Test func devicesRepliesAndPossessivesAreNotPeople() {
        #expect(PersonName.parse("MacBook Pro Speakers") == nil)
        #expect(PersonName.parse("Sam\u{2019}s AirPods Pro") == nil)
        #expect(PersonName.parse("Yes, Sir.") == nil)
        #expect(PersonName.parse("Yes Sir") == nil)
        #expect(PersonName.parse("Nora Hale") == "Nora Hale")
        #expect(PersonName.isNotAPerson("Sam\u{2019}s AirPods Pro"))
        #expect(PersonName.isNotAPerson("Yes, Sir."))
        #expect(!PersonName.isNotAPerson("Lopez, Maria (AGENCY)"))
    }
}

import Foundation
import Testing
@testable import SpeakerFusion

/// Real data from two Teams meetings with known speakers. The recordings and
/// the names in them are private (see `PrivateFixtures`); roles stand in for
/// the names here: "user" is the person recording, "remote1" and "remote2"
/// the two others at 9:03.
struct SpeakerFusionTests {
    // swiftlint:disable identifier_name
    /// Field names match the fixture files.
    struct RawWord: Decodable {
        let s: Double
        let e: Double
        let w: String
        let spk: Int
    }

    // swiftlint:enable identifier_name

    struct RawLevels: Decodable {
        let frameSeconds: Double
        let micDB: [Float]
        let systemDB: [Float]
    }

    static func fixture(_ name: String) throws -> URL {
        try PrivateFixtures.url(name)
    }

    static func name(_ role: String) -> String {
        PrivateFixtures.name(role)
    }

    struct Meeting {
        let words: [FusionWord]
        let levels: LevelTrack
        let timeline: ParticipantTimeline
    }

    static func meeting0903() throws -> Meeting {
        let raw = try JSONDecoder().decode([RawWord].self, from: Data(contentsOf: fixture("0903-words.json")))
        let levels = try JSONDecoder().decode(RawLevels.self, from: Data(contentsOf: fixture("0903-levels.json")))
        let timeline = try ParticipantTimelineBuilder.build(captureFile: fixture("capture-0903.jsonl"), recordingStartedAt: nil)
        return Meeting(
            words: raw.map { FusionWord(text: $0.w, start: $0.s, end: $0.e, clusterID: $0.spk) },
            levels: LevelTrack(frameSeconds: levels.frameSeconds, micDB: levels.micDB, systemDB: levels.systemDB),
            timeline: timeline
        )
    }

    /// Who actually spoke in the 9:03 meeting (the user on AirPods, two
    /// remote), by recording second. Not asserted: remote1 at 59-63 s
    /// (diarization put them in remote2's voice, so they're named with it)
    /// and "no problem" at 72 s (remote1, in a voice of its own with no
    /// evidence).
    static func expected0903(_ start: Double) -> FusedSpeaker? {
        switch start {
        case 37 ..< 38, 41 ..< 43.5: .person(name("remote1"))
        case 52 ..< 55.2, 64.4 ..< 68.9: .person(name("remote2"))
        case 20 ..< 31.5, 39.5 ..< 40, 44 ..< 51.1, 55.2 ..< 59.2, 63.3 ..< 64.4, 69.1 ..< 71: .user
        default: nil
        }
    }

    @Test(.enabled(if: PrivateFixtures.available))
    func timelineFromTeamsTilesMatchesWhoSpokeAt0903() throws {
        let timeline = try Self.meeting0903().timeline
        let first = Self.name("remote1")
        let second = Self.name("remote2")
        #expect(Set(timeline.participants) == [first, second])
        let firstIntervals = timeline.intervals.filter { $0.name == first }
        let secondIntervals = timeline.intervals.filter { $0.name == second }
        #expect(firstIntervals.contains { $0.start < 42 && $0.end > 43 })
        #expect(firstIntervals.contains { $0.start < 60 && $0.end > 63 })
        #expect(secondIntervals.contains { $0.start < 52 && $0.end > 55 })
        #expect(secondIntervals.contains { $0.start < 66 && $0.end > 69 })
    }

    @Test(.enabled(if: PrivateFixtures.available))
    func everyWordOf0903GetsTheRightSpeaker() throws {
        let meeting = try Self.meeting0903()
        let result = SpeakerFuser.fuse(
            words: meeting.words, levels: meeting.levels, timeline: meeting.timeline, userName: Self.name("user")
        )
        var checked = 0
        for segment in result.segments {
            for word in segment.words {
                if let expected = Self.expected0903(word.start) {
                    #expect(segment.speaker == expected, "\(word.text) at \(word.start)")
                    checked += 1
                } else if word.start > 70 {
                    #expect(segment.speaker != .person(Self.name("remote2")), "\(word.text) at \(word.start)")
                }
            }
        }
        #expect(checked >= 70)
        #expect(Set(result.report.namedPeople) == [Self.name("remote1"), Self.name("remote2")])
        // Lines break where the speaker changes: user, remote1, user, ...
        #expect(result.segments.count >= 12)
    }

    @Test(.enabled(if: PrivateFixtures.available))
    func withoutCaptureTheUserStillGetsTheirLines() throws {
        let meeting = try Self.meeting0903()
        let result = SpeakerFuser.fuse(
            words: meeting.words, levels: meeting.levels, timeline: nil, userName: Self.name("user")
        )
        for segment in result.segments {
            for word in segment.words where Self.expected0903(word.start) == .user {
                #expect(segment.speaker == .user, "\(word.text) at \(word.start)")
            }
        }
        #expect(result.report.namedPeople.isEmpty)
        #expect(result.report.summary.contains("no meeting-window capture"))
    }

    /// 11:19 meeting (user, remote1, remote3), captured by a session started
    /// at 11:16:38 by hand, so the header doesn't name the recording.
    @Test(.enabled(if: PrivateFixtures.available))
    func timelineFrom1119LinesUpWithTheTranscript() throws {
        let recordingStart = try #require(ISO8601DateFormatter().date(from: "2026-11-18T17:19:43Z"))
        let timeline = try ParticipantTimelineBuilder.build(
            captureFile: Self.fixture("capture-1116.jsonl"), recordingStartedAt: recordingStart
        )
        func speaking(_ role: String, at second: Double) -> Bool {
            let name = Self.name(role)
            return timeline.intervals.contains { $0.name == name && $0.start - 1.5 <= second && $0.end + 1.5 >= second }
        }
        let everyone: Set = [Self.name("remote1"), Self.name("remote3"), Self.name("user")]
        #expect(Set(timeline.participants).isSubset(of: everyone))
        // Indicators here are noisy (one headset kept glitching), so only
        // the moments both people clearly started talking are checked.
        #expect(speaking("remote3", at: 28))
        #expect(speaking("remote3", at: 49))
        #expect(speaking("remote3", at: 76))
        #expect(speaking("remote1", at: 42))
        #expect(speaking("remote1", at: 68))
    }

    @Test func namesComeFromLabelsNotControls() {
        #expect(PersonName.parse("Nora Hale, Context menu is available") == "Nora Hale")
        #expect(PersonName.parse("Jamie Ford, muted, Context menu is available") == "Jamie Ford")
        #expect(PersonName.parse("Brooks, Daniel, muted") == "Brooks, Daniel")
        #expect(PersonName.parse("Sam Carter (You)") == "Sam Carter")
        #expect(PersonName.parse("Mute mic") == nil)
        #expect(PersonName.parse("Meeting in General") == nil)
        #expect(PersonName.parse("Chat Nora Hale In a call") == nil)
        #expect(PersonName.parse("Copy meeting link") == nil)
        #expect(PersonName.isMuted("Jamie Ford, muted, Context menu is available"))
        #expect(!PersonName.isMuted("Nora Hale, Unmuted"))
    }

    @Test func mutedHighlightsDoNotNameAnyone() {
        let header = UICaptureTestHeader.make()
        func node(_ path: String, label: String? = nil, classes: [String]? = nil) -> NodeRecordBox {
            NodeRecordBox(path: path, label: label, classes: classes)
        }
        let records = header + [
            UICaptureTestHeader.snapshot(at: 0, nodes: [
                node("0.1", label: "Jamie Ford, muted, Context menu is available"),
                node("0.1.0", classes: ["tile", "idle"])
            ]),
            UICaptureTestHeader.change(at: 10, path: "0.1.0", classes: "tile speaking"),
            UICaptureTestHeader.change(at: 12, path: "0.1.0", classes: "tile idle"),
            UICaptureTestHeader.change(at: 30, path: "0.1.0", classes: "tile speaking"),
            UICaptureTestHeader.change(at: 33, path: "0.1.0", classes: "tile idle"),
            UICaptureTestHeader.end(at: 100)
        ]
        let timeline = ParticipantTimelineBuilder.build(records: records, recordingStartedAt: nil)
        #expect(timeline.intervals.isEmpty)
        #expect(timeline.mutedHighlightsDropped == 2)
    }
}

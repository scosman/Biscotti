import Foundation
import Testing
import UICapture
@testable import SpeakerFusion

/// Teams live captions name who is speaking.
struct CaptionTimelineTests {
    private static func staticText(_ path: String, _ value: String) -> [String: Any] {
        ["path": path, "depth": path.split(separator: ".").count, "role": "AXStaticText", "value": value]
    }

    private static func diff(at time: Double, added: [[String: Any]] = [], changed: [[String: Any]] = []) -> CaptureRecord {
        UICaptureTestHeader.decode(["type": "diff", "data": [
            "uptime": 1000 + time, "bundleID": "app", "window": "0:Meeting",
            "added": added, "removed": [] as [Any], "changed": changed, "walkMillis": 1.0
        ] as [String: Any]])
    }

    /// The panel as Teams draws it: a "Live Captions" group, then entries
    /// whose first child is the speaker and a later child the words.
    private static func meeting() -> [CaptureRecord] {
        var records = UICaptureTestHeader.make()
        records.append(UICaptureTestHeader.snapshot(at: 0, nodes: [
            NodeRecordBox(path: "0"),
            NodeRecordBox(path: "0.2", label: "Live Captions"),
            NodeRecordBox(path: "0.2.0")
        ]))
        records.append(diff(at: 10, added: [
            ["path": "0.2.0.1", "depth": 4, "role": "AXGroup"],
            staticText("0.2.0.1.0", "Lopez, Maria (AGENCY)"),
            staticText("0.2.0.1.2", "[caption 12 chars]")
        ]))
        records.append(diff(at: 12, changed: [["path": "0.2.0.1.2", "fields": ["value": "[caption 40 chars]"]]]))
        records.append(diff(at: 15, added: [
            ["path": "0.2.0.3", "depth": 4, "role": "AXGroup"],
            staticText("0.2.0.3.0", "Sam Carter"),
            staticText("0.2.0.3.1", "[caption 9 chars]")
        ]))
        records.append(diff(at: 20, added: [
            ["path": "0.2.0.5", "depth": 4, "role": "AXGroup"],
            staticText("0.2.0.5.0", "Lopez, Maria (AGENCY)"),
            // A short caption that looks like a name must not become one.
            staticText("0.2.0.5.2", "Doing OK")
        ]))
        records.append(UICaptureTestHeader.end(at: 30))
        return records
    }

    @Test func captionsBecomeSpeakingIntervals() {
        let timeline = ParticipantTimelineBuilder.build(records: Self.meeting(), recordingStartedAt: nil)
        let maria = timeline.intervals.filter { $0.name == "Lopez, Maria" }
        #expect(maria.count == 2)
        #expect(abs((maria.first?.start ?? 0) - 7.5) < 0.01)
        #expect(abs((maria.first?.end ?? 0) - 12.0) < 0.01)
        #expect(timeline.intervals.contains { $0.name == "Sam Carter" })
    }

    @Test func recycledRowsDontCountAsSpeech() {
        var records = Self.meeting()
        records.removeLast()
        // Teams re-renders three old rows at once: nobody spoke.
        records.append(Self.diff(at: 25, changed: [
            ["path": "0.2.0.1.2", "fields": ["value": "[caption 90 chars]"]],
            ["path": "0.2.0.3.1", "fields": ["value": "[caption 70 chars]"]],
            ["path": "0.2.0.5.2", "fields": ["value": "[caption 50 chars]"]]
        ]))
        records.append(UICaptureTestHeader.end(at: 30))
        let timeline = ParticipantTimelineBuilder.build(records: records, recordingStartedAt: nil)
        #expect(!timeline.intervals.contains { $0.end > 21 })
    }

    @Test func captionLinesKeepTheirTextAndGrow() {
        var records = UICaptureTestHeader.make()
        records.append(UICaptureTestHeader.snapshot(at: 0, nodes: [
            NodeRecordBox(path: "0"), NodeRecordBox(path: "0.2", label: "Live Captions"), NodeRecordBox(path: "0.2.0")
        ]))
        records.append(Self.diff(at: 10, added: [
            Self.staticText("0.2.0.1.0", "Sam Carter"), Self.staticText("0.2.0.1.1", "You're")
        ]))
        records.append(Self.diff(at: 11, changed: [["path": "0.2.0.1.1", "fields": ["value": "You're muted, Chris."]]]))
        // The row is reused for a different caption.
        records.append(Self.diff(at: 20, changed: [["path": "0.2.0.1.1", "fields": ["value": "Okay, can you hear me now?"]]]))
        records.append(UICaptureTestHeader.end(at: 30))
        let timeline = ParticipantTimelineBuilder.build(records: records, recordingStartedAt: nil)
        #expect(timeline.captions.map(\.text) == ["You're muted, Chris.", "Okay, can you hear me now?"])
        #expect(timeline.captions.first?.start == 10)
        #expect(timeline.captions.first?.end == 11)
    }

    @Test func captionPanelTextIsNeverAPerson() {
        let timeline = ParticipantTimelineBuilder.build(records: Self.meeting(), recordingStartedAt: nil)
        #expect(Set(timeline.participants) == ["Sam Carter", "Lopez, Maria"])
    }

    @Test func organisationTagsAreStripped() {
        #expect(PersonName.parse("Lopez, Maria (AGENCY)") == "Lopez, Maria")
        #expect(PersonName.parse("Nora Hale (Contractor)") == "Nora Hale")
        #expect(PersonName.parse("Live Captions") == nil)
    }

    @Test func recorderKeepsOnlyTheSpeakerInCaptions() {
        var panel = NodeRecord(path: "0.2", depth: 1)
        panel.label = "Live Captions"
        #expect(TextRedactor.isCaptionArea(panel))
        #expect(TextRedactor.captionPlaceholder("Hey, how are you") == "[caption 16 chars]")
        #expect(TextRedactor.captionPlaceholder("[redacted 57 chars]") == "[caption 57 chars]")
    }
}

/// Prints the timeline of a real capture named by the
/// BISCOTTI_CAPTURE environment variable. Skipped when it isn't set.
struct RealCaptureTimelineTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BISCOTTI_CAPTURE"] != nil))
    func printTimeline() throws {
        let path = try #require(ProcessInfo.processInfo.environment["BISCOTTI_CAPTURE"])
        let timeline = try ParticipantTimelineBuilder.build(captureFile: URL(fileURLWithPath: path), recordingStartedAt: nil)
        print("PARTICIPANTS", timeline.participants)
        print("SEEN", timeline.seen, "CALLEND", timeline.callEndedAt as Any)
        var totals: [String: (count: Int, seconds: Double)] = [:]
        for interval in timeline.intervals {
            let entry = totals[interval.name] ?? (0, 0)
            totals[interval.name] = (entry.count + 1, entry.seconds + interval.end - interval.start)
        }
        for (name, entry) in totals.sorted(by: { $0.key < $1.key }) {
            print("SPEAKER", name, entry.count, "intervals", Int(entry.seconds), "s")
        }
        for line in timeline.captions {
            print(String(format: "CAPTION %6.1f-%6.1f", line.start, line.end), line.name, "|", line.text)
        }
    }
}

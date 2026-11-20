import Foundation
import Testing
import UICapture
@testable import SpeakerFusion

/// When the meeting window says a call ended, and how long a highlight lasts.
struct TimelineEvidenceTests {
    private static func timer(at time: Double) -> CaptureRecord {
        let seconds = Int(time)
        return .event(UIEvent(
            uptime: 1000 + time, bundleID: "app", name: "AXValueChanged",
            value: String(format: "%02d:%02d", seconds / 60, seconds % 60)
        ))
    }

    private static func leaveButton() -> [String: Any] {
        ["path": "0.9", "depth": 2, "role": "AXButton", "label": "Leave"]
    }

    private static func call(windowActiveUntil activeUntil: Double, timerUntil: Double, captureUntil: Double) -> [CaptureRecord] {
        var records = UICaptureTestHeader.make()
        records.append(UICaptureTestHeader.decode(["type": "snapshot", "data": [
            "uptime": 1000.0, "bundleID": "app", "window": "0:Meeting",
            "nodes": [["path": "0", "depth": 1, "role": "AXGroup"], leaveButton()], "walkMillis": 1.0, "truncated": false
        ] as [String: Any]]))
        for second in stride(from: 1.0, through: timerUntil, by: 1) {
            records.append(timer(at: second))
        }
        for second in stride(from: 5.0, through: activeUntil, by: 5) {
            records.append(UICaptureTestHeader.change(at: second, path: "0", classes: "tick \(second)"))
        }
        records.append(UICaptureTestHeader.end(at: captureUntil))
        return records.sorted { uptime($0) < uptime($1) }
    }

    private static func uptime(_ record: CaptureRecord) -> Double {
        switch record {
        case let .header(value): value.startUptime
        case let .snapshot(value): value.uptime
        case let .diff(value): value.uptime
        case let .event(value): value.uptime
        case let .note(value): value.uptime
        }
    }

    @Test func aCallWhoseWindowWentQuietEnded() {
        let timeline = ParticipantTimelineBuilder.build(
            records: Self.call(windowActiveUntil: 30, timerUntil: 30, captureUntil: 60), recordingStartedAt: nil
        )
        let end = try? #require(timeline.callEndedAt)
        #expect(abs((end ?? 0) - 30) < 0.5)
    }

    @Test func aStoppedTimerAloneDoesNotEndTheCall() {
        // The timer stops being read at 30 s, but the call window keeps
        // changing until 55 s: the call is still on.
        let timeline = ParticipantTimelineBuilder.build(
            records: Self.call(windowActiveUntil: 55, timerUntil: 30, captureUntil: 60), recordingStartedAt: nil
        )
        #expect(timeline.callEndedAt == nil)
    }

    @Test func endedNoticesAreRecognised() {
        #expect(ParticipantTimelineBuilder.isEndedNotice("Meeting in \"General\" ended"))
        #expect(ParticipantTimelineBuilder.isEndedNotice("Call ended"))
        #expect(ParticipantTimelineBuilder.isEndedNotice("You left the meeting"))
        #expect(!ParticipantTimelineBuilder.isEndedNotice("The meeting is about the call that ended up late"))
        #expect(!ParticipantTimelineBuilder.isEndedNotice("Recording ended"))
    }

    @Test func aHighlightEndsWhenItsTileLeaves() {
        var records = UICaptureTestHeader.make()
        records.append(UICaptureTestHeader.snapshot(at: 0, nodes: [
            NodeRecordBox(path: "0.1", label: "Nora Hale"),
            NodeRecordBox(path: "0.1.0", classes: ["tile", "idle"])
        ]))
        records.append(UICaptureTestHeader.change(at: 10, path: "0.1.0", classes: "tile speaking"))
        records.append(UICaptureTestHeader.change(at: 12, path: "0.1.0", classes: "tile idle"))
        records.append(UICaptureTestHeader.change(at: 20, path: "0.1.0", classes: "tile speaking"))
        records.append(UICaptureTestHeader.decode(["type": "diff", "data": [
            "uptime": 1022.0, "bundleID": "app", "window": "0:Meeting",
            "added": [] as [Any], "removed": ["0.1.0"], "changed": [] as [Any], "walkMillis": 1.0
        ] as [String: Any]]))
        records.append(UICaptureTestHeader.end(at: 80))
        let timeline = ParticipantTimelineBuilder.build(records: records, recordingStartedAt: nil)
        let nora = timeline.intervals.filter { $0.name == "Nora Hale" }
        #expect(nora.count == 2)
        #expect((nora.map(\.end).max() ?? 0) <= 22.01)
    }

    @Test func aCaptureTaggedForAnotherMeetingIsNeverBorrowed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("captures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func write(_ name: String, meeting: UUID?) throws {
            let header = SessionHeader(
                startedAt: start, startUptime: 1, hostApp: "test", macOSVersion: "test", targets: [],
                recordingMeetingID: meeting
            )
            try CaptureCoding.encodeLine(.header(header)).write(to: folder.appendingPathComponent(name))
            try FileManager.default.setAttributes(
                [.modificationDate: start.addingTimeInterval(600)], ofItemAtPath: folder.appendingPathComponent(name).path
            )
        }
        try write("ui-capture other.jsonl", meeting: UUID())
        let mine = UUID()
        #expect(ParticipantTimelineBuilder.findCapture(
            in: folder, meetingID: mine, recordingStart: start, recordingEnd: start.addingTimeInterval(600)
        ) == nil)
        try write("ui-capture manual.jsonl", meeting: nil)
        #expect(ParticipantTimelineBuilder.findCapture(
            in: folder, meetingID: mine, recordingStart: start, recordingEnd: start.addingTimeInterval(600)
        )?.lastPathComponent == "ui-capture manual.jsonl")
    }

    @Test func theUserIsExcludedWhicheverWayTheNameIsWritten() {
        let timeline = ParticipantTimeline(
            intervals: [SpeakingInterval(name: "Carter, Sam", start: 0, end: 5)], participants: ["Carter, Sam"]
        )
        #expect(timeline.overlaps(from: 0, until: 5, excluding: ["Sam Carter"]).isEmpty)
    }
}

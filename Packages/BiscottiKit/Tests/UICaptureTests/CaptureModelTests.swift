import Foundation
import Testing
@testable import UICapture

@Suite("TextRedactor")
struct TextRedactorTests {
    @Test("keeps names, labels and short status text")
    func keepsShortText() {
        for text in ["Sam Carter", "Priya Shah (Guest)", "Mute", "Sam Carter is speaking", "sam@example.com", "12"] {
            #expect(TextRedactor.redact(text, role: "AXStaticText") == text)
        }
    }

    @Test("drops long text and sentence-shaped text")
    func dropsProse() {
        let long = String(repeating: "a", count: 81)
        #expect(TextRedactor.redact(long, role: nil) == "[redacted 81 chars]")
        #expect(TextRedactor.redact("Can you send me the deck before Friday?", role: nil) == "[redacted 39 chars]")
        #expect(TextRedactor.redact("one two three four five six seven eight nine", role: nil)?.hasPrefix("[redacted") == true)
    }

    @Test("short questions under four words are kept")
    func shortQuestionKept() {
        #expect(TextRedactor.redact("Leave meeting?", role: nil) == "Leave meeting?")
    }

    @Test("text inputs are always dropped, whatever their length")
    func inputsDropped() {
        #expect(TextRedactor.redact("ok", role: "AXTextArea") == "[input 2 chars]")
        #expect(TextRedactor.redact("hi there", role: "AXTextField") == "[input 8 chars]")
    }

    @Test("empty and whitespace become nil")
    func empty() {
        #expect(TextRedactor.redact(nil, role: nil) == nil)
        #expect(TextRedactor.redact("  \n", role: nil) == nil)
    }
}

@Suite("SnapshotDiffer")
struct SnapshotDifferTests {
    func node(_ path: String, role: String = "AXStaticText", title: String? = nil, bold: Bool? = nil, frame: [Int]? = nil) -> NodeRecord {
        var record = NodeRecord(path: path, depth: path.split(separator: ".").count - 1)
        record.role = role
        record.title = title
        record.bold = bold
        record.frame = frame
        return record
    }

    func snap(_ nodes: [NodeRecord], at uptime: Double) -> Snapshot {
        Snapshot(uptime: uptime, bundleID: "com.microsoft.teams2", window: "0:Meeting", nodes: nodes, walkMillis: 12, truncated: false)
    }

    @Test("a speaker turning bold shows up as one changed field")
    func boldFlip() {
        let before = snap([node("0"), node("0.0", title: "Sam Carter", bold: false), node("0.1", title: "Priya Shah", bold: true)], at: 1)
        let after = snap([node("0"), node("0.0", title: "Sam Carter", bold: true), node("0.1", title: "Priya Shah", bold: false)], at: 2)
        let diff = SnapshotDiffer.diff(from: before, to: after)
        #expect(diff.added.isEmpty)
        #expect(diff.removed.isEmpty)
        #expect(diff.changed.count == 2)
        #expect(diff.changed.first { $0.path == "0.0" }?.fields == ["bold": "1"])
        #expect(diff.changed.first { $0.path == "0.1" }?.fields == ["bold": "0"])
        #expect(diff.uptime == 2)
    }

    @Test("a level meter changing size is a frame change")
    func meterFrame() {
        let before = snap([node("0.2", role: "AXImage", frame: [10, 10, 4, 2])], at: 1)
        let after = snap([node("0.2", role: "AXImage", frame: [10, 6, 4, 6])], at: 1.1)
        let diff = SnapshotDiffer.diff(from: before, to: after)
        #expect(diff.changed == [SnapshotDiff.Change(path: "0.2", fields: ["frame": "10,6,4,6"])])
    }

    @Test("added, removed and role-changed nodes")
    func structure() {
        let before = snap([node("0"), node("0.0"), node("0.1", role: "AXButton")], at: 1)
        let after = snap([node("0"), node("0.1", role: "AXGroup"), node("0.2")], at: 2)
        let diff = SnapshotDiffer.diff(from: before, to: after)
        #expect(diff.added.map(\.path) == ["0.1", "0.2"])
        #expect(diff.removed == ["0.0"])
        #expect(diff.changed.isEmpty)
    }

    @Test("a field that disappears is reported as empty")
    func fieldRemoved() {
        let before = snap([node("0.0", title: "Sam Carter")], at: 1)
        let after = snap([node("0.0")], at: 2)
        #expect(SnapshotDiffer.diff(from: before, to: after).changed.first?.fields == ["title": ""])
    }

    @Test("identical snapshots produce an empty diff")
    func identical() {
        let nodes = [node("0"), node("0.0", title: "x")]
        #expect(SnapshotDiffer.diff(from: snap(nodes, at: 1), to: snap(nodes, at: 2)).isEmpty)
    }
}

@Suite("Capture file")
struct CaptureFileTests {
    @Test("every record type round-trips through a JSONL line")
    func roundTrip() throws {
        var node = NodeRecord(path: "0.1", depth: 1)
        node.role = "AXStaticText"
        node.title = "Sam Carter"
        node.domClasses = ["fui-Avatar", "speaking"]
        node.bold = true
        node.fontWeight = 0.4
        let header = SessionHeader(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            startUptime: 1234.5,
            hostApp: "Biscotti test",
            macOSVersion: "27.2.1",
            targets: [TargetApp(bundleID: "us.zoom.xos", name: "Zoom", pid: 42, version: "6.5")],
            recordingMeetingID: UUID()
        )
        let records: [CaptureRecord] = [
            .header(header),
            .snapshot(Snapshot(uptime: 1, bundleID: "us.zoom.xos", window: "0:Zoom", nodes: [node], walkMillis: 3, truncated: true)),
            .diff(SnapshotDiff(
                uptime: 2, bundleID: "us.zoom.xos", window: "0:Zoom",
                added: [node], removed: ["0.9"], changed: [.init(path: "0.1", fields: ["bold": "0"])], walkMillis: 4
            )),
            .event(UIEvent(uptime: 3, bundleID: "us.zoom.xos", name: "AXValueChanged", role: "AXLevelIndicator", value: "0.7")),
            .note(Note(uptime: 4, message: "burst start"))
        ]
        for record in records {
            let line = try CaptureCoding.encodeLine(record)
            #expect(line.last == 0x0A)
            #expect(!line.dropLast().contains(0x0A), "one record per line")
            #expect(try CaptureCoding.decodeLine(line.dropLast()) == record)
        }
    }

    @Test("writer appends lines and stops at the size cap")
    func writerCap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uicapture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try CaptureWriter(url: dir.appendingPathComponent("a/b.jsonl"), maxBytes: 200)
        for index in 0 ..< 20 {
            try writer.write(.note(Note(uptime: Double(index), message: "message \(index)")))
        }
        writer.close()
        let text = try String(contentsOf: writer.url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(writer.isFull)
        #expect(lines.count >= 2 && lines.count < 20)
        #expect(text.utf8.count == writer.bytesWritten)
    }

    @Test("file name")
    func fileName() {
        let date = Date(timeIntervalSince1970: 1_763_391_722) // 2025-11-17 15:02:02 UTC
        let utc = TimeZone(identifier: "UTC") ?? .current
        #expect(CaptureWriter.fileName(for: date, timeZone: utc) == "ui-capture 2025-11-17 150202.jsonl")
    }
}

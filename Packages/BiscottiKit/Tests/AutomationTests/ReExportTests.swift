import Foundation
import Testing
@testable import Automation

/// Keeping an old export when re-transcribing.
struct ReExportTests {
    static func folderTarget() throws -> (ExportTarget, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ExportTarget(name: "Folder", kind: .folder, path: root.path), root)
    }

    @Test func keepingRenamesTheOldFileSoTheNextExportLeavesItAlone() throws {
        let (target, root) = try Self.folderTarget()
        let meetingID = UUID()
        let marker = MeetingMarkdown.idMarker(for: meetingID)
        let old = root.appendingPathComponent("2026-11-18 1129 NORTHWIND \(marker).md")
        try Data("old".utf8).write(to: old)
        try Data("other".utf8).write(to: root.appendingPathComponent("unrelated.md"))

        #expect(MeetingExporter.existingExports(meetingID: meetingID, in: [target]).count == 1)
        let stamp = try #require(ISO8601DateFormatter().date(from: "2026-11-18T21:30:00Z"))
        let renamed = try MeetingExporter.preserveExistingExports(
            meetingID: meetingID, in: [target], now: stamp, timeZone: #require(TimeZone(identifier: "America/Chicago"))
        )

        #expect(renamed.map(\.lastPathComponent) == ["2026-11-18 1129 NORTHWIND \(marker) (before 2026-11-18 1530).md"])
        #expect(MeetingExporter.existingExports(meetingID: meetingID, in: [target]).isEmpty)

        // A new export writes the canonical name and doesn't touch the kept file.
        _ = try MeetingExporter().writeFile("new", named: "2026-11-18 1129 NORTHWIND \(marker).md", meetingID: meetingID, into: root)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names.count == 3)
        #expect(try String(contentsOf: renamed[0], encoding: .utf8) == "old")
    }

    @Test func keepingTwiceInOneMinuteDoesNotOverwrite() throws {
        let (target, root) = try Self.folderTarget()
        let meetingID = UUID()
        let marker = MeetingMarkdown.idMarker(for: meetingID)
        let now = Date()
        for version in ["first", "second"] {
            try Data(version.utf8).write(to: root.appendingPathComponent("Meeting \(marker).md"))
            try MeetingExporter.preserveExistingExports(meetingID: meetingID, in: [target], now: now)
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(kept.count == 2)
    }
}

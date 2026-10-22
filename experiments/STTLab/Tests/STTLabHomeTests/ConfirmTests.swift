import Foundation
import STTLabCore
@testable import STTLabHome
import Testing

/// Fixed UUIDs for deterministic tests.
private let uuids = (0 ..< 10).map { i in
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!
}

@Suite("Confirm")
struct ConfirmTests {
    /// Create a temp workspace with a pre-built selection.json.
    private func writeSelection(
        _ selection: SelectionFile,
        in workspace: URL
    ) throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try JSONFiles.write(selection, to: workspace.appendingPathComponent("selection.json"))
    }

    @Test("Assigns sequential meeting IDs m01, m02, ...")
    func assignsSequentialIDs() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-confirm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let meetings = (0 ..< 3).map { i in
            SelectionEntry(
                meetingUUID: uuids[i],
                title: "M\(i)",
                date: Date(),
                durationSeconds: 1800,
                speakerCount: 2,
                wordCount: 1000,
                wordsPerMinute: 100,
                language: "en"
            )
        }
        let selection = SelectionFile(meetings: meetings)
        try writeSelection(selection, in: tmpDir)

        let log = RunLog(echoToStdout: false)
        let result = try Confirm.run(workspace: tmpDir, log: log)

        #expect(result.meetings[0].meetingID == "m01")
        #expect(result.meetings[1].meetingID == "m02")
        #expect(result.meetings[2].meetingID == "m03")
        #expect(result.confirmed == true)
        #expect(result.confirmedAt != nil)
    }

    @Test("Confirmed hash matches recomputation")
    func hashMatchesRecomputation() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-confirm-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let meetings = [
            SelectionEntry(
                meetingUUID: uuids[0],
                title: "A",
                date: Date(),
                durationSeconds: 1800,
                speakerCount: 2,
                wordCount: 1000,
                wordsPerMinute: 100,
                language: "en"
            )
        ]
        let selection = SelectionFile(meetings: meetings)
        try writeSelection(selection, in: tmpDir)

        let log = RunLog(echoToStdout: false)
        let result = try Confirm.run(workspace: tmpDir, log: log)

        let expected = Confirm.computeHash(meetings: result.meetings)
        #expect(result.confirmedHash == expected)
    }

    @Test("Rejects empty selection")
    func rejectsEmpty() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-confirm-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let selection = SelectionFile(meetings: [])
        try writeSelection(selection, in: tmpDir)

        let log = RunLog(echoToStdout: false)
        #expect(throws: ConfirmError.emptySelection) {
            try Confirm.run(workspace: tmpDir, log: log)
        }
    }

    @Test("Rejects empty appleLocale")
    func rejectsEmptyLocale() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-confirm-locale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let meetings = [
            SelectionEntry(
                meetingUUID: uuids[0],
                title: "Bad Locale",
                date: Date(),
                durationSeconds: 1800,
                speakerCount: 2,
                wordCount: 1000,
                wordsPerMinute: 100,
                language: "en",
                appleLocale: ""
            )
        ]
        let selection = SelectionFile(meetings: meetings)
        try writeSelection(selection, in: tmpDir)

        let log = RunLog(echoToStdout: false)
        #expect(throws: ConfirmError.emptyAppleLocale("Bad Locale")) {
            try Confirm.run(workspace: tmpDir, log: log)
        }
    }

    @Test("Rejects duplicate UUIDs")
    func rejectsDuplicateUUIDs() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-confirm-dup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let meetings = [
            SelectionEntry(
                meetingUUID: uuids[0],
                title: "A",
                date: Date(),
                durationSeconds: 1800,
                speakerCount: 2,
                wordCount: 1000,
                wordsPerMinute: 100,
                language: "en"
            ),
            SelectionEntry(
                meetingUUID: uuids[0],
                title: "B (same UUID)",
                date: Date(),
                durationSeconds: 1800,
                speakerCount: 2,
                wordCount: 1000,
                wordsPerMinute: 100,
                language: "en"
            )
        ]
        let selection = SelectionFile(meetings: meetings)
        try writeSelection(selection, in: tmpDir)

        let log = RunLog(echoToStdout: false)
        #expect(throws: ConfirmError.duplicateUUID(uuids[0])) {
            try Confirm.run(workspace: tmpDir, log: log)
        }
    }

    @Test("Rejects too many meetings")
    func rejectsTooMany() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-confirm-toomany-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Generate 21 unique meetings (over the 20 limit).
        let ids = (0 ..< 21).map {
            UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", $0))!
        }
        let meetings = ids.map { id in
            SelectionEntry(
                meetingUUID: id,
                title: "M",
                date: Date(),
                durationSeconds: 1800,
                speakerCount: 2,
                wordCount: 1000,
                wordsPerMinute: 100,
                language: "en"
            )
        }
        let selection = SelectionFile(meetings: meetings)
        try writeSelection(selection, in: tmpDir)

        let log = RunLog(echoToStdout: false)
        #expect(throws: ConfirmError.tooManyMeetings(21)) {
            try Confirm.run(workspace: tmpDir, log: log)
        }
    }

    @Test("Confirm persists to disk and is readable")
    func persistsToDisk() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-confirm-persist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let meetings = [
            SelectionEntry(
                meetingUUID: uuids[0],
                title: "Persist",
                date: Date(),
                durationSeconds: 1800,
                speakerCount: 2,
                wordCount: 1000,
                wordsPerMinute: 100,
                language: "en"
            )
        ]
        let selection = SelectionFile(meetings: meetings)
        try writeSelection(selection, in: tmpDir)

        let log = RunLog(echoToStdout: false)
        try Confirm.run(workspace: tmpDir, log: log)

        // Re-read from disk.
        let reloaded: SelectionFile = try JSONFiles.read(
            from: tmpDir.appendingPathComponent("selection.json")
        )
        #expect(reloaded.confirmed == true)
        #expect(reloaded.meetings[0].meetingID == "m01")
        #expect(reloaded.confirmedHash != nil)
    }
}

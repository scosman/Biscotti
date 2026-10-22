import Foundation
import STTLabCore
@testable import STTLabHome
import Testing

/// Fixed UUIDs for deterministic tests.
private let uuids = (0 ..< 5).map { i in
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!
}

@Suite("ConsentGate")
struct ConsentGateTests {
    /// Create a workspace with a confirmed selection.
    private func writeConfirmedSelection(in workspace: URL) throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var meetings = [
            SelectionEntry(
                meetingUUID: uuids[0],
                title: "A",
                date: Date(),
                durationSeconds: 1800,
                speakerCount: 2,
                wordCount: 1000,
                wordsPerMinute: 100,
                language: "en",
                meetingID: "m01"
            )
        ]
        let hash = Confirm.computeHash(meetings: meetings)
        let selection = SelectionFile(
            meetings: meetings,
            confirmed: true,
            confirmedAt: Date(),
            confirmedHash: hash
        )
        try JSONFiles.write(selection, to: workspace.appendingPathComponent("selection.json"))
    }

    @Test("Passes when selection is confirmed with valid hash")
    func passesWhenValid() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-gate-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try writeConfirmedSelection(in: tmpDir)
        let result = try ConsentGate.require(workspace: tmpDir)
        #expect(result.confirmed == true)
    }

    @Test("Fails when selection.json is missing")
    func failsMissing() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-gate-missing-\(UUID().uuidString)")

        #expect(throws: ConsentGateError.self) {
            try ConsentGate.require(workspace: tmpDir)
        }
    }

    @Test("Fails when selection is not confirmed")
    func failsNotConfirmed() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-gate-unconfirmed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let selection = SelectionFile(
            meetings: [
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
            ],
            confirmed: false
        )
        try JSONFiles.write(selection, to: tmpDir.appendingPathComponent("selection.json"))

        #expect(throws: ConsentGateError.notConfirmed) {
            try ConsentGate.require(workspace: tmpDir)
        }
    }

    @Test("Fails when hash does not match (selection was modified after confirm)")
    func failsHashMismatch() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-gate-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try writeConfirmedSelection(in: tmpDir)

        // Tamper with the selection: change the appleLocale.
        var selection: SelectionFile = try JSONFiles.read(
            from: tmpDir.appendingPathComponent("selection.json")
        )
        selection.meetings[0].appleLocale = "fr_FR"
        try JSONFiles.write(selection, to: tmpDir.appendingPathComponent("selection.json"))

        #expect(throws: ConsentGateError.hashMismatch) {
            try ConsentGate.require(workspace: tmpDir)
        }
    }
}

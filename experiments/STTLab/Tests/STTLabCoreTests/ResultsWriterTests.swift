import Foundation
import Testing

@testable import STTLabCore

@Suite("ResultsWriter tests")
struct ResultsWriterTests {
    private func tempResultsDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("STTLabCoreTests")
            .appendingPathComponent("results_\(UUID().uuidString)")
    }

    private let bundleID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

    private func makeMachine() -> MachineInfo {
        MachineInfo(
            hostModel: "Mac14,6", chip: "M2",
            memoryBytes: 16_000_000_000, osVersion: "15.0", osBuild: "24A335"
        )
    }

    @Test func ensureResultsDirCreatesStructure() throws {
        let dir = tempResultsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try ResultsWriter.ensureResultsDir(at: dir)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("meetings").path,
            isDirectory: &isDir
        )
        #expect(exists)
        #expect(isDir.boolValue)
    }

    @Test func createAndReloadSession() throws {
        let dir = tempResultsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ResultsWriter.ensureResultsDir(at: dir)

        let session = RunnerSession(
            bundleID: bundleID,
            appVersion: "1.0",
            machine: makeMachine(),
            startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            speechTranscriberAvailable: true,
            supportedLocales: ["en_US"],
            force: false,
            meetingsAttempted: ["m01"],
            meetingsSkipped: ["m02"]
        )
        var runFile = RunFile(sessions: [session])
        try ResultsWriter.writeRunFile(runFile, to: dir)

        let reloaded = ResultsWriter.loadRunFile(from: dir)
        #expect(reloaded.sessions.count == 1)
        #expect(reloaded.sessions[0].bundleID == bundleID)
        #expect(reloaded.sessions[0].meetingsAttempted == ["m01"])

        // Append a second session
        let session2 = RunnerSession(
            bundleID: bundleID,
            appVersion: "1.0",
            machine: makeMachine(),
            startedAt: Date(timeIntervalSinceReferenceDate: 700_010_000),
            speechTranscriberAvailable: true
        )
        runFile.sessions.append(session2)
        try ResultsWriter.writeRunFile(runFile, to: dir)

        let reloaded2 = ResultsWriter.loadRunFile(from: dir)
        #expect(reloaded2.sessions.count == 2)
    }

    @Test func loadRunFileReturnsEmptyWhenMissing() throws {
        let dir = tempResultsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ResultsWriter.ensureResultsDir(at: dir)

        let runFile = ResultsWriter.loadRunFile(from: dir)
        #expect(runFile.sessions.isEmpty)
        #expect(runFile.schemaVersion == SchemaVersions.runFile)
    }

    @Test func writeMeetingResultLandsAtCorrectPath() throws {
        let dir = tempResultsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ResultsWriter.ensureResultsDir(at: dir)

        let result = AppleMeetingResult(
            bundleID: bundleID,
            meetingID: "m03",
            status: .completed,
            requestedLocale: "en_US",
            config: AppleConfig(),
            audioDurationSeconds: 1800.0,
            results: []
        )
        try ResultsWriter.writeMeetingResult(result, meetingID: "m03", resultsURL: dir)

        // Verify file exists at the expected path
        let expectedPath = dir
            .appendingPathComponent("meetings")
            .appendingPathComponent("m03")
            .appendingPathComponent("apple.json")
        #expect(FileManager.default.fileExists(atPath: expectedPath.path))

        // Verify round-trip through load
        let loaded = ResultsWriter.loadMeetingResult(meetingID: "m03", resultsURL: dir)
        #expect(loaded != nil)
        #expect(loaded == result)
    }

    @Test func loadMeetingResultReturnsNilWhenMissing() throws {
        let dir = tempResultsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ResultsWriter.ensureResultsDir(at: dir)

        let loaded = ResultsWriter.loadMeetingResult(meetingID: "m99", resultsURL: dir)
        #expect(loaded == nil)
    }

    @Test func logURLPointsToCorrectFile() {
        let dir = URL(fileURLWithPath: "/tmp/test-results")
        let logURL = ResultsWriter.logURL(dir)
        #expect(logURL.lastPathComponent == "log.txt")
        #expect(logURL.deletingLastPathComponent().path == dir.path)
    }
}

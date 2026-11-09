import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import AudioImport

@Suite("AudioImportController")
@MainActor
struct AudioImportControllerTests {
    // MARK: - Helpers

    private struct Harness {
        let controller: AudioImportController
        let store: DataStore
        let converter: FakeAudioConverter
        let root: URL

        @MainActor
        static func make(testName: String = "AICTest") throws -> Harness {
            let store = try DataStore(storage: .inMemory)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(testName)-\(UUID())")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
            let converter = FakeAudioConverter()
            let controller = AudioImportController(
                store: store,
                recordingsRoot: root,
                converter: converter
            )
            return Harness(
                controller: controller, store: store,
                converter: converter, root: root
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        /// Creates a real temp file for import.
        func tempFile(name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(repeating: 0x42, count: 64).write(to: url)
            return url
        }
    }

    // MARK: - Basic flow

    @Test("add files processes in order")
    func addFilesInOrder() async throws {
        let harness = try Harness.make(testName: "InOrder")
        defer { harness.cleanup() }

        let file1 = try harness.tempFile(name: "a.wav")
        let file2 = try harness.tempFile(name: "b.wav")
        let file3 = try harness.tempFile(name: "c.wav")

        harness.controller.add([.file(file1), .file(file2), .file(file3)])
        await harness.controller.awaitIdle()

        #expect(harness.converter.convertedSources.map(\.lastPathComponent) ==
            ["a.wav", "b.wav", "c.wav"])
    }

    @Test("done creates meeting with placeholder title")
    func doneCreatesMeeting() async throws {
        let harness = try Harness.make(testName: "DoneMeeting")
        defer { harness.cleanup() }

        let file = try harness.tempFile(name: "call.m4a")
        harness.controller.add([.file(file)])
        await harness.controller.awaitIdle()

        let item = harness.controller.items[0]
        guard case let .done(meetingID) = item.status else {
            Issue.record("expected .done, got \(item.status)")
            return
        }

        // Verify meeting exists in store
        let title = try await harness.store.read { store in
            try store.meeting(id: meetingID)?.title
        }
        #expect(title == "Imported from call.m4a")

        // Verify placeholder flag
        let isPlaceholder = try await harness.store.read { store in
            try store.meeting(id: meetingID)?.titleIsPlaceholder
        }
        #expect(isPlaceholder == true)
    }

    @Test("failed conversion leaves no meeting")
    func failedNoMeeting() async throws {
        let harness = try Harness.make(testName: "FailedNoMeeting")
        defer { harness.cleanup() }

        let file = try harness.tempFile(name: "bad.wav")
        harness.converter.outcomes["bad.wav"] = .failure(.noAudio)

        harness.controller.add([.file(file)])
        await harness.controller.awaitIdle()

        guard case let .failed(reason) = harness.controller.items[0].status else {
            Issue.record("expected .failed")
            return
        }
        #expect(reason == .noAudio)

        // No meetings should exist
        let count = try await harness.store.read { store in
            try store.recentMeetings(limit: 100).count
        }
        #expect(count == 0)
    }

    // MARK: - Date handling

    @Test("nil date falls back to addedAt")
    func nilDateFallback() async throws {
        let harness = try Harness.make(testName: "NilDate")
        defer { harness.cleanup() }

        let file = try harness.tempFile(name: "nodate.wav")
        harness.controller.add([.file(file)])
        await harness.controller.awaitIdle()

        let item = harness.controller.items[0]
        // meetingDate should be the addedAt (no metadata date available from
        // a temp file with no embedded metadata).
        #expect(item.meetingDate != nil)
    }

    // MARK: - Session state

    @Test("run cleared when idle")
    func runClearedWhenIdle() async throws {
        let harness = try Harness.make(testName: "RunCleared")
        defer { harness.cleanup() }

        let file = try harness.tempFile(name: "one.wav")
        harness.controller.add([.file(file)])
        #expect(harness.controller.run != nil)

        await harness.controller.awaitIdle()
        #expect(harness.controller.run == nil)
        #expect(!harness.controller.hasPendingWork)
    }

    @Test("hasSession is true after add, stays true when idle")
    func hasSession() async throws {
        let harness = try Harness.make(testName: "HasSession")
        defer { harness.cleanup() }

        #expect(!harness.controller.hasSession)

        let file = try harness.tempFile(name: "x.wav")
        harness.controller.add([.file(file)])
        #expect(harness.controller.hasSession)

        await harness.controller.awaitIdle()
        #expect(harness.controller.hasSession) // Items persist
    }

    // MARK: - Callback

    @Test("onItemFinished fires for each item")
    func onItemFinished() async throws {
        let harness = try Harness.make(testName: "OnFinished")
        defer { harness.cleanup() }

        var finished: [ImportFinished] = []
        harness.controller.onItemFinished = { result in
            finished.append(result)
        }

        let file1 = try harness.tempFile(name: "ok.wav")
        let file2 = try harness.tempFile(name: "fail.wav")
        harness.converter.outcomes["fail.wav"] = .failure(.unreadable)

        harness.controller.add([.file(file1), .file(file2)])
        await harness.controller.awaitIdle()

        #expect(finished.count == 2)
        #expect(finished[0].batchSize == 2)
        #expect(finished[1].batchSize == 2)
    }

    // MARK: - Staging cleanup

    @Test("cleanStaging removes .import-staging directory")
    func cleanStaging() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-\(UUID())")
        let staging = root.appendingPathComponent(".import-staging")
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true
        )
        try Data(repeating: 0xFF, count: 16)
            .write(to: staging.appendingPathComponent("leftover.aac"))

        AudioImportController.cleanStaging(recordingsRoot: root)

        #expect(!FileManager.default.fileExists(atPath: staging.path))
        try? FileManager.default.removeItem(at: root)
    }
}

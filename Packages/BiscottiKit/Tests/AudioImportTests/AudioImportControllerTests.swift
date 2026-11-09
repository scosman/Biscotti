import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import AudioImport

@Suite("AudioImportController")
@MainActor
// swiftlint:disable:next type_body_length
struct AudioImportControllerTests {
    // MARK: - Helpers

    private struct Harness {
        let controller: AudioImportController
        let store: DataStore
        let converter: FakeAudioConverter
        let metadata: FakeMetadataReader
        let root: URL

        @MainActor
        static func make(
            testName: String = "AICTest",
            metadataDate: Date?? = .none
        ) throws -> Harness {
            let store = try DataStore(storage: .inMemory)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(testName)-\(UUID())")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
            let converter = FakeAudioConverter()
            let metadata = FakeMetadataReader(date: metadataDate ?? nil)
            let controller = AudioImportController(
                store: store,
                recordingsRoot: root,
                converter: converter,
                metadata: metadata
            )
            return Harness(
                controller: controller, store: store,
                converter: converter, metadata: metadata, root: root
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

    // MARK: - Promises

    @Test("promised delivery updates name and converts")
    func promisedDeliveredUpdatesName() async throws {
        let harness = try Harness.make(testName: "PromiseOK")
        defer { harness.cleanup() }

        // Place the promised file in a dedicated receiving directory
        // (outside recordingsRoot) so cleanup doesn't mask the result.
        let receivingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("promise-recv-\(UUID())")
        try FileManager.default.createDirectory(
            at: receivingDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: receivingDir) }

        let file = receivingDir.appendingPathComponent("real-audio.wav")
        try Data(repeating: 0x42, count: 64).write(to: file)
        let localFile = file // capture for Sendable closure

        harness.controller.add([
            .promised(
                displayName: "placeholder",
                deliver: { localFile }
            )
        ])
        await harness.controller.awaitIdle()

        let item = harness.controller.items[0]
        #expect(item.displayName == "real-audio.wav")
        guard case let .done(meetingID) = item.status else {
            Issue.record("expected .done, got \(item.status)")
            return
        }
        #expect(harness.converter.convertedSources.count == 1)

        // Verify the final audio file exists in the meeting directory.
        let systemAAC = harness.root
            .appendingPathComponent(meetingID.uuidString)
            .appendingPathComponent("system.aac")
        #expect(
            FileManager.default.fileExists(atPath: systemAAC.path),
            "system.aac must exist after import"
        )
    }

    @Test("promised delivery failure marks unreadable, queue continues")
    func promisedDeliveryFails() async throws {
        let harness = try Harness.make(testName: "PromiseFail")
        defer { harness.cleanup() }

        let goodFile = try harness.tempFile(name: "good.wav")
        harness.controller.add([
            .promised(displayName: "bad", deliver: {
                throw ImportFailure.unreadable
            }),
            .file(goodFile)
        ])
        await harness.controller.awaitIdle()

        // First item failed.
        guard case let .failed(reason) = harness.controller.items[0].status
        else {
            Issue.record("expected .failed")
            return
        }
        #expect(reason == .unreadable)

        // Second item succeeded -- queue continued.
        guard case .done = harness.controller.items[1].status else {
            Issue.record("expected .done for second item")
            return
        }
    }

    @Test("promised item blocks worker until delivered, FIFO preserved")
    func promisedBlocksWorkerFIFO() async throws {
        let harness = try Harness.make(testName: "PromiseFIFO")
        defer { harness.cleanup() }

        let deliveredFile = try harness.tempFile(name: "delayed.wav")
        let localFile = deliveredFile // capture for Sendable closure

        // Use an AsyncStream to control when the promise resolves.
        let (stream, continuation) = AsyncStream<URL>.makeStream()

        harness.controller.add([
            .promised(displayName: "delayed", deliver: {
                // Block until the test yields a URL via the stream.
                for await url in stream {
                    return url
                }
                throw ImportFailure.unreadable
            })
        ])

        // The item should be .receiving while the promise is pending.
        #expect(harness.controller.items[0].status == .receiving)

        // Deliver the file.
        continuation.yield(localFile)
        continuation.finish()

        await harness.controller.awaitIdle()

        // After delivery, the item should be converted.
        let item = harness.controller.items[0]
        guard case .done = item.status else {
            Issue.record("expected .done, got \(item.status)")
            return
        }
        #expect(harness.converter.convertedSources.count == 1)
    }

    // MARK: - Date handling

    @Test("future date clamped to addedAt")
    func futureDateClamped() async throws {
        let futureDate = Date().addingTimeInterval(86400) // 1 day ahead
        let harness = try Harness.make(
            testName: "FutureDate",
            metadataDate: .some(futureDate)
        )
        defer { harness.cleanup() }

        let file = try harness.tempFile(name: "future.wav")
        harness.controller.add([.file(file)])
        await harness.controller.awaitIdle()

        let item = harness.controller.items[0]
        // The future date must be clamped to addedAt.
        #expect(item.meetingDate == item.addedAt)
    }

    @Test("nil date falls back to addedAt")
    func nilDateFallback() async throws {
        let harness = try Harness.make(
            testName: "NilDate",
            metadataDate: .some(nil)
        )
        defer { harness.cleanup() }

        let file = try harness.tempFile(name: "nodate.wav")
        harness.controller.add([.file(file)])
        await harness.controller.awaitIdle()

        let item = harness.controller.items[0]
        // nil metadata date must fall back to exactly addedAt.
        #expect(item.meetingDate == item.addedAt)
    }

    // MARK: - Run tracking

    @Test("add while running extends run and appends items")
    func addWhileRunningExtendsRun() async throws {
        let harness = try Harness.make(testName: "ExtendRun")
        defer { harness.cleanup() }

        let (entered, resume) = harness.converter.installGate()

        let file1 = try harness.tempFile(name: "first.wav")
        harness.controller.add([.file(file1)])

        // Wait until converter is gated (first item is .converting).
        await entered()

        #expect(harness.controller.run?.count == 1)

        // Add more while running.
        let file2 = try harness.tempFile(name: "second.wav")
        harness.controller.add([.file(file2)])

        #expect(harness.controller.run?.count == 2)
        #expect(harness.controller.items.count == 2)

        resume()
        await harness.controller.awaitIdle()

        #expect(harness.converter.convertedSources.count == 2)
    }

    @Test("runPosition tracks the converting item (1-based)")
    func runPositionTracksConverting() async throws {
        let harness = try Harness.make(testName: "RunPos")
        defer { harness.cleanup() }

        let (entered, resume) = harness.converter.installGate()

        let file1 = try harness.tempFile(name: "a.wav")
        let file2 = try harness.tempFile(name: "b.wav")
        harness.controller.add([.file(file1), .file(file2)])

        // Gate catches the first item.
        await entered()

        // First item is converting -> runPosition == 1.
        #expect(harness.controller.runPosition == 1)

        resume()
        await harness.controller.awaitIdle()

        // After idle, no item is converting -> runPosition == nil.
        #expect(harness.controller.runPosition == nil)
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

    // MARK: - isConverting via gate

    @Test("isConverting is true while converter is working")
    func isConvertingDuringWork() async throws {
        let harness = try Harness.make(testName: "IsConverting")
        defer { harness.cleanup() }

        let (entered, resume) = harness.converter.installGate()

        let file = try harness.tempFile(name: "gate.wav")
        harness.controller.add([.file(file)])

        await entered()
        #expect(harness.controller.isConverting)

        resume()
        await harness.controller.awaitIdle()
        #expect(!harness.controller.isConverting)
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

// MARK: - FakeMetadataReader

/// Returns a scripted date for all files.
private struct FakeMetadataReader: ImportMetadataReading {
    let date: Date?

    func meetingDate(for _: URL) async -> Date? {
        date
    }
}

import BiscottiTestSupport
import DataStore
import Foundation
import ImportExport
import Testing
@testable import AppCore

@Suite("AppCore -- Send to app")
@MainActor
struct AppCoreSendToTests {
    // MARK: - Helpers

    /// Mutable reference box for tracking fake environment calls.
    final class FakeBox: @unchecked Sendable {
        var schemeURLs: [String: URL] = [:]
        var bundleIDURLs: [String: URL] = [:]
        var openURLResult: Bool = true
        var openFileError: (any Error)?
        var openedURLs: [URL] = []
        var openedFiles: [(file: URL, app: URL)] = []
        var openedApps: [URL] = []
        var pasteboardText: String?
        var tempDir: URL = FileManager.default.temporaryDirectory
        var fixedDate = Date(timeIntervalSinceReferenceDate: 810_000_000)
        // swiftlint:disable:next force_unwrapping
        var fixedTimeZone = TimeZone(identifier: "America/New_York")!
    }

    private static func makeSendEnv(_ box: FakeBox) -> SendEnvironment {
        SendEnvironment(
            appURLForScheme: { scheme in box.schemeURLs[scheme] },
            appURLForBundleID: { id in box.bundleIDURLs[id] },
            openURL: { url in
                box.openedURLs.append(url)
                return box.openURLResult
            },
            openFile: { fileURL, appURL in
                box.openedFiles.append((fileURL, appURL))
                if let err = box.openFileError { throw err }
            },
            openApp: { url in box.openedApps.append(url) },
            writePasteboard: { text in box.pasteboardText = text },
            tempRoot: { box.tempDir },
            now: { box.fixedDate },
            timeZone: { box.fixedTimeZone }
        )
    }

    private static func makeSource(meetingID: UUID) -> ExportSource {
        ExportSource(
            meetingID: meetingID,
            title: "Weekly Sync",
            start: Date(timeIntervalSinceReferenceDate: 810_000_000),
            durationMinutes: 42,
            attendees: ["Alice", "Bob"],
            summary: "## Key points\n\n- Item one",
            notes: "Follow up on Q3",
            tags: ["project-x"]
        )
    }

    private static let obsidianAppURL = URL(fileURLWithPath: "/Applications/Obsidian.app")
    private static let notesAppURL = URL(fileURLWithPath: "/System/Applications/Notes.app")

    /// Creates a core fixture with the fake send environment injected.
    private static func makeFixture(
        testName: String,
        box: FakeBox
    ) throws -> CoreFixture {
        let fix = try makeCoreFixture(
            sendEnvironment: makeSendEnv(box),
            testName: testName
        )
        box.tempDir = fix.storageRoot
        return fix
    }

    // MARK: - URL send (Obsidian)

    @Test("URL send records the export with the correct hash")
    func urlSendRecordsExport() async throws {
        let box = FakeBox()
        box.schemeURLs["obsidian"] = Self.obsidianAppURL

        let fix = try Self.makeFixture(testName: "SendTo-URLSend", box: box)
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Weekly Sync")
        let source = Self.makeSource(meetingID: meetingID)
        let outcome = await fix.core.send(source, to: .obsidian)

        #expect(outcome == .sent)
        #expect(box.openedURLs.count == 1)

        let records = try await fix.store.sentExports(meetingID: meetingID)
        #expect(records.count == 1)
        #expect(records.first?.destination == .obsidian)
        #expect(records.first?.contentHash.count == 64)
    }

    // MARK: - openURL failure

    @Test("openURL returns false -> .failed with no record")
    func openURLFails() async throws {
        let box = FakeBox()
        box.schemeURLs["obsidian"] = Self.obsidianAppURL
        box.openURLResult = false

        let fix = try Self.makeFixture(testName: "SendTo-URLFail", box: box)
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Test")
        let source = Self.makeSource(meetingID: meetingID)
        let outcome = await fix.core.send(source, to: .obsidian)

        #expect(outcome == .failed)
        let records = try await fix.store.sentExports(meetingID: meetingID)
        #expect(records.isEmpty)
    }

    // MARK: - Notes file hand-off

    @Test("Notes file hand-off writes file and records export")
    func notesHandOff() async throws {
        let box = FakeBox()
        box.bundleIDURLs["com.apple.Notes"] = Self.notesAppURL

        let fix = try Self.makeFixture(testName: "SendTo-Notes", box: box)
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Weekly Sync")
        let source = Self.makeSource(meetingID: meetingID)
        let outcome = await fix.core.send(source, to: .appleNotes)

        #expect(outcome == .sent)
        #expect(box.openedFiles.count == 1)
        #expect(box.openedFiles.first?.app == Self.notesAppURL)

        let fileURL = try #require(box.openedFiles.first?.file)
        #expect(fileURL.lastPathComponent == "Weekly Sync.md")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let records = try await fix.store.sentExports(meetingID: meetingID)
        #expect(records.count == 1)
        #expect(records.first?.destination == .appleNotes)
    }

    // MARK: - openFile throws

    @Test("openFile throws -> .failed with no record")
    func openFileThrows() async throws {
        let box = FakeBox()
        box.bundleIDURLs["com.apple.Notes"] = Self.notesAppURL
        box.openFileError = NSError(domain: "test", code: 1)

        let fix = try Self.makeFixture(testName: "SendTo-NotesFail", box: box)
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Test")
        let source = Self.makeSource(meetingID: meetingID)
        let outcome = await fix.core.send(source, to: .appleNotes)

        #expect(outcome == .failed)
        let records = try await fix.store.sentExports(meetingID: meetingID)
        #expect(records.isEmpty)
    }

    // MARK: - Not installed

    @Test("Not installed -> .failed")
    func notInstalled() async throws {
        let box = FakeBox()

        let fix = try Self.makeFixture(testName: "SendTo-NoApp", box: box)
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Test")
        let source = Self.makeSource(meetingID: meetingID)
        let outcome = await fix.core.send(source, to: .obsidian)

        #expect(outcome == .failed)
    }

    // MARK: - installedSendDestinations

    @Test("installedSendDestinations returns correct order and filters")
    func installedDestinationsFiltering() throws {
        let box = FakeBox()
        box.schemeURLs["obsidian"] = Self.obsidianAppURL
        box.bundleIDURLs["com.apple.Notes"] = Self.notesAppURL

        let fix = try Self.makeFixture(testName: "SendTo-Detect", box: box)
        defer { fix.cleanup() }

        let destinations = fix.core.installedSendDestinations()
        #expect(destinations == [.obsidian, .appleNotes])
    }

    // MARK: - Oversize (clipboard fallback)

    @Test("Oversize URL -> clipboard fallback, no record")
    func oversizeClipboard() async throws {
        let box = FakeBox()
        box.schemeURLs["obsidian"] = Self.obsidianAppURL

        let fix = try Self.makeFixture(testName: "SendTo-Oversize", box: box)
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Huge")
        var source = Self.makeSource(meetingID: meetingID)
        source.notes = String(repeating: "X", count: 600_000)

        let outcome = await fix.core.send(source, to: .obsidian)

        #expect(outcome == .copiedToClipboard)
        #expect(box.pasteboardText != nil)
        #expect(box.openedURLs.isEmpty)
        let records = try await fix.store.sentExports(meetingID: meetingID)
        #expect(records.isEmpty)
    }
}

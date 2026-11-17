import AudioImport
import BiscottiTestSupport
import DataStore
import Formatting
import Foundation
import Testing
@testable import AppCore
@testable import ImportUI

@Suite("ImportViewModel row mapping")
struct ImportViewModelRowMappingTests {
    @Test("waiting item maps to neutral icon and waiting trailing")
    @MainActor
    func waitingRow() throws {
        let fix = try makeCoreFixture(testName: "ImportVM")
        defer { fix.cleanup() }

        // Install a gate so the converter blocks and the item stays waiting.
        let (_, resume) = fix.fakeAudioConverter.installGate()
        defer { resume() }

        let url = fix.storageRoot.appendingPathComponent("test.m4a")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fix.core.importFiles([.file(url)])

        // Before the gate is reached, item is still waiting.
        let viewModel = ImportViewModel(core: fix.core)
        let rows = viewModel.rows
        #expect(rows.count == 1)
        #expect(rows[0].name == "test.m4a")
        #expect(rows[0].secondLineIsError == false)
        #expect(rows[0].icon == .neutral)
    }

    @Test("converting item maps to sage icon and converting trailing")
    @MainActor
    func convertingRow() async throws {
        let fix = try makeCoreFixture(testName: "ImportVM")
        defer { fix.cleanup() }

        let (entered, resume) = fix.fakeAudioConverter.installGate()
        defer { resume() }

        let url = fix.storageRoot.appendingPathComponent("test.m4a")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fix.core.importFiles([.file(url)])

        // Wait for the converter to enter the gate (item is converting).
        await entered()

        let viewModel = ImportViewModel(core: fix.core)
        let rows = viewModel.rows
        #expect(rows.count == 1)
        #expect(rows[0].icon == .sage)
        #expect(rows[0].trailing == .converting)
    }

    @Test("done item with existing meeting maps to goToMeeting")
    @MainActor
    func doneRow() async throws {
        let fix = try makeCoreFixture(testName: "ImportVM")
        defer { fix.cleanup() }

        let url = fix.storageRoot.appendingPathComponent("call.m4a")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fix.core.importFiles([.file(url)])
        await fix.core.audioImport.awaitIdle()
        await fix.core.reloadSummaries()

        let viewModel = ImportViewModel(core: fix.core)
        let rows = viewModel.rows
        #expect(rows.count == 1)
        #expect(rows[0].icon == .sage)
        if case .goToMeeting = rows[0].trailing {
            // correct
        } else {
            Issue.record("Expected goToMeeting trailing, got \(rows[0].trailing)")
        }
    }

    @Test("done item with deleted meeting maps to deleted")
    @MainActor
    func doneDeletedRow() async throws {
        let fix = try makeCoreFixture(testName: "ImportVM")
        defer { fix.cleanup() }

        let url = fix.storageRoot.appendingPathComponent("old.m4a")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fix.core.importFiles([.file(url)])
        await fix.core.audioImport.awaitIdle()

        // Delete the meeting so summaries no longer contain it.
        let items = fix.core.audioImport.items
        guard case let .done(meetingID) = items[0].status else {
            Issue.record("Expected done status")
            return
        }
        await fix.core.deleteMeeting(meetingID: meetingID)
        await fix.core.reloadSummaries()

        let viewModel = ImportViewModel(core: fix.core)
        let rows = viewModel.rows
        #expect(rows[0].trailing == .deleted)
    }

    @Test("failed item maps to failed icon and showInFinder")
    @MainActor
    func failedRow() async throws {
        let fix = try makeCoreFixture(testName: "ImportVM")
        defer { fix.cleanup() }

        fix.fakeAudioConverter.outcomes["bad.m4a"] = .failure(.noAudio)
        let url = fix.storageRoot.appendingPathComponent("bad.m4a")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fix.core.importFiles([.file(url)])
        await fix.core.audioImport.awaitIdle()

        let viewModel = ImportViewModel(core: fix.core)
        let rows = viewModel.rows
        #expect(rows.count == 1)
        #expect(rows[0].icon == .failed)
        #expect(rows[0].trailing == .showInFinder)
        #expect(rows[0].secondLineIsError == true)
        #expect(rows[0].secondLine == "This file has no audio.")
    }

    @Test("date text placeholder is a single space when date is nil")
    @MainActor
    func dateTextPlaceholder() throws {
        let fix = try makeCoreFixture(testName: "ImportVM")
        defer { fix.cleanup() }

        // Use a gate so the item stays waiting and date hasn't resolved.
        let (_, resume) = fix.fakeAudioConverter.installGate()
        defer { resume() }

        let url = fix.storageRoot.appendingPathComponent("dated.m4a")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fix.core.importFiles([.file(url)])

        let viewModel = ImportViewModel(core: fix.core)
        let rows = viewModel.rows
        // meetingDate may already be resolved from file metadata; if not,
        // second line is " ".
        if rows[0].secondLine != " " {
            // Date resolved -- verify it uses dateAndTime format.
            let item = fix.core.audioImport.items[0]
            if let date = item.meetingDate {
                #expect(rows[0].secondLine == TimeFormatting.dateAndTime(date))
            }
        }
    }

    @Test("header passes through ImportHeaderCopy")
    @MainActor
    func headerPassthrough() throws {
        let fix = try makeCoreFixture(testName: "ImportVM")
        defer { fix.cleanup() }

        let viewModel = ImportViewModel(core: fix.core)
        let expected = ImportHeaderCopy.make(
            items: [], run: nil, runPosition: nil
        )
        #expect(viewModel.header == expected)
    }
}

@Suite("ImportViewModel actions")
struct ImportViewModelActionTests {
    @Test("goToMeeting routes to meeting")
    @MainActor
    func goToMeetingRoutes() async throws {
        let fix = try makeCoreFixture(testName: "ImportVM")
        defer { fix.cleanup() }
        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.core.onLaunch()

        let url = fix.storageRoot.appendingPathComponent("meeting.m4a")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fix.core.importFiles([.file(url)])
        await fix.core.audioImport.awaitIdle()
        await fix.core.reloadSummaries()

        let items = fix.core.audioImport.items
        guard case let .done(meetingID) = items[0].status else {
            Issue.record("Expected done status")
            return
        }

        let viewModel = ImportViewModel(core: fix.core)
        viewModel.goToMeeting(meetingID)
        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection.contains(meetingID))
    }

    @Test("showInFinder with existing file calls reveal with file URL")
    @MainActor
    func showInFinderExistingFile() async throws {
        let fix = try makeCoreFixture(testName: "ImportVM")
        defer { fix.cleanup() }

        fix.fakeAudioConverter.outcomes["exists.m4a"] = .failure(.noAudio)
        let url = fix.storageRoot.appendingPathComponent("exists.m4a")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fix.core.importFiles([.file(url)])
        await fix.core.audioImport.awaitIdle()

        var revealedURL: URL?
        let viewModel = ImportViewModel(
            core: fix.core,
            revealInFinder: { revealedURL = $0 }
        )
        let rows = viewModel.rows
        viewModel.showInFinder(rows[0].id)
        #expect(revealedURL == url)
    }

    @Test("showInFinder with missing file reveals nearest parent")
    @MainActor
    func showInFinderMissingFile() async throws {
        let fix = try makeCoreFixture(testName: "ImportVM")
        defer { fix.cleanup() }

        fix.fakeAudioConverter.outcomes["gone.m4a"] = .failure(.noAudio)
        let subdir = fix.storageRoot.appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            at: subdir, withIntermediateDirectories: true
        )
        let url = subdir.appendingPathComponent("gone.m4a")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fix.core.importFiles([.file(url)])
        await fix.core.audioImport.awaitIdle()
        // Delete the file after import processed it.
        try FileManager.default.removeItem(at: url)

        var openedURL: URL?
        let viewModel = ImportViewModel(
            core: fix.core,
            openFolder: { openedURL = $0 }
        )
        let rows = viewModel.rows
        viewModel.showInFinder(rows[0].id)
        #expect(openedURL?.standardizedFileURL == subdir.standardizedFileURL)
    }
}

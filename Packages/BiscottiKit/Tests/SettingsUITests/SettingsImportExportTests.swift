import AppCore
import BiscottiTestSupport
import Foundation
import ImportExport
import Testing
@testable import DataStore
@testable import SettingsUI

/// Records panel invocations, stubs a chosen result, and samples the
/// view model's state at the moment each panel is on screen — which is
/// the only observable window into the in-flight busy/spinner flags.
@MainActor
private final class PanelSpy {
    var openPanelResult: URL?
    var savePanelResult: URL?
    private(set) var openPanelCount = 0
    private(set) var savePanelNames: [String] = []
    private(set) var busyWhenSaveShown: [Bool] = []
    private(set) var exportSpinnerWhenSaveShown: [Bool] = []
    weak var viewModel: SettingsViewModel?

    func presentOpen() -> URL? {
        openPanelCount += 1
        return openPanelResult
    }

    func presentSave(name: String) -> URL? {
        savePanelNames.append(name)
        busyWhenSaveShown.append(viewModel?.importExportBusy ?? false)
        exportSpinnerWhenSaveShown.append(viewModel?.exportInFlight ?? true)
        return savePanelResult
    }
}

// Serialized: the export tests share the temp directory and a
// second-granularity filename, so one test's cancel-path delete must
// never land inside another's export-to-move window.
@Suite("SettingsViewModel -- Import/Export", .serialized)
@MainActor
struct SettingsImportExportTests {
    // MARK: - Import flow

    @Test("cancelling the open panel does nothing")
    func openPanelCancelIsNoOp() async throws {
        let fix = try makeCoreFixture(testName: "IOCancel")
        defer { fix.cleanup() }

        let spy = PanelSpy()
        spy.openPanelResult = nil
        let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: spy)

        await viewModel.beginImport()

        #expect(spy.openPanelCount == 1)
        #expect(viewModel.importAlert == nil)
        #expect(viewModel.pendingImport == nil)
        #expect(!viewModel.importExportBusy)
        #expect(!viewModel.importInFlight)
        #expect(try await fix.store.meetingSummaries().isEmpty)
    }

    @Test("critical errors present .blocked and commit nothing")
    func criticalErrorsBlock() async throws {
        let fix = try makeCoreFixture(testName: "IOBlocked")
        defer { fix.cleanup() }

        let spy = PanelSpy()
        spy.openPanelResult = try ImportExportTestSupport.writeCSV("id,title\nabc-1,Standup")
        let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: spy)

        await viewModel.beginImport()

        guard case let .blocked(title, body) = viewModel.importAlert else {
            Issue.record("expected .blocked, got \(String(describing: viewModel.importAlert))")
            return
        }
        #expect(title == "Cannot Import This File")
        #expect(body == "Required columns are missing: created.")
        #expect(viewModel.pendingImport == nil)
        #expect(try await fix.store.meetingSummaries().isEmpty)
    }

    @Test("warnings present .review; Cancel keeps the store untouched, Continue commits")
    func warningsReviewCancelContinue() async throws {
        let fix = try makeCoreFixture(testName: "IOReview")
        defer { fix.cleanup() }

        let existingID = try await fix.store.createMeeting(title: "Existing")
        let csv = "id,title,created\n"
            + "\(existingID.uuidString),Existing,2026-01-03T14:26:42Z\n"
            + "abc-new,Fresh,2026-01-04T09:00:00Z\n"

        let spy = PanelSpy()
        let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: spy)

        // First pass: review appears, Cancel leaves the store untouched.
        spy.openPanelResult = try ImportExportTestSupport.writeCSV(csv)
        await viewModel.beginImport()
        guard case .review = viewModel.importAlert else {
            Issue.record("expected .review, got \(String(describing: viewModel.importAlert))")
            return
        }
        #expect(viewModel.pendingImport?.drafts.count == 1)
        viewModel.cancelImportReview()
        #expect(viewModel.importAlert == nil)
        #expect(try await fix.store.meetingSummaries().count == 1)

        // Second pass: Continue commits exactly the held scan result.
        spy.openPanelResult = try ImportExportTestSupport.writeCSV(csv)
        await viewModel.beginImport()
        guard case .review = viewModel.importAlert else {
            Issue.record("expected .review again, got \(String(describing: viewModel.importAlert))")
            return
        }
        await viewModel.confirmImport()

        guard case let .result(title, body) = viewModel.importAlert else {
            Issue.record("expected .result, got \(String(describing: viewModel.importAlert))")
            return
        }
        #expect(title == "Import Complete")
        #expect(body == """
        Imported 1 meeting.
        1 row was skipped because those meetings already exist.
        """)
        #expect(try await fix.store.meetingSummaries().count == 2)
        #expect(fix.core.summaries.count == 2)
    }

    @Test("clean file commits straight through with no review alert")
    func cleanFileCommitsDirectly() async throws {
        let fix = try makeCoreFixture(testName: "IOClean")
        defer { fix.cleanup() }

        let spy = PanelSpy()
        spy.openPanelResult = try ImportExportTestSupport.writeCSV(
            "id,title,created,summary\nabc-1,Standup,2026-01-03T14:26:42Z,Hello"
        )
        let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: spy)

        await viewModel.beginImport()

        guard case let .result(_, body) = viewModel.importAlert else {
            Issue.record("expected .result, got \(String(describing: viewModel.importAlert))")
            return
        }
        #expect(body == "Imported 1 meeting.")
        #expect(viewModel.pendingImport == nil)
        #expect(try await fix.store.meetingSummaries().count == 1)
    }

    @Test("header-only CSV reports 'Imported 0 meetings.' and writes nothing")
    func headerOnlyCommitsZero() async throws {
        let fix = try makeCoreFixture(testName: "IOHeaderOnly")
        defer { fix.cleanup() }

        // The carried-in Phase 3 state: canProceed == false,
        // needsReview == false, drafts.isEmpty. The wiring must land it
        // deliberately in the clean path — zero meetings committed, the
        // §3.4 result alert shown, and no review alert on the way.
        let spy = PanelSpy()
        spy.openPanelResult = try ImportExportTestSupport.writeCSV(
            "id,title,created,summary,notes,transcript"
        )
        let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: spy)

        await viewModel.beginImport()

        guard case let .result(title, body) = viewModel.importAlert else {
            Issue.record("expected .result, got \(String(describing: viewModel.importAlert))")
            return
        }
        #expect(title == "Import Complete")
        #expect(body == "Imported 0 meetings.")
        #expect(try await fix.store.meetingSummaries().isEmpty)
        #expect(!viewModel.importExportBusy)
    }

    // MARK: - Export flow

    @Test("export moves the temp file to the chosen destination")
    func exportMovesFile() async throws {
        let fix = try makeCoreFixture(testName: "IOExportMove")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "One")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dest-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: destination) }

        let spy = PanelSpy()
        spy.savePanelResult = destination
        let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: spy)

        await viewModel.beginExport()

        // The save panel received the generated filename, was shown while
        // the operation was busy (both buttons disabled) and after the
        // spinner had cleared (functional spec §5.2).
        #expect(spy.savePanelNames.count == 1)
        #expect(spy.savePanelNames[0].hasPrefix("Biscotti_export_"))
        #expect(spy.savePanelNames[0].hasSuffix(".csv"))
        #expect(spy.busyWhenSaveShown == [true])
        #expect(spy.exportSpinnerWhenSaveShown == [false])

        #expect(FileManager.default.fileExists(atPath: destination.path()))
        #expect(viewModel.importAlert == nil)
        #expect(!viewModel.importExportBusy)
        #expect(!viewModel.exportInFlight)
    }

    @Test("export over an existing destination replaces it")
    func exportReplacesExistingDestination() async throws {
        let fix = try makeCoreFixture(testName: "IOExportReplace")
        defer { fix.cleanup() }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("replace-\(UUID().uuidString).csv")
        try Data("old contents".utf8).write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }

        let spy = PanelSpy()
        spy.savePanelResult = destination
        let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: spy)

        await viewModel.beginExport()

        // The old file is replaced by the CSV, not left behind or lost.
        let saved = try String(contentsOf: destination, encoding: .utf8)
        #expect(saved.hasPrefix("id,title,created,summary,notes,transcript\r\n"))
        #expect(viewModel.importAlert == nil)
        guard let fileName = spy.savePanelNames.first else {
            Issue.record("save panel was never shown")
            return
        }
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
        #expect(!FileManager.default.fileExists(atPath: tempFile.path()))
    }

    @Test("cancelling the save panel deletes the temp file and shows no alert")
    func exportCancelDeletesTemp() async throws {
        let fix = try makeCoreFixture(testName: "IOExportCancel")
        defer { fix.cleanup() }

        let spy = PanelSpy()
        spy.savePanelResult = nil
        let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: spy)

        await viewModel.beginExport()

        // Exactly one export file existed; the cancel path must have
        // removed it.
        guard let fileName = spy.savePanelNames.first else {
            Issue.record("save panel was never shown")
            return
        }
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
        #expect(!FileManager.default.fileExists(atPath: tempFile.path()))
        #expect(viewModel.importAlert == nil)
        #expect(!viewModel.importExportBusy)
    }

    @Test("a failed move surfaces .failure and deletes the temp file")
    func exportMoveFailureAlerts() async throws {
        let fix = try makeCoreFixture(testName: "IOExportMoveFail")
        defer { fix.cleanup() }

        // A destination whose parent directory does not exist makes the
        // move fail.
        let destination = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/out.csv")
        let spy = PanelSpy()
        spy.savePanelResult = destination
        let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: spy)

        await viewModel.beginExport()

        guard case let .failure(title, _) = viewModel.importAlert else {
            Issue.record("expected .failure, got \(String(describing: viewModel.importAlert))")
            return
        }
        #expect(title == "Export Failed")
        guard let fileName = spy.savePanelNames.first else {
            Issue.record("save panel was never shown")
            return
        }
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
        #expect(!FileManager.default.fileExists(atPath: tempFile.path()))
        #expect(!viewModel.importExportBusy)
    }

    // MARK: - Alert copy

    @Test("resultBody lists skipped rows per spec wording")
    func resultBodyCopy() {
        let single = SettingsViewModel.resultBody(
            for: ImportCommitSummary(imported: 1, skippedExisting: 0, skippedMisformatted: 0)
        )
        #expect(single == "Imported 1 meeting.")

        let full = SettingsViewModel.resultBody(
            for: ImportCommitSummary(imported: 42, skippedExisting: 3, skippedMisformatted: 2)
        )
        #expect(full == """
        Imported 42 meetings.
        3 rows were skipped because those meetings already exist.
        2 rows were skipped because they were missing a required value.
        """)
    }

    // MARK: - Helpers
}

#if DEBUG
    @Suite("SettingsViewModel -- Debug: Delete Imported Meetings")
    @MainActor
    struct SettingsDebugDeleteImportedTests {
        @Test("delete prompt uses the exact N/M copy")
        func deletePromptCopy() async throws {
            let fix = try makeCoreFixture(testName: "IODeletePrompt")
            defer { fix.cleanup() }

            _ = try await fix.store.createMeeting(title: "Recorded")
            try await fix.store.insertImportedMeetings(
                [ImportExportTestSupport.draft(title: "A"), ImportExportTestSupport.draft(title: "B")],
                batchID: 1
            )

            let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: PanelSpy())
            await viewModel.promptDeleteImportedMeetings()

            #expect(
                viewModel.importAlert
                    == .confirmDeleteImported(
                        title: "Delete 2 meetings?",
                        body: "This will delete 2 meetings (and leave 1 meetings)."
                    )
            )
        }

        @Test("zero imported meetings shows the none-to-delete result")
        func deletePromptZero() async throws {
            let fix = try makeCoreFixture(testName: "IODeleteZero")
            defer { fix.cleanup() }

            let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: PanelSpy())
            await viewModel.promptDeleteImportedMeetings()

            #expect(
                viewModel.importAlert
                    == .result(
                        title: "Delete Imported Meetings",
                        body: "No imported meetings to delete."
                    )
            )
            #expect(try await fix.store.meetingSummaries().isEmpty)
        }

        @Test("cancel from the delete confirmation performs no delete")
        func deleteCancelPerformsNoDelete() async throws {
            let fix = try makeCoreFixture(testName: "IODeleteCancel")
            defer { fix.cleanup() }

            try await fix.store.insertImportedMeetings(
                [ImportExportTestSupport.draft(title: "A")],
                batchID: 1
            )
            await fix.core.reloadSummaries()

            let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: PanelSpy())
            await viewModel.promptDeleteImportedMeetings()
            guard case .confirmDeleteImported = viewModel.importAlert else {
                Issue.record(
                    "expected .confirmDeleteImported, got \(String(describing: viewModel.importAlert))"
                )
                return
            }

            // The Cancel button's action.
            viewModel.dismissImportAlert()

            #expect(viewModel.importAlert == nil)
            #expect(fix.core.summaries.count == 1)
            let counts = await fix.core.importedMeetingCounts()
            #expect(counts.imported == 1)
        }

        @Test("confirming the delete removes imported meetings and reports the count")
        func deleteConfirmRemoves() async throws {
            let fix = try makeCoreFixture(testName: "IODeleteConfirm")
            defer { fix.cleanup() }

            let recordedID = try await fix.store.createMeeting(title: "Recorded")
            try await fix.store.insertImportedMeetings(
                [ImportExportTestSupport.draft(title: "A")],
                batchID: 1
            )
            await fix.core.reloadSummaries()

            let viewModel = ImportExportTestSupport.makeViewModel(fix: fix, spy: PanelSpy())
            await viewModel.confirmDeleteImportedMeetings()

            #expect(
                viewModel.importAlert
                    == .result(
                        title: "Delete Imported Meetings",
                        body: "Deleted 1 meeting."
                    )
            )
            #expect(fix.core.summaries.count == 1)
            #expect(try await fix.store.meetingExists(id: recordedID))
        }
    }
#endif

// MARK: - Shared helpers

private enum ImportExportTestSupport {
    @MainActor
    static func makeViewModel(
        fix: CoreFixture, spy: PanelSpy
    ) -> SettingsViewModel {
        let viewModel = SettingsViewModel(
            core: fix.core,
            presentOpenPanel: { spy.presentOpen() },
            presentSavePanel: { name in spy.presentSave(name: name) }
        )
        spy.viewModel = viewModel
        return viewModel
    }

    static func writeCSV(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("io-\(UUID().uuidString).csv")
        try Data(text.utf8).write(to: url)
        return url
    }

    static func draft(title: String) -> ImportedMeetingDraft {
        ImportedMeetingDraft(
            meetingID: UUID(),
            title: title,
            created: Date(timeIntervalSince1970: 1_767_000_000)
        )
    }
}

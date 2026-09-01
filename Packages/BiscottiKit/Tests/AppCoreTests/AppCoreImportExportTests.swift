import AppCore
import BiscottiTestSupport
import Foundation
import ImportExport
import Testing
@testable import DataStore

@Suite("AppCore -- CSV import/export")
@MainActor
struct AppCoreImportExportTests {
    // MARK: - Scan

    @Test("scanMeetingImport returns drafts for a clean file")
    func scanCleanFile() async throws {
        let fix = try makeCoreFixture(testName: "CSVScanClean")
        defer { fix.cleanup() }

        let url = try Self.writeCSV(
            "id,title,created,summary\nabc-1,Standup,2026-01-03T14:26:42Z,Hello"
        )
        let result = await fix.core.scanMeetingImport(at: url)

        #expect(result.criticalErrors.isEmpty)
        #expect(result.warnings.isEmpty)
        #expect(result.drafts.count == 1)
        #expect(result.drafts.first?.externalID == "abc-1")
        #expect(result.drafts.first?.title == "Standup")
    }

    @Test("scanMeetingImport on an unreadable path reports .unreadableFile")
    func scanUnreadableFile() async throws {
        let fix = try makeCoreFixture(testName: "CSVScanUnreadable")
        defer { fix.cleanup() }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).csv")
        let result = await fix.core.scanMeetingImport(at: missing)

        #expect(result.drafts.isEmpty)
        guard case .unreadableFile = result.criticalErrors.first else {
            Issue.record(
                "expected .unreadableFile, got \(result.criticalErrors)"
            )
            return
        }
    }

    // MARK: - Commit

    @Test("commitMeetingImport inserts the drafts and reloads summaries")
    func commitInsertsAndReloads() async throws {
        let fix = try makeCoreFixture(testName: "CSVCommit")
        defer { fix.cleanup() }

        let url = try Self.writeCSV(
            "id,title,created\n"
                + "abc-1,Standup,2026-01-03T14:26:42Z\n"
                + "abc-2,Retro,2026-01-04T09:00:00Z\n"
        )
        let result = await fix.core.scanMeetingImport(at: url)
        let summary = try await fix.core.commitMeetingImport(result)

        #expect(summary.imported == 2)
        #expect(summary.skippedExisting == 0)
        #expect(summary.skippedMisformatted == 0)
        #expect(fix.core.summaries.count == 2)
        // The batch stamp is what the debug delete (and a future
        // un-import) keys on. Read on-actor: the @Model is not Sendable.
        let stampedID = result.drafts[0].meetingID
        let stamped = try await fix.store.read { store in
            try store.meeting(id: stampedID)?.importBatch != nil
        }
        #expect(stamped)
    }

    @Test("header-only CSV commits zero meetings and leaves the store untouched")
    func commitHeaderOnly() async throws {
        let fix = try makeCoreFixture(testName: "CSVCommitHeaderOnly")
        defer { fix.cleanup() }

        // The carried-in Phase 3 state: valid header, zero data rows
        // scans to no errors, no warnings, no drafts — and canProceed
        // is false only because there is nothing to insert. The commit
        // must handle it deliberately: zero imported, no store writes.
        let url = try Self.writeCSV("id,title,created,summary,notes,transcript")
        let result = await fix.core.scanMeetingImport(at: url)
        #expect(result.criticalErrors.isEmpty)
        #expect(result.warnings.isEmpty)
        #expect(result.drafts.isEmpty)
        #expect(result.canProceed == false)
        #expect(result.needsReview == false)

        let summary = try await fix.core.commitMeetingImport(result)
        #expect(summary.imported == 0)
        #expect(try await fix.store.meetingSummaries().isEmpty)
        #expect(fix.core.summaries.isEmpty)
    }

    @Test("commit derives skip counts from the scan's warnings")
    func commitDerivesSkipCounts() async throws {
        let fix = try makeCoreFixture(testName: "CSVCommitSkips")
        defer { fix.cleanup() }

        let existingID = try await fix.store.createMeeting(title: "Existing")
        let url = try Self.writeCSV(
            "id,title,created\n"
                + "\(existingID.uuidString),Existing,2026-01-03T14:26:42Z\n"
                + "abc-new,Fresh,2026-01-04T09:00:00Z\n"
                + ",No ID,2026-01-05T09:00:00Z\n"
        )
        let result = await fix.core.scanMeetingImport(at: url)
        let summary = try await fix.core.commitMeetingImport(result)

        #expect(summary.imported == 1)
        #expect(summary.skippedExisting == 1)
        #expect(summary.skippedMisformatted == 1)
        #expect(fix.core.summaries.count == 2)
    }

    // MARK: - Export

    @Test("exportMeetingsCSV writes the canonical header to a temp file")
    func exportWritesHeader() async throws {
        let fix = try makeCoreFixture(testName: "CSVExport")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "One")

        // The export filename has second granularity and the temp
        // directory is shared with the concurrently running SettingsUI
        // export tests, whose cancel paths delete their temp file by
        // that same name. Export just past a fresh second boundary and
        // retry once if a sibling still raced the same second.
        var exported: URL?
        for _ in 0 ..< 3 {
            try await Self.sleepPastSecondBoundary()
            let candidate = try await fix.core.exportMeetingsCSV()
            if FileManager.default.fileExists(atPath: candidate.path()) {
                exported = candidate
                break
            }
        }
        guard let url = exported else {
            Issue.record("the export file never appeared in the temp directory")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.lastPathComponent.hasPrefix("Biscotti_export_"))
        #expect(url.lastPathComponent.hasSuffix(".csv"))

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("id,title,created,summary,notes,transcript\r\n"))
        #expect(text.components(separatedBy: .newlines).count >= 2)
    }

    // MARK: - Debug bulk delete

    #if DEBUG
        @Test("importedMeetingCounts splits imported from remaining")
        func countsSplitImportedAndRemaining() async throws {
            let fix = try makeCoreFixture(testName: "CSVDebugCounts")
            defer { fix.cleanup() }

            _ = try await fix.store.createMeeting(title: "Recorded")
            try await fix.store.insertImportedMeetings(
                [Self.draft(title: "Imported 1"), Self.draft(title: "Imported 2")],
                batchID: 1
            )

            let counts = await fix.core.importedMeetingCounts()
            #expect(counts.imported == 2)
            #expect(counts.remaining == 1)
        }

        @Test("deleteImportedMeetings removes only imported meetings and reloads")
        func deleteRemovesOnlyImported() async throws {
            let fix = try makeCoreFixture(testName: "CSVDebugDelete")
            defer { fix.cleanup() }

            let recordedID = try await fix.store.createMeeting(title: "Recorded")
            try await fix.store.insertImportedMeetings(
                [Self.draft(title: "Imported")],
                batchID: 1
            )
            await fix.core.reloadSummaries()
            #expect(fix.core.summaries.count == 2)

            let deleted = try await fix.core.deleteImportedMeetings()
            #expect(deleted == 1)
            #expect(fix.core.summaries.count == 1)
            #expect(try await fix.store.meetingExists(id: recordedID))
        }
    #endif

    // MARK: - Helpers

    /// Sleeps until just past the next whole-second boundary, so a
    /// second-granularity export filename is unique to this call.
    private static func sleepPastSecondBoundary() async throws {
        let fraction = Date().timeIntervalSince1970
            .truncatingRemainder(dividingBy: 1)
        try await Task.sleep(for: .seconds((1 - fraction) + 0.02))
    }

    private static func writeCSV(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-\(UUID().uuidString).csv")
        try Data(text.utf8).write(to: url)
        return url
    }

    private static func draft(title: String) -> ImportedMeetingDraft {
        ImportedMeetingDraft(
            meetingID: UUID(),
            title: title,
            created: Date(timeIntervalSince1970: 1_767_000_000)
        )
    }
}

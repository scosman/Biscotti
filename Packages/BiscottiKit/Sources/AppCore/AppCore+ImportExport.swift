import DataStore
import Foundation
import ImportExport
import os

/// What a committed import actually did (architecture §5). The skip
/// counts are derived from the scan's warnings — the commit itself never
/// re-reads the file.
public struct ImportCommitSummary: Sendable, Equatable {
    public let imported: Int
    public let skippedExisting: Int
    public let skippedMisformatted: Int

    public init(
        imported: Int,
        skippedExisting: Int,
        skippedMisformatted: Int
    ) {
        self.imported = imported
        self.skippedExisting = skippedExisting
        self.skippedMisformatted = skippedMisformatted
    }
}

// MARK: - CSV import/export actions (architecture §5)

public extension AppCore {
    /// Scans a CSV file for import without writing anything (functional
    /// spec §2.1). The heavy parsing runs in a detached task so a large
    /// file never blocks the main actor.
    func scanMeetingImport(at url: URL) async -> ImportScanResult {
        // A failed identity fetch degrades to no duplicate detection.
        // That is acceptable because the same broken store makes the
        // subsequent commit throw, so no data can be silently duplicated —
        // but the failure is logged so "store broken" is distinguishable
        // from "no duplicates" in the field (architecture §8).
        let existing: ExistingMeetingIdentity
        do {
            existing = try await store.existingMeetingIdentity()
        } catch {
            importExportActionLog.error(
                "identity fetch failed; scanning without duplicate detection: \(String(describing: error), privacy: .public)"
            )
            existing = ExistingMeetingIdentity()
        }

        return await Task.detached(priority: .userInitiated) {
            MeetingCSVImporter.scan(fileURL: url, existing: existing)
        }.value
    }

    /// Inserts the scan's drafts as one import batch, then refreshes the
    /// sidebar. The file is never re-read or re-validated — exactly what
    /// the scan produced is what lands in the store.
    func commitMeetingImport(
        _ result: ImportScanResult
    ) async throws -> ImportCommitSummary {
        let skippedExisting = Self.skippedExisting(from: result.warnings)
        let skippedMisformatted = Self.skippedMisformatted(from: result.warnings)

        // A header-only file (valid header, zero data rows) scans clean
        // with no drafts — `canProceed == false` only because there is
        // nothing to insert. It is not a failure: per functional spec
        // §3.3/§3.4 it commits zero meetings, so return early without
        // minting a batch or touching the store.
        guard !result.drafts.isEmpty else {
            return ImportCommitSummary(
                imported: 0,
                skippedExisting: skippedExisting,
                skippedMisformatted: skippedMisformatted
            )
        }

        let batchID = try await store.nextImportBatchID()
        let imported = try await store.insertImportedMeetings(
            result.drafts, batchID: batchID
        )
        await reloadSummaries()
        importExportActionLog.info(
            "CSV import committed \(imported) meetings (batch \(batchID))"
        )
        return ImportCommitSummary(
            imported: imported,
            skippedExisting: skippedExisting,
            skippedMisformatted: skippedMisformatted
        )
    }

    /// Streams every meeting to a CSV file in the temporary directory
    /// and returns its URL (functional spec §5.2). The exporter is
    /// stateless, so it is built per call.
    func exportMeetingsCSV() async throws -> URL {
        try await MeetingCSVExporter(store: store).export()
    }
}

private extension AppCore {
    static func skippedExisting(from warnings: [ImportWarning]) -> Int {
        warnings.reduce(0) { total, warning in
            if case let .alreadyInDatabase(count) = warning {
                total + count
            } else {
                total
            }
        }
    }

    static func skippedMisformatted(from warnings: [ImportWarning]) -> Int {
        warnings.reduce(0) { total, warning in
            if case let .misformattedRows(count, _) = warning {
                total + count
            } else {
                total
            }
        }
    }
}

/// Counts and row numbers only — never file contents (architecture §8).
private let importExportActionLog = Logger(
    subsystem: "net.scosman.biscotti",
    category: "ImportExport"
)

// MARK: - Debug-build bulk delete (functional spec §6.1)

#if DEBUG
    public extension AppCore {
        /// The imported/remaining meeting split, for the debug delete
        /// confirmation copy. A store failure logs and reports (0, 0)
        /// rather than throwing — but the log keeps the degraded count
        /// from masquerading as a genuine empty state (architecture §8).
        func importedMeetingCounts() async -> (imported: Int, remaining: Int) {
            do {
                return try await store.importedMeetingCounts()
            } catch {
                importExportActionLog.error(
                    "importedMeetingCounts failed: \(String(describing: error), privacy: .public)"
                )
                return (imported: 0, remaining: 0)
            }
        }

        /// Deletes every imported meeting (`importBatch != nil`),
        /// cascading transcripts and search-index entries, then refreshes
        /// the sidebar. Debug builds only.
        @discardableResult
        func deleteImportedMeetings() async throws -> Int {
            let deleted = try await store.deleteImportedMeetings()
            await reloadSummaries()
            importExportActionLog.info(
                "Debug bulk delete removed \(deleted) imported meetings"
            )
            return deleted
        }
    }
#endif

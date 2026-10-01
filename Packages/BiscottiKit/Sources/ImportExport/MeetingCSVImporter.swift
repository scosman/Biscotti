import DataStore
import Formatting
import Foundation

/// Scans a CSV file into importable meeting drafts (functional spec §2.1).
/// Pure and store-free — the caller hands in the existing identity rather
/// than a database, so every error and warning case is a plain unit test.
/// The file is read exactly once; a commit inserts exactly what the scan
/// produced.
public enum MeetingCSVImporter {
    /// Scans the CSV file at `fileURL`. Never throws — every failure is a
    /// `criticalError` in the result, so the caller has one code path.
    public static func scan(
        fileURL: URL,
        existing: ExistingMeetingIdentity
    ) -> ImportScanResult {
        do {
            return try scan(data: Data(contentsOf: fileURL), existing: existing)
        } catch {
            importExportLog.error(
                "CSV scan could not read the file: \(error.localizedDescription, privacy: .public)"
            )
            return ImportScanResult(
                criticalErrors: [.unreadableFile(error.localizedDescription)]
            )
        }
    }

    /// Byte-level entry point so tests (and any future non-file source)
    /// share the exact production path.
    static func scan(
        data: Data,
        existing: ExistingMeetingIdentity
    ) -> ImportScanResult {
        guard let text = text(from: data) else {
            importExportLog.error("CSV scan failed: the file is not valid UTF-8")
            return ImportScanResult(criticalErrors: [.notUTF8])
        }

        let rows: [[String]]
        do {
            rows = try CSVParser.parse(text)
        } catch {
            importExportLog.error("CSV scan failed: malformed CSV at row \(error.row)")
            return ImportScanResult(criticalErrors: [.malformedCSV(row: error.row)])
        }
        guard !rows.isEmpty else {
            return ImportScanResult(criticalErrors: [.emptyFile])
        }

        let header = resolveHeader(rows[0])
        if !header.missingColumns.isEmpty {
            importExportLog.error(
                "CSV scan failed: missing columns \(header.missingColumns.joined(separator: ", "), privacy: .public)"
            )
            return ImportScanResult(
                criticalErrors: [.missingColumns(header.missingColumns)]
            )
        }

        let outcome = scanRows(Array(rows.dropFirst()), header: header, existing: existing)
        // `.nothingToImport` requires at least one real data row — the
        // `dataRowCount` a blank line never increments — so a header-only
        // file (with or without trailing blank lines) stays on the clean
        // commit-zero path (functional spec §3.3/§3.4).
        let criticalErrors: [ImportCriticalError] =
            outcome.drafts.isEmpty && outcome.dataRowCount > 0 ? [.nothingToImport] : []

        importExportLog.info(
            "CSV scan: \(outcome.drafts.count) importable rows, \(outcome.misformattedRowNumbers.count) misformatted, \(outcome.alreadyInDatabaseCount) already in database, \(outcome.duplicateRowNumbers.count) duplicate in file"
        )
        return ImportScanResult(
            drafts: outcome.drafts,
            warnings: warnings(from: outcome, ambiguousColumns: header.ambiguousColumns),
            criticalErrors: criticalErrors
        )
    }

    // MARK: - Decoding

    /// Strips a UTF-8 BOM, then decodes. Nil when the bytes are not UTF-8.
    private static func text(from data: Data) -> String? {
        var bytes = data
        if Array(bytes.prefix(3)) == [0xEF, 0xBB, 0xBF] {
            bytes.removeFirst(3)
        }
        return String(data: bytes, encoding: .utf8)
    }

    // MARK: - Header Resolution

    /// Resolves the header per functional spec §1.2: trim + lowercase each
    /// cell, map aliases, keep the first occurrence of each canonical
    /// column, and let the canonical name win over its alias when both are
    /// present (recording the ambiguity).
    private static func resolveHeader(_ headerCells: [String]) -> HeaderResolution {
        let normalized = headerCells.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var canonicalIndex: [String: Int] = [:]
        var aliasIndex: [String: Int] = [:]
        for (index, cell) in normalized.enumerated() {
            if CSVColumns.canonical.contains(cell) {
                if canonicalIndex[cell] == nil { canonicalIndex[cell] = index }
            } else if let canonical = CSVColumns.aliases[cell] {
                if aliasIndex[canonical] == nil { aliasIndex[canonical] = index }
            }
        }

        var columnIndex: [String: Int] = [:]
        var ambiguousColumns: [String] = []
        for column in CSVColumns.canonical {
            if let index = canonicalIndex[column] {
                columnIndex[column] = index
                if aliasIndex[column] != nil { ambiguousColumns.append(column) }
            } else {
                columnIndex[column] = aliasIndex[column]
            }
        }

        return HeaderResolution(
            columnIndex: columnIndex,
            width: headerCells.count,
            ambiguousColumns: ambiguousColumns,
            missingColumns: CSVColumns.required.filter { columnIndex[$0] == nil }
        )
    }

    // MARK: - Row Scan

    private static func scanRows(
        _ rows: [[String]],
        header: HeaderResolution,
        existing: ExistingMeetingIdentity
    ) -> RowScanOutcome {
        var outcome = RowScanOutcome()
        var claims = ClaimTracker()

        for (offset, rawFields) in rows.enumerated() {
            let rowNumber = offset + 2
            // A blank line parses to a single empty field (a line of
            // spaces to a single blank one). It carries no data —
            // dropping it keeps a hand-edited file's stray blank lines
            // (a trailing "\r\n\r\n") from being reported as ragged or
            // misformatted rows.
            if rawFields.count == 1, isBlank(rawFields[0]) { continue }
            outcome.dataRowCount += 1
            var fields = rawFields
            if fields.count != header.width {
                outcome.raggedRowNumbers.append(rowNumber)
                resize(&fields, to: header.width)
            }

            switch scanRow(fields, header: header, existing: existing, claims: &claims) {
            case let .draft(draft):
                if isBlank(draft.summary), isBlank(draft.notes), draft.transcript.isEmpty {
                    outcome.emptyContentCount += 1
                }
                outcome.drafts.append(draft)
            case .misformatted:
                outcome.misformattedRowNumbers.append(rowNumber)
            case .alreadyInDatabase:
                outcome.alreadyInDatabaseCount += 1
            case .duplicateInFile:
                outcome.duplicateRowNumbers.append(rowNumber)
            }
        }
        return outcome
    }

    /// Scans one width-normalized data row (architecture §4.2 steps 4–7).
    private static func scanRow(
        _ fields: [String],
        header: HeaderResolution,
        existing: ExistingMeetingIdentity,
        claims: inout ClaimTracker
    ) -> RowScan {
        func cell(_ column: String) -> String {
            header.columnIndex[column].map { fields[$0] } ?? ""
        }

        let id = cell(CSVColumns.id).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cell(CSVColumns.title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              !title.isEmpty,
              let created = ISO8601Formatting.date(from: cell(CSVColumns.created))
        else {
            return .misformatted
        }

        switch resolveIdentity(for: id, existing: existing, claims: &claims) {
        case .alreadyInDatabase:
            return .alreadyInDatabase
        case .duplicateInFile:
            return .duplicateInFile
        case let .resolved(meetingID, externalID):
            return .draft(
                ImportedMeetingDraft(
                    meetingID: meetingID,
                    externalID: externalID,
                    title: title,
                    created: created,
                    summary: cell(CSVColumns.summary),
                    notes: cell(CSVColumns.notes),
                    transcript: TranscriptTextFormatting.parse(cell(CSVColumns.transcript))
                )
            )
        }
    }

    /// UUID rows match against meeting IDs, non-UUID strings against
    /// external IDs — first against the database, then against earlier
    /// rows in this file (functional spec §2.4).
    private static func resolveIdentity(
        for id: String,
        existing: ExistingMeetingIdentity,
        claims: inout ClaimTracker
    ) -> IdentityResolution {
        if let parsed = UUID(uuidString: id) {
            if existing.meetingIDs.contains(parsed) { return .alreadyInDatabase }
            if !claims.meetingIDs.insert(parsed).inserted { return .duplicateInFile }
            return .resolved(parsed, externalID: nil)
        }
        if existing.externalIDs.contains(id) { return .alreadyInDatabase }
        if !claims.externalIDs.insert(id).inserted { return .duplicateInFile }
        return .resolved(UUID(), externalID: id)
    }

    // MARK: - Warnings

    private static func warnings(
        from outcome: RowScanOutcome,
        ambiguousColumns: [String]
    ) -> [ImportWarning] {
        var warnings: [ImportWarning] = []
        if !ambiguousColumns.isEmpty {
            warnings.append(.ambiguousColumns(ambiguousColumns))
        }
        appendRowWarning(
            &warnings,
            rowNumbers: outcome.raggedRowNumbers,
            make: ImportWarning.raggedRows
        )
        appendRowWarning(
            &warnings,
            rowNumbers: outcome.misformattedRowNumbers,
            make: ImportWarning.misformattedRows
        )
        if outcome.alreadyInDatabaseCount > 0 {
            warnings.append(.alreadyInDatabase(count: outcome.alreadyInDatabaseCount))
        }
        appendRowWarning(
            &warnings,
            rowNumbers: outcome.duplicateRowNumbers,
            make: ImportWarning.duplicateInFile
        )
        if outcome.emptyContentCount > 0 {
            warnings.append(.emptyContent(count: outcome.emptyContentCount))
        }
        return warnings
    }

    private static func appendRowWarning(
        _ warnings: inout [ImportWarning],
        rowNumbers: [Int],
        make: (Int, [Int]) -> ImportWarning
    ) {
        guard !rowNumbers.isEmpty else { return }
        warnings.append(
            make(rowNumbers.count, Array(rowNumbers.prefix(maxExamples)))
        )
    }

    // MARK: - Helpers

    /// Pads a short row with empty values, drops a long row's extras —
    /// the caller has already counted the row as ragged (functional spec
    /// §3.2).
    private static func resize(_ fields: inout [String], to width: Int) {
        if fields.count < width {
            fields.append(contentsOf: Array(repeating: "", count: width - fields.count))
        } else {
            fields.removeLast(fields.count - width)
        }
    }

    /// Example row numbers are capped at 5 (functional spec §3.3).
    private static let maxExamples = 5

    private static func isBlank(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Resolved header: canonical column name → index into the raw header
/// cells, the raw width (ragged-row baseline), and the two warning/error
/// payloads header resolution can produce.
private struct HeaderResolution {
    let columnIndex: [String: Int]
    let width: Int
    let ambiguousColumns: [String]
    let missingColumns: [String]
}

/// Tallies from the single pass over the data rows.
private struct RowScanOutcome {
    var drafts: [ImportedMeetingDraft] = []
    /// Data rows that survived the blank-line skip — the denominator
    /// for the `.nothingToImport` gate.
    var dataRowCount = 0
    var raggedRowNumbers: [Int] = []
    var misformattedRowNumbers: [Int] = []
    var alreadyInDatabaseCount = 0
    var duplicateRowNumbers: [Int] = []
    var emptyContentCount = 0
}

/// First-wins identity claims for IDs earlier rows in this file took.
private struct ClaimTracker {
    var meetingIDs = Set<UUID>()
    var externalIDs = Set<String>()
}

private enum IdentityResolution {
    /// A usable identity: the parsed UUID (or a minted one) plus the
    /// raw string to store as `externalID` when it was not a UUID.
    case resolved(UUID, externalID: String?)
    case alreadyInDatabase
    case duplicateInFile
}

private enum RowScan {
    case draft(ImportedMeetingDraft)
    case misformatted
    case alreadyInDatabase
    case duplicateInFile
}

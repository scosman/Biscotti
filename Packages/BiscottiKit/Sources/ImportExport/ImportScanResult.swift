import DataStore
import Foundation

/// The outcome of `MeetingCSVImporter.scan` (architecture §4.2): the
/// importable drafts plus everything the review alert needs. Commit
/// inserts exactly `drafts` — the file is never re-read or re-validated.
public struct ImportScanResult: Sendable, Equatable {
    /// Importable rows only, in file order. Misformatted and duplicate
    /// rows were excluded during the scan.
    public let drafts: [ImportedMeetingDraft]
    public let warnings: [ImportWarning]
    public let criticalErrors: [ImportCriticalError]

    public init(
        drafts: [ImportedMeetingDraft] = [],
        warnings: [ImportWarning] = [],
        criticalErrors: [ImportCriticalError] = []
    ) {
        self.drafts = drafts
        self.warnings = warnings
        self.criticalErrors = criticalErrors
    }

    /// True when the import may commit: no critical errors and at least
    /// one importable draft.
    public var canProceed: Bool {
        criticalErrors.isEmpty && !drafts.isEmpty
    }

    /// True when the review alert must be shown before committing
    /// (functional spec §3.3).
    public var needsReview: Bool {
        !warnings.isEmpty || !criticalErrors.isEmpty
    }
}

/// A file-level problem that blocks the whole import (functional spec
/// §3.1). A problem with an individual row never does — that is an
/// `ImportWarning`.
public enum ImportCriticalError: Sendable, Equatable {
    /// The file could not be read; the payload is the underlying error's
    /// description.
    case unreadableFile(String)
    case notUTF8
    case emptyFile
    /// Canonical names of the required columns the header lacks, in
    /// canonical order.
    case missingColumns([String])
    /// Structurally malformed CSV; `row` is 1-based counting the header as
    /// row 1.
    case malformedCSV(row: Int)
    case nothingToImport

    /// The alert copy for this problem.
    public var message: String {
        switch self {
        case let .unreadableFile(reason):
            "The file could not be read: \(reason)"
        case .notUTF8:
            "The file is not valid UTF-8 text."
        case .emptyFile:
            "The file is empty."
        case let .missingColumns(columns):
            "Required columns are missing: \(columns.joined(separator: ", "))."
        case let .malformedCSV(row):
            "The file is not valid CSV (unterminated quoted field at row \(row))."
        case .nothingToImport:
            "No meetings in this file can be imported."
        }
    }
}

/// A recoverable problem (functional spec §3.2): rows skipped or caveats
/// recorded, but the import can proceed after review. Row numbers are
/// 1-based counting the header as row 1, matching what a spreadsheet
/// shows; example lists are capped at 5.
public enum ImportWarning: Sendable, Equatable {
    /// Rows with a blank `id`, a blank `title`, or a missing/unparseable
    /// `created`. Skipped.
    case misformattedRows(count: Int, exampleRows: [Int])
    /// Rows whose summary, notes, and transcript are all blank. Imported.
    case emptyContent(count: Int)
    /// Rows whose meeting already exists in the database. Skipped.
    case alreadyInDatabase(count: Int)
    /// Rows whose ID an earlier row in the same file claimed. Skipped —
    /// the first occurrence wins.
    case duplicateInFile(count: Int, exampleRows: [Int])
    /// Rows with a different field count than the header: short rows were
    /// padded with empty values, long rows dropped their extra fields.
    case raggedRows(count: Int, exampleRows: [Int])
    /// Canonical names where both the canonical column and its alias were
    /// present; the canonical column is used.
    case ambiguousColumns([String])

    /// The alert copy for this warning.
    public var message: String {
        switch self {
        case let .misformattedRows(count, exampleRows):
            "\(count) \(rowNoun(count)) \(rowVerb(count)) missing a required value "
                + "and will be skipped\(examples(exampleRows))."
        case let .emptyContent(count):
            "\(count) \(rowNoun(count)) \(hasVerb(count)) no summary, notes, or transcript."
        case let .alreadyInDatabase(count):
            count == 1
                ? "1 meeting already exists in your database, it will be skipped."
                : "\(count) meetings already exist in your database, these will be skipped."
        case let .duplicateInFile(count, exampleRows):
            "\(count) \(rowNoun(count)) \(hasVerb(count)) the same ID as an earlier "
                + "row; the first occurrence wins\(examples(exampleRows))."
        case let .raggedRows(count, exampleRows):
            "\(count) \(rowNoun(count)) \(hasVerb(count)) a different number of "
                + "fields than the header\(examples(exampleRows))."
        case let .ambiguousColumns(columns):
            columns.compactMap { column -> String? in
                guard let alias = CSVColumns.alias(for: column) else { return nil }
                return "Columns '\(column)' and '\(alias)' are both present; '\(column)' is used."
            }
            .joined(separator: " ")
        }
    }

    private func rowNoun(_ count: Int) -> String {
        count == 1 ? "row" : "rows"
    }

    private func rowVerb(_ count: Int) -> String {
        count == 1 ? "is" : "are"
    }

    private func hasVerb(_ count: Int) -> String {
        count == 1 ? "has" : "have"
    }

    private func examples(_ rows: [Int]) -> String {
        guard !rows.isEmpty else { return "" }
        let list = rows.map(String.init).joined(separator: ", ")
        return rows.count == 1 ? " (row \(list))" : " (rows \(list))"
    }
}

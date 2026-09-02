import DataStore
import Formatting
import Foundation
import Testing
@testable import ImportExport

// MARK: - Shared Helpers

private let canonicalHeader = "id,title,created,summary,notes,transcript"

private func scanCSV(
    _ csv: String,
    existing: ExistingMeetingIdentity = ExistingMeetingIdentity()
) -> ImportScanResult {
    MeetingCSVImporter.scan(data: Data(csv.utf8), existing: existing)
}

private func scanBytes(
    _ bytes: [UInt8],
    existing: ExistingMeetingIdentity = ExistingMeetingIdentity()
) -> ImportScanResult {
    MeetingCSVImporter.scan(data: Data(bytes), existing: existing)
}

private func onlyDraft(
    _ result: ImportScanResult
) throws -> ImportedMeetingDraft {
    #expect(result.drafts.count == 1)
    return try #require(result.drafts.first)
}

// MARK: - Header Resolution & Row Validation

@Suite("MeetingCSVImporter.scan — header and rows")
struct MeetingCSVImporterRowTests {
    @Test("An alias-only CSV imports (document_id/document_title/document_created)")
    func aliasOnlyColumns() throws {
        let result = scanCSV(
            "document_id,document_title,document_created,summary\n"
                + "granola-1,Weekly Sync,2026-01-03T14:26:42Z,Recap"
        )

        #expect(result.criticalErrors.isEmpty)
        #expect(result.warnings.isEmpty)
        #expect(result.canProceed)
        #expect(!result.needsReview)

        let draft = try onlyDraft(result)
        #expect(draft.externalID == "granola-1")
        #expect(draft.title == "Weekly Sync")
        #expect(draft.summary == "Recap")
        #expect(draft.created == ISO8601Formatting.date(from: "2026-01-03T14:26:42Z"))
    }

    @Test("Unknown columns are ignored; header matching is case- and whitespace-lenient")
    func unknownColumnsIgnored() throws {
        let result = scanCSV(
            "extra1, ID ,Title,Created,extra2,Summary,Notes,Transcript\n"
                + "x,\(UUID()),Standup,2026-01-03,ignored,Recap,Note,"
        )

        #expect(result.warnings.isEmpty)
        #expect(result.criticalErrors.isEmpty)

        let draft = try onlyDraft(result)
        #expect(draft.title == "Standup")
        #expect(draft.summary == "Recap")
        #expect(draft.notes == "Note")
        #expect(draft.transcript.isEmpty)
    }

    @Test("A missing required column blocks with missingColumns in canonical order")
    func missingColumns() {
        let missingCreated = scanCSV("id,title,summary\n\(UUID()),T,2026-01-03")
        #expect(missingCreated.criticalErrors == [.missingColumns(["created"])])
        #expect(!missingCreated.canProceed)

        let missingEverything = scanCSV("summary,notes\na,b")
        #expect(
            missingEverything.criticalErrors
                == [.missingColumns(["id", "title", "created"])]
        )
    }

    @Test("Both a canonical column and its alias present warns and the canonical wins")
    func ambiguousColumns() throws {
        let canonicalID = UUID()
        let result = scanCSV(
            "document_id,id,title,created\n"
                + "alias-value,\(canonicalID),T,2026-01-03"
        )

        #expect(result.warnings == [.ambiguousColumns(["id"]), .emptyContent(count: 1)])

        let draft = try onlyDraft(result)
        #expect(draft.meetingID == canonicalID)
        #expect(draft.externalID == nil)
    }

    @Test("Rows with a blank id, blank title, or unparseable date are skipped with row numbers")
    func misformattedRows() throws {
        let goodID = UUID()
        let result = scanCSV(
            canonicalHeader + "\n"
                + ",No ID,2026-01-03,,,\n"
                + "\(UUID()), ,2026-01-03,,,\n"
                + "\(UUID()),No Date,yesterday,,,\n"
                + "\(goodID),Good,2026-01-03,,,"
        )

        #expect(
            result.warnings.contains(
                .misformattedRows(count: 3, exampleRows: [2, 3, 4])
            )
        )
        #expect(result.criticalErrors.isEmpty)

        let draft = try onlyDraft(result)
        #expect(draft.meetingID == goodID)
        #expect(draft.title == "Good")
    }

    @Test("Example row numbers are capped at five")
    func exampleRowsCapped() {
        var csv = canonicalHeader + "\n"
        for _ in 0 ..< 7 {
            csv += "\(UUID()),T,yesterday,,,\n"
        }

        let result = scanCSV(csv)
        #expect(
            result.warnings.contains(
                .misformattedRows(count: 7, exampleRows: [2, 3, 4, 5, 6])
            )
        )
    }

    @Test("A row whose UUID id already exists in the database is skipped")
    func uuidAlreadyInDatabase() {
        let existingID = UUID()
        let result = scanCSV(
            canonicalHeader + "\n\(existingID),T,2026-01-03,,,",
            existing: ExistingMeetingIdentity(meetingIDs: [existingID])
        )

        #expect(result.warnings == [.alreadyInDatabase(count: 1)])
        #expect(result.drafts.isEmpty)
        #expect(result.criticalErrors == [.nothingToImport])
        #expect(!result.canProceed)
    }

    @Test("A row whose non-UUID id already exists as an externalID is skipped")
    func externalIDAlreadyInDatabase() {
        let result = scanCSV(
            canonicalHeader + "\notter-7,T,2026-01-03,,,",
            existing: ExistingMeetingIdentity(externalIDs: ["otter-7"])
        )

        #expect(result.warnings == [.alreadyInDatabase(count: 1)])
        #expect(result.criticalErrors == [.nothingToImport])
    }

    @Test("A non-UUID id gets a minted UUID and the raw string as externalID")
    func nonUUIDIDMinted() throws {
        let result = scanCSV(canonicalHeader + "\ngranola-42,T,2026-01-03,,,")

        let draft = try onlyDraft(result)
        #expect(draft.externalID == "granola-42")
    }

    @Test("A UUID id becomes the meeting ID directly; id and title are trimmed")
    func uuidIDUsedDirectly() throws {
        let id = UUID()
        let result = scanCSV(
            canonicalHeader + "\n \(id.uuidString) ,  Spaced Title  ,2026-01-03,,,"
        )

        // Full-width row: no ragged-row warning rides along.
        #expect(
            !result.warnings.contains {
                if case .raggedRows = $0 { return true }
                return false
            }
        )
        let draft = try onlyDraft(result)
        #expect(draft.meetingID == id)
        #expect(draft.externalID == nil)
        #expect(draft.title == "Spaced Title")
    }

    @Test("A duplicate id within the file skips the later row; the first wins")
    func duplicateInFile() throws {
        let id = UUID()
        let result = scanCSV(
            canonicalHeader + "\n"
                + "\(id),First,2026-01-03,,,\n"
                + "\(id),Second,2026-01-04,,,"
        )

        #expect(
            result.warnings == [
                .duplicateInFile(count: 1, exampleRows: [3]),
                .emptyContent(count: 1)
            ]
        )

        let draft = try onlyDraft(result)
        #expect(draft.title == "First")
    }

    @Test("A row with no summary, notes, or transcript imports with an emptyContent warning")
    func emptyContent() throws {
        let id = UUID()
        let result = scanCSV(canonicalHeader + "\n\(id),T,2026-01-03,,,")

        #expect(result.warnings == [.emptyContent(count: 1)])

        let draft = try onlyDraft(result)
        #expect(draft.meetingID == id)
        #expect(draft.summary.isEmpty)
        #expect(draft.notes.isEmpty)
        #expect(draft.transcript.isEmpty)
    }

    @Test("A quoted transcript field with embedded newlines parses into segments")
    func multilineTranscript() throws {
        let result = scanCSV(
            canonicalHeader + "\n"
                + "\(UUID()),T,2026-01-03,,,\"[0:23] Steve\nHello there\n[0:31] Priya\nHi\""
        )

        let draft = try onlyDraft(result)
        let segments = draft.transcript
        #expect(segments.count == 2)
        #expect(segments[0].speakerLabel == "Steve")
        #expect(segments[0].startTime == 23)
        #expect(segments[0].text == "Hello there")
        #expect(segments[1].speakerLabel == "Priya")
        #expect(segments[1].startTime == 31)
        #expect(segments[1].text == "Hi")
    }

    @Test("When every row is bad the scan reports nothingToImport")
    func nothingToImport() {
        let result = scanCSV(
            canonicalHeader + "\n,yesterday,,,,\n,also bad,,,,"
        )

        // Full-width rows: the blank ids make both rows misformatted and
        // nothing else.
        #expect(result.warnings == [.misformattedRows(count: 2, exampleRows: [2, 3])])
        #expect(result.criticalErrors == [.nothingToImport])
        #expect(result.drafts.isEmpty)
        #expect(!result.canProceed)
        #expect(result.needsReview)
    }

    @Test("Drafts keep file order")
    func fileOrderPreserved() {
        let first = UUID()
        let second = UUID()
        let result = scanCSV(
            canonicalHeader + "\n\(first),A,2026-01-03,summary,,\n\(second),B,2026-01-04,summary,,"
        )

        #expect(result.drafts.map(\.meetingID) == [first, second])
    }

    @Test("Epoch-millisecond dates parse")
    func epochMilliseconds() throws {
        let result = scanCSV(canonicalHeader + "\n\(UUID()),T,1750000000123,,,")

        let draft = try onlyDraft(result)
        #expect(draft.created == Date(timeIntervalSince1970: 1_750_000_000.123))
    }
}

// MARK: - Ragged Rows & File-Level Errors

@Suite("MeetingCSVImporter.scan — ragged rows and file errors")
struct MeetingCSVImporterFileTests {
    @Test("A short row is padded and still imports")
    func raggedShortRowPadded() throws {
        let id = UUID()
        let result = scanCSV(canonicalHeader + "\n\(id),T,2026-01-03,Recap")

        #expect(result.warnings == [.raggedRows(count: 1, exampleRows: [2])])

        let draft = try onlyDraft(result)
        #expect(draft.summary == "Recap")
        #expect(draft.notes.isEmpty)
    }

    @Test("A short row whose padding blanks a required field is also misformatted")
    func raggedShortRowMissingRequired() {
        let result = scanCSV(canonicalHeader + "\n\(UUID()),T")

        #expect(result.warnings.contains(.raggedRows(count: 1, exampleRows: [2])))
        #expect(
            result.warnings.contains(.misformattedRows(count: 1, exampleRows: [2]))
        )
        #expect(result.criticalErrors == [.nothingToImport])
    }

    @Test("A long row drops its extra fields")
    func raggedLongRowTruncated() throws {
        let id = UUID()
        let result = scanCSV(canonicalHeader + "\n\(id),T,2026-01-03,Recap,Note,text,EXTRA")

        #expect(result.warnings == [.raggedRows(count: 1, exampleRows: [2])])

        let draft = try onlyDraft(result)
        #expect(draft.meetingID == id)
        #expect(draft.summary == "Recap")
        #expect(draft.notes == "Note")
        #expect(draft.transcript.map(\.text) == ["text"])
    }

    @Test("An unreadable file reports unreadableFile")
    func unreadableFile() throws {
        let result = MeetingCSVImporter.scan(
            fileURL: URL(fileURLWithPath: "/nonexistent/biscotti-test-import.csv"),
            existing: ExistingMeetingIdentity()
        )

        let first = try #require(result.criticalErrors.first)
        guard case .unreadableFile = first else {
            Issue.record("Expected unreadableFile, got \(first)")
            return
        }
        #expect(!result.canProceed)
    }

    @Test("Bytes that are not UTF-8 report notUTF8")
    func notUTF8() {
        #expect(scanBytes([0xFF, 0xFE, 0x41, 0x00]).criticalErrors == [.notUTF8])
    }

    @Test("Empty data reports emptyFile")
    func emptyFile() {
        #expect(scanBytes([]).criticalErrors == [.emptyFile])
    }

    @Test("A malformed CSV reports malformedCSV with the row")
    func malformedCSV() {
        let result = scanCSV(canonicalHeader + "\n\"unterminated,more")
        #expect(result.criticalErrors == [.malformedCSV(row: 2)])
    }

    @Test("Blank lines among the data are ignored, not warned about")
    func blankLinesDropped() throws {
        let id = UUID()
        let result = scanCSV(
            canonicalHeader + "\n"
                + "\(id),T,2026-01-03,summary,,\n"
                + "\n"
                + "\n"
        )

        #expect(result.criticalErrors.isEmpty)
        #expect(result.warnings.isEmpty)

        let draft = try onlyDraft(result)
        #expect(draft.meetingID == id)
    }

    @Test("Trailing blank lines keep a header-only file on the commit-zero path")
    func headerOnlyWithTrailingBlanks() {
        // Same user content as a plain header-only file: no critical
        // error, so the flow commits and reports "Imported 0 meetings."
        // rather than blocking.
        let result = scanCSV(canonicalHeader + "\n\n")

        #expect(result.criticalErrors.isEmpty)
        #expect(result.warnings.isEmpty)
        #expect(result.drafts.isEmpty)
    }

    @Test("Whitespace-only lines are dropped like blank lines, not double-reported")
    func whitespaceOnlyLinesDropped() throws {
        let id = UUID()
        let result = scanCSV(
            canonicalHeader + "\n"
                + "   \n"
                + "\(id),T,2026-01-03,summary,,\n"
                + "\t\n"
        )

        #expect(result.criticalErrors.isEmpty)
        #expect(result.warnings.isEmpty)

        let draft = try onlyDraft(result)
        #expect(draft.meetingID == id)
    }

    @Test("A UTF-8 BOM before the header does not block the import")
    func bomPrefixedFile() throws {
        let id = UUID()
        let csv = canonicalHeader + "\n\(id),T,2026-01-03,summary,,"
        let result = scanBytes([0xEF, 0xBB, 0xBF] + Array(csv.utf8))

        #expect(result.criticalErrors.isEmpty)
        #expect(result.warnings.isEmpty)

        let draft = try onlyDraft(result)
        #expect(draft.meetingID == id)
    }
}

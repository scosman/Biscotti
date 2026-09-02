import DataStore
import Foundation
import Testing
@testable import ImportExport

/// Verbatim alert copy (functional spec §3.2/§3.3): counts, singular and
/// plural verbs, and the capped example-row suffixes. The warnings'
/// `message` strings are what the review and blocked alerts render.
@Suite("Import message copy")
struct ImportMessageCopyTests {
    @Test("misformattedRows copy is singular/plural-correct with examples")
    func misformattedRowsCopy() {
        #expect(
            ImportWarning.misformattedRows(count: 1, exampleRows: [2]).message
                == "1 row is missing a required value and will be skipped (row 2)."
        )
        #expect(
            ImportWarning.misformattedRows(count: 3, exampleRows: [2, 3, 4]).message
                == "3 rows are missing a required value and will be skipped (rows 2, 3, 4)."
        )
        #expect(
            ImportWarning.misformattedRows(count: 1, exampleRows: []).message
                == "1 row is missing a required value and will be skipped."
        )
    }

    @Test("emptyContent copy is singular/plural-correct")
    func emptyContentCopy() {
        #expect(
            ImportWarning.emptyContent(count: 1).message
                == "1 row has no summary, notes, or transcript."
        )
        #expect(
            ImportWarning.emptyContent(count: 2).message
                == "2 rows have no summary, notes, or transcript."
        )
    }

    @Test("alreadyInDatabase copy is singular/plural-correct")
    func alreadyInDatabaseCopy() {
        #expect(
            ImportWarning.alreadyInDatabase(count: 1).message
                == "1 meeting already exists in your database, it will be skipped."
        )
        #expect(
            ImportWarning.alreadyInDatabase(count: 3).message
                == "3 meetings already exist in your database, these will be skipped."
        )
    }

    @Test("duplicateInFile copy carries first-wins and example rows")
    func duplicateInFileCopy() {
        #expect(
            ImportWarning.duplicateInFile(count: 1, exampleRows: [3]).message
                == "1 row has the same ID as an earlier row; the first occurrence wins (row 3)."
        )
        #expect(
            ImportWarning.duplicateInFile(count: 2, exampleRows: [4, 5]).message
                == "2 rows have the same ID as an earlier row; the first occurrence wins (rows 4, 5)."
        )
    }

    @Test("raggedRows copy carries the header comparison and example rows")
    func raggedRowsCopy() {
        #expect(
            ImportWarning.raggedRows(count: 1, exampleRows: [2]).message
                == "1 row has a different number of fields than the header (row 2)."
        )
        #expect(
            ImportWarning.raggedRows(count: 2, exampleRows: [2, 3]).message
                == "2 rows have a different number of fields than the header (rows 2, 3)."
        )
    }

    @Test("ambiguousColumns copy names the canonical winner")
    func ambiguousColumnsCopy() {
        #expect(
            ImportWarning.ambiguousColumns(["id"]).message
                == "Columns 'id' and 'document_id' are both present; 'id' is used."
        )
    }

    @Test("critical error copy matches the spec wording")
    func criticalErrorCopy() {
        #expect(
            ImportCriticalError.unreadableFile("boom").message
                == "The file could not be read: boom"
        )
        #expect(ImportCriticalError.notUTF8.message == "The file is not valid UTF-8 text.")
        #expect(ImportCriticalError.emptyFile.message == "The file is empty.")
        #expect(
            ImportCriticalError.missingColumns(["id", "created"]).message
                == "Required columns are missing: id, created."
        )
        #expect(
            ImportCriticalError.malformedCSV(row: 4).message
                == "The file is not valid CSV (unterminated quoted field at row 4)."
        )
        #expect(
            ImportCriticalError.nothingToImport.message
                == "No meetings in this file can be imported."
        )
    }
}

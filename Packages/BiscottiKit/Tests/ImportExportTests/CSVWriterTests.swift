import Testing
@testable import ImportExport

@Suite("CSVWriter")
struct CSVWriterTests {
    @Test("Plain fields are not quoted")
    func plainFieldsStayUnquoted() {
        #expect(CSVWriter.field("hello") == "hello")
        #expect(CSVWriter.field("a b:c") == "a b:c")
        #expect(CSVWriter.field("") == "")
    }

    @Test("Fields with commas, quotes, CR, or LF are quoted")
    func specialFieldsAreQuoted() {
        #expect(CSVWriter.field("a,b") == "\"a,b\"")
        #expect(CSVWriter.field("a\nb") == "\"a\nb\"")
        #expect(CSVWriter.field("a\rb") == "\"a\rb\"")
    }

    @Test("Embedded quotes are doubled")
    func embeddedQuotesAreDoubled() {
        #expect(CSVWriter.field("he said \"hi\"") == "\"he said \"\"hi\"\"\"")
    }

    @Test("Rows are comma-joined and CRLF-terminated")
    func rowFormat() {
        #expect(CSVWriter.row(["a", "b,c", "d"]) == "a,\"b,c\",d\r\n")
        #expect(CSVWriter.row(["a", ""]) == "a,\r\n")
    }

    @Test("Writer output round-trips through the parser")
    func roundTrip() throws {
        let fields = ["plain", "with,comma", "quote \" here", "line1\nline2", ""]
        let parsed = try CSVParser.parse(CSVWriter.row(fields))
        #expect(parsed == [fields])
    }
}

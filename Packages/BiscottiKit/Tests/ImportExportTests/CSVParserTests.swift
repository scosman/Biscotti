import Testing
@testable import ImportExport

@Suite("CSVParser")
struct CSVParserTests {
    @Test("Embedded commas stay inside quoted fields")
    func quotedCommas() throws {
        #expect(try CSVParser.parse("a,\"b,c\",d") == [["a", "b,c", "d"]])
    }

    @Test("Embedded newlines stay inside quoted fields")
    func quotedNewlines() throws {
        #expect(try CSVParser.parse("\"line1\nline2\",next") == [["line1\nline2", "next"]])
        #expect(try CSVParser.parse("\"a\r\nb\",x") == [["a\r\nb", "x"]])
        #expect(try CSVParser.parse("\"a\rb\",x") == [["a\rb", "x"]])
    }

    @Test("Doubled quotes decode to a single quote")
    func doubledQuotes() throws {
        #expect(try CSVParser.parse("\"say \"\"hi\"\"\",plain") == [["say \"hi\"", "plain"]])
    }

    @Test("CRLF separators split rows")
    func crlfSeparators() throws {
        #expect(try CSVParser.parse("a,b\r\nc,d") == [["a", "b"], ["c", "d"]])
    }

    @Test("LF separators split rows")
    func lfSeparators() throws {
        #expect(try CSVParser.parse("a,b\nc,d") == [["a", "b"], ["c", "d"]])
    }

    @Test("Bare CR separators split rows")
    func crSeparators() throws {
        #expect(try CSVParser.parse("a,b\rc,d") == [["a", "b"], ["c", "d"]])
        // A CR followed by LF is one terminator, not two.
        #expect(try CSVParser.parse("a\r\r\nb") == [["a"], [""], ["b"]])
    }

    @Test("A trailing row terminator does not create a phantom empty row")
    func trailingTerminator() throws {
        #expect(try CSVParser.parse("a,b\r\n") == [["a", "b"]])
        #expect(try CSVParser.parse("a,b\n") == [["a", "b"]])
        #expect(try CSVParser.parse("a,b\r") == [["a", "b"]])
    }

    @Test("A leading BOM is ignored")
    func leadingBOM() throws {
        #expect(try CSVParser.parse("\u{FEFF}a,b") == [["a", "b"]])
    }

    @Test("Ragged rows are passed through as-is")
    func raggedRows() throws {
        #expect(try CSVParser.parse("a,b,c\n1,2") == [["a", "b", "c"], ["1", "2"]])
        #expect(try CSVParser.parse("a,b\n1,2,3") == [["a", "b"], ["1", "2", "3"]])
    }

    @Test("An unterminated quote throws with the 1-based row number")
    func unterminatedQuote() {
        #expect(throws: CSVParseError.unterminatedQuote(row: 1)) {
            try CSVParser.parse("\"oops")
        }
        #expect(throws: CSVParseError.unterminatedQuote(row: 2)) {
            try CSVParser.parse("a,b\n\"oops,more")
        }
    }

    @Test("Empty input yields no rows")
    func emptyInput() throws {
        #expect(try CSVParser.parse("") == [])
    }

    @Test("The final row is kept without a terminator")
    func finalRowWithoutTerminator() throws {
        #expect(try CSVParser.parse("a,b") == [["a", "b"]])
        #expect(try CSVParser.parse("a,") == [["a", ""]])
    }

    @Test("An empty quoted field is an empty string")
    func emptyQuotedField() throws {
        #expect(try CSVParser.parse("a,\"\",b") == [["a", "", "b"]])
    }

    @Test("A lone quoted empty field is one row with one empty field")
    func loneQuotedEmptyField() throws {
        #expect(try CSVParser.parse("\"\"") == [[""]])
    }

    @Test("A doubled quote at the start of a quoted field is a literal quote")
    func doubledQuoteAtFieldStart() throws {
        // `"""x"` = open quote, escaped pair (one literal quote), x,
        // closing quote — the case the quotePending flag exists for.
        #expect(try CSVParser.parse("\"\"\"x\",y") == [["\"x", "y"]])
    }

    @Test("Text after a closing quote is kept, with the quote as content")
    func textAfterClosingQuote() throws {
        #expect(try CSVParser.parse("\"closed\"tail,x") == [["closed\"tail", "x"]])
    }
}

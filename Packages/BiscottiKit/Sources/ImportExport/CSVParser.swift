import Foundation

/// RFC 4180 CSV parsing, lenient where other tools' exports demand it
/// (architecture §4.1): mixed CRLF/LF/CR row separators, ragged rows
/// passed through for the importer to normalize, and a tolerated leading
/// BOM. Terminators inside quoted fields are literal content.
enum CSVParseError: Error, Equatable {
    /// A quoted field was never closed. `row` is 1-based, counting the
    /// header as row 1.
    case unterminatedQuote(row: Int)

    var row: Int {
        switch self {
        case let .unterminatedQuote(row): row
        }
    }
}

enum CSVParser {
    static func parse(_ text: String) throws(CSVParseError) -> [[String]] {
        var scalars = Array(text.unicodeScalars)
        // The import flow strips the BOM from the raw bytes before decoding;
        // this second strip keeps the parser correct for any caller.
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }

        var scanner = Scanner()
        var index = 0
        while index < scalars.count {
            if scanner.consume(scalars[index]) {
                index = indexAfterRowTerminator(scalars, at: index)
            } else {
                index += 1
            }
        }

        if scanner.isUnterminated {
            throw CSVParseError.unterminatedQuote(row: scanner.rowIndex)
        }
        scanner.finishRowIfPending()
        return scanner.rows
    }

    /// A CR may be half of a CRLF pair — skip its LF too.
    private static func indexAfterRowTerminator(
        _ scalars: [Unicode.Scalar],
        at index: Int
    ) -> Int {
        if scalars[index] == "\r",
           index + 1 < scalars.count,
           scalars[index + 1] == "\n"
        {
            return index + 2
        }
        return index + 1
    }
}

/// The field/row state machine. `consume` feeds one scalar and returns
/// whether it ended a row.
private struct Scanner {
    private enum State {
        case fieldStart
        case inUnquoted
        case inQuoted
    }

    private var state = State.fieldStart
    /// A quote seen inside a quoted field is ambiguous until the next
    /// scalar: a second quote is a literal quote, anything else closes
    /// the field.
    private var quotePending = false
    private var fields: [String] = []
    private var field = String.UnicodeScalarView()

    var rows: [[String]] = []
    var rowIndex = 1

    var isUnterminated: Bool {
        state == .inQuoted && !quotePending
    }

    mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        switch state {
        case .fieldStart: consumeAtFieldStart(scalar)
        case .inUnquoted: consumeInUnquoted(scalar)
        case .inQuoted: consumeInQuoted(scalar)
        }
    }

    /// Emits the final row only when it has content: a trailing
    /// terminator already ended the last row, leaving nothing pending.
    mutating func finishRowIfPending() {
        if !(fields.isEmpty && field.isEmpty) {
            endField()
            rows.append(fields)
        }
    }

    private mutating func consumeAtFieldStart(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\"":
            state = .inQuoted
        case ",":
            endField()
        case "\r", "\n":
            endRow()
            return true
        default:
            field.append(scalar)
            state = .inUnquoted
        }
        return false
    }

    private mutating func consumeInUnquoted(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case ",":
            endField()
        case "\r", "\n":
            endRow()
            return true
        default:
            field.append(scalar)
        }
        return false
    }

    private mutating func consumeInQuoted(_ scalar: Unicode.Scalar) -> Bool {
        if quotePending {
            return consumeAfterPendingQuote(scalar)
        }
        if scalar == "\"" {
            quotePending = true
        } else {
            // Everything else — commas and newlines included — is
            // literal content inside a quoted field.
            field.append(scalar)
        }
        return false
    }

    private mutating func consumeAfterPendingQuote(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\"":
            field.append("\"")
            quotePending = false
            return false
        case ",":
            endField()
            return false
        case "\r", "\n":
            endRow()
            return true
        default:
            // Lenient: content after a closing quote keeps the quote as
            // a literal rather than failing the file. The field then
            // continues as unquoted text so a later comma still closes it.
            field.append("\"")
            field.append(scalar)
            quotePending = false
            state = .inUnquoted
            return false
        }
    }

    private mutating func endField() {
        fields.append(String(field))
        field.removeAll()
        state = .fieldStart
        quotePending = false
    }

    private mutating func endRow() {
        endField()
        rows.append(fields)
        fields = []
        rowIndex += 1
    }
}

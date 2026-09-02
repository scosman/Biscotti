import Foundation

/// RFC 4180 CSV writing (architecture §4.1): a field is quoted when it
/// contains a comma, double quote, CR, or LF; embedded quotes are doubled;
/// rows are comma-joined and CRLF-terminated. Newlines inside a field are
/// preserved as-is (LF) — only the row separator is CRLF.
enum CSVWriter {
    static func field(_ value: String) -> String {
        let needsQuoting = value.unicodeScalars.contains { scalar in
            scalar == "," || scalar == "\"" || scalar == "\r" || scalar == "\n"
        }
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func row(_ fields: [String]) -> String {
        fields.map(field).joined(separator: ",") + "\r\n"
    }
}

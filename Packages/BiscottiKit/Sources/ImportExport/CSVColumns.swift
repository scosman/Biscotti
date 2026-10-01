/// The CSV column contract (functional spec §1.1–§1.2): the canonical
/// column set and order, the aliases import resolves, and the header row
/// export writes. Shared by the importer (header resolution), the exporter
/// (header row), and warning copy (alias names).
enum CSVColumns {
    static let id = "id"
    static let title = "title"
    static let created = "created"
    static let summary = "summary"
    static let notes = "notes"
    static let transcript = "transcript"

    /// Canonical column names in the exact order export writes them.
    static let canonical = [id, title, created, summary, notes, transcript]

    /// Columns a header must provide, in canonical order.
    static let required = [id, title, created]

    /// Header-cell aliases from other apps' exports, mapped to their
    /// canonical column.
    static let aliases = [
        "document_id": id,
        "document_title": title,
        "document_created": created
    ]

    /// The alias for a canonical column name, when one exists.
    static func alias(for canonical: String) -> String? {
        aliases.first { $0.value == canonical }?.key
    }

    /// The canonical header row, CRLF-terminated.
    static var headerRow: String {
        CSVWriter.row(canonical)
    }
}

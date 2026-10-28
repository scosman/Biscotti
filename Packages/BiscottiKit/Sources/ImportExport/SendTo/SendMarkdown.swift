import DataStore
import Foundation

/// Builds the markdown body and per-destination additions (functional spec §3).
public enum SendMarkdown {
    /// The shared markdown body for all destinations.
    ///
    /// Layout: title heading, metadata line, optional attendees, optional
    /// summary (no wrapper heading), optional `# Notes` section. Blocks
    /// joined with one blank line. Ends with exactly one `\n`.
    public static func body(
        _ source: ExportSource,
        timeZone: TimeZone = .current
    ) -> String {
        var blocks: [String] = []

        // Title
        let title = cleanTitle(source.title)
        blocks.append("# \(title)")

        // Metadata line + attendees (no blank line between them per spec §3.1)
        var headerBlock = metadataLine(source, timeZone: timeZone)
        let attendees = source.attendees.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !attendees.isEmpty {
            headerBlock += "\nAttendees: \(attendees.joined(separator: ", "))"
        }
        blocks.append(headerBlock)

        // Summary (verbatim, trimmed; omit if empty)
        let summary = normaliseLineEndings(source.summary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            blocks.append(summary)
        }

        // Notes (with heading; omit both if empty)
        let notes = normaliseLineEndings(source.notes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            blocks.append("# Notes\n\n\(notes)")
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Obsidian YAML frontmatter (functional spec §3.2).
    /// Key order is fixed. String values use JSON-style escaping in double quotes.
    public static func obsidianFrontmatter(
        _ source: ExportSource,
        tags: [String],
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var lines = ["---"]
        lines.append("tags: [\(tags.map { yamlQuote($0) }.joined(separator: ", "))]")
        lines.append("biscotti_url: \(yamlQuote(source.biscottiURL.absoluteString))")
        lines.append("date: \(formatter.string(from: source.start))")

        let attendees = source.attendees.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !attendees.isEmpty {
            lines.append("attendees: [\(attendees.map { yamlQuote($0) }.joined(separator: ", "))]")
        }

        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Apple Notes tag footer: `#biscotti #project-x`.
    public static func notesTagFooter(_ tags: [String]) -> String {
        tags.map { "#\($0)" }.joined(separator: " ")
    }

    // MARK: - Helpers

    /// Clean the title: trim, collapse newlines to spaces, fallback.
    private static func cleanTitle(_ raw: String) -> String {
        var title = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse any newline sequences to a single space
        title = title.replacingOccurrences(
            of: #"[\r\n]+"#, with: " ", options: .regularExpression
        )
        return title.isEmpty ? "Untitled Meeting" : title
    }

    /// Build the metadata line: `2026-10-21 10:00 · 42 min · [Open in Biscotti](url)`
    private static func metadataLine(
        _ source: ExportSource,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var parts: [String] = [formatter.string(from: source.start)]

        if let minutes = source.durationMinutes, minutes > 0 {
            parts.append(formatDuration(minutes))
        }

        parts.append("[Open in Biscotti](\(source.biscottiURL.absoluteString))")

        return parts.joined(separator: " \u{00B7} ")
    }

    /// Format duration: `42 min` or `1 h 05 min`.
    private static func formatDuration(_ totalMinutes: Int) -> String {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return String(format: "%d h %02d min", hours, minutes)
        }
        return "\(minutes) min"
    }

    /// Replace `\r\n` and `\r` with `\n`.
    private static func normaliseLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// JSON-style double-quoted string for YAML values.
    private static func yamlQuote(_ value: String) -> String {
        var escaped = value
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

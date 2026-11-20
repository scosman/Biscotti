import Foundation

/// The meeting fields an export needs. Built by `AppCore` from DataStore
/// read models; kept free of DataStore so this module stays testable on its
/// own.
public struct ExportableMeeting: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let date: Date
    public let durationMinutes: Int?
    public let attendees: [String]
    public let tags: [String]
    public let summary: String
    public let notes: String
    /// Plain-text transcript in Biscotti's `[M:SS] Speaker` format.
    public let transcript: String
    /// One line per speaker saying who they are and how sure
    /// the app is, e.g. "Lee Morgan: Screen · Medium. Highlighted ...".
    public var speakers: [String] = []

    public init(
        id: UUID,
        title: String,
        date: Date,
        durationMinutes: Int? = nil,
        attendees: [String] = [],
        tags: [String] = [],
        summary: String = "",
        notes: String = "",
        transcript: String = ""
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.durationMinutes = durationMinutes
        self.attendees = attendees
        self.tags = tags
        self.summary = summary
        self.notes = notes
        self.transcript = transcript
    }

    /// Whether there is any text worth exporting.
    public var hasContent: Bool {
        [summary, notes, transcript].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// Renders a meeting as one Markdown file with YAML frontmatter.
public enum MeetingMarkdown {
    public static func render(_ meeting: ExportableMeeting, timeZone: TimeZone = .current) -> String {
        var blocks = [frontmatter(meeting, timeZone: timeZone), "# \(singleLine(meeting.title))"]
        appendSection("Speakers", meeting.speakers.map { "- \($0)" }.joined(separator: "\n"), to: &blocks)
        appendSection("Summary", meeting.summary, to: &blocks)
        appendSection("Notes", meeting.notes, to: &blocks)
        appendSection("Transcript", meeting.transcript, to: &blocks)
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// `2026-11-17 0930 Weekly sync [1a2b3c4d].md`. The bracketed ID prefix
    /// keeps the name unique and lets a re-export find and replace the
    /// previous file even after the title changes.
    public static func fileName(for meeting: ExportableMeeting, timeZone: TimeZone = .current) -> String {
        let stamp = formatted(meeting.date, "yyyy-MM-dd HHmm", timeZone: timeZone)
        return "\(stamp) \(sanitize(meeting.title)) \(idMarker(for: meeting.id)).md"
    }

    public static func idMarker(for id: UUID) -> String {
        "[\(id.uuidString.prefix(8).lowercased())]"
    }

    /// True when the file named `name` is this meeting's export: its name
    /// carries the meeting's marker and its frontmatter names the meeting.
    /// The 8-character marker alone could match another meeting.
    public static func isExport(named name: String, in directory: URL, of id: UUID) -> Bool {
        guard name.hasSuffix("\(idMarker(for: id)).md"),
              let handle = FileHandle(forReadingAtPath: directory.appendingPathComponent(name).path)
        else { return false }
        defer { try? handle.close() }
        let head = String(bytes: (try? handle.read(upToCount: 4096)) ?? Data(), encoding: .utf8) ?? ""
        return head.contains("biscotti_id: \(id.uuidString)")
    }

    /// Removes characters that are unsafe in file names, collapses
    /// whitespace and caps the length.
    public static func sanitize(_ title: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]\0")
            .union(.controlCharacters)
        // Disallowed characters become spaces, then whitespace runs collapse,
        // so "Q4 / plan" and "a\nb" read as "Q4 plan" and "a b".
        let replaced = String(String.UnicodeScalarView(title.unicodeScalars.map {
            disallowed.contains($0) ? " " : $0
        }))
        var result = replaced
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        while result.hasPrefix(".") {
            result.removeFirst()
        }
        result = String(result.prefix(100)).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "Untitled Meeting" : result
    }

    // MARK: - Private

    private static func frontmatter(_ meeting: ExportableMeeting, timeZone: TimeZone) -> String {
        var lines = [
            "---",
            "biscotti_id: \(meeting.id.uuidString)",
            "title: \(quoted(meeting.title))",
            "date: \(formatted(meeting.date, "yyyy-MM-dd'T'HH:mm:ssXXXXX", timeZone: timeZone))"
        ]
        if let minutes = meeting.durationMinutes {
            lines.append("duration_minutes: \(minutes)")
        }
        lines.append("attendees: \(list(meeting.attendees))")
        lines.append("tags: \(list(meeting.tags))")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private static func appendSection(_ heading: String, _ text: String, to blocks: inout [String]) {
        let body = stripLeadingHeading(
            heading,
            from: text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !body.isEmpty else { return }
        blocks.append("## \(heading)\n\n\(body)")
    }

    /// Drops a first line that repeats the section's own heading (the AI
    /// summary often starts with "## Summary"), at any heading level.
    static func stripLeadingHeading(_ heading: String, from body: String) -> String {
        guard let firstLine = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              firstLine.hasPrefix("#")
        else { return body }
        let title = firstLine.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        guard title.caseInsensitiveCompare(heading) == .orderedSame else { return body }
        return String(body.dropFirst(firstLine.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func list(_ values: [String]) -> String {
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return "[" + cleaned.map(quoted).joined(separator: ", ") + "]"
    }

    /// JSON string escaping, which is valid YAML double-quoted scalar syntax.
    private static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let encoded = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return encoded
    }

    private static func singleLine(_ value: String) -> String {
        let flattened = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.isEmpty ? "Untitled Meeting" : flattened
    }

    private static func formatted(_ date: Date, _ format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

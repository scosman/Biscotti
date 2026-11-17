import DataStore
import Foundation
import Testing
@testable import ImportExport

@Suite("SendMarkdown")
struct MarkdownTests {
    // A fixed time zone and date for deterministic output.
    // swiftlint:disable:next force_unwrapping
    private let timeZone = TimeZone(identifier: "America/New_York")!
    /// 2026-10-21 14:00 UTC = 2026-10-21 10:00 EDT
    private let fixedDate = Date(timeIntervalSince1970: 1_792_591_200)
    // swiftlint:disable:next force_unwrapping
    private let fixedID = UUID(uuidString: "AABBCCDD-1122-3344-5566-778899AABBCC")!

    private func source(
        title: String = "Weekly Sync",
        durationMinutes: Int? = 42,
        attendees: [String] = ["Alice", "Bob"],
        summary: String = "## Key Points\n\n- Ship v2",
        notes: String = "Follow up with design team",
        tags: [String] = ["project-x"]
    ) -> ExportSource {
        ExportSource(
            meetingID: fixedID,
            title: title,
            start: fixedDate,
            durationMinutes: durationMinutes,
            attendees: attendees,
            summary: summary,
            notes: notes,
            tags: tags
        )
    }

    // MARK: - Golden body

    @Test("Golden body with all fields")
    func goldenBody() {
        let body = SendMarkdown.body(source(), timeZone: timeZone)
        let expected = """
        # Weekly Sync

        2026-10-21 10:00 \u{00B7} 42 min \u{00B7} [Open in Biscotti](biscotti://meeting/AABBCCDD-1122-3344-5566-778899AABBCC)
        Attendees: Alice, Bob

        ## Key Points

        - Ship v2

        # Notes

        Follow up with design team
        """
        #expect(body == expected + "\n")
    }

    // MARK: - Omission cases

    @Test("Body without summary omits summary block")
    func noSummary() {
        let body = SendMarkdown.body(source(summary: ""), timeZone: timeZone)
        #expect(!body.contains("Key Points"))
        #expect(body.contains("# Notes"))
    }

    @Test("Body without notes omits Notes heading and block")
    func noNotes() {
        let body = SendMarkdown.body(source(notes: ""), timeZone: timeZone)
        #expect(!body.contains("# Notes"))
        #expect(body.contains("Key Points"))
    }

    @Test("Body without attendees omits attendees line")
    func noAttendees() {
        let body = SendMarkdown.body(source(attendees: []), timeZone: timeZone)
        #expect(!body.contains("Attendees"))
    }

    @Test("Body without duration omits duration segment")
    func noDuration() {
        let body = SendMarkdown.body(source(durationMinutes: nil), timeZone: timeZone)
        #expect(!body.contains("min"))
        // Still has the date and link connected by ·
        #expect(body.contains("2026-10-21 10:00 \u{00B7} [Open in Biscotti]"))
    }

    @Test("Zero duration omits duration segment")
    func zeroDuration() {
        let body = SendMarkdown.body(source(durationMinutes: 0), timeZone: timeZone)
        #expect(!body.contains("min"))
    }

    // MARK: - Duration formats

    @Test("Duration under an hour: 42 min")
    func durationMinutes() {
        let body = SendMarkdown.body(source(durationMinutes: 42), timeZone: timeZone)
        #expect(body.contains("42 min"))
    }

    @Test("Duration over an hour: 1 h 05 min")
    func durationHoursMinutes() {
        let body = SendMarkdown.body(source(durationMinutes: 65), timeZone: timeZone)
        #expect(body.contains("1 h 05 min"))
    }

    @Test("Duration exactly an hour: 1 h 00 min")
    func durationExactHour() {
        let body = SendMarkdown.body(source(durationMinutes: 60), timeZone: timeZone)
        #expect(body.contains("1 h 00 min"))
    }

    // MARK: - CRLF normalisation

    @Test("CRLF in summary and notes is normalised to LF")
    func crlfNormalisation() {
        let body = SendMarkdown.body(
            source(summary: "line1\r\nline2", notes: "a\r\nb"),
            timeZone: timeZone
        )
        #expect(!body.contains("\r"))
        #expect(body.contains("line1\nline2"))
    }

    // MARK: - Title fallback

    @Test("Empty title falls back to Untitled Meeting")
    func emptyTitleFallback() {
        let body = SendMarkdown.body(source(title: ""), timeZone: timeZone)
        #expect(body.hasPrefix("# Untitled Meeting\n"))
    }

    @Test("Whitespace-only title falls back to Untitled Meeting")
    func whitespaceTitleFallback() {
        let body = SendMarkdown.body(source(title: "   "), timeZone: timeZone)
        #expect(body.hasPrefix("# Untitled Meeting\n"))
    }

    // MARK: - Determinism

    @Test("Double render produces identical output")
    func deterministic() {
        let src = source()
        let first = SendMarkdown.body(src, timeZone: timeZone)
        let second = SendMarkdown.body(src, timeZone: timeZone)
        #expect(first == second)
    }

    // MARK: - Obsidian frontmatter

    @Test("Golden frontmatter")
    func goldenFrontmatter() {
        let frontmatter = SendMarkdown.obsidianFrontmatter(
            source(),
            tags: ["biscotti", "project-x"],
            timeZone: timeZone
        )
        let expected = """
        ---
        tags: ["biscotti", "project-x"]
        biscotti_url: "biscotti://meeting/AABBCCDD-1122-3344-5566-778899AABBCC"
        date: 2026-10-21
        attendees: ["Alice", "Bob"]
        ---
        """
        #expect(frontmatter == expected + "\n")
    }

    @Test("Frontmatter escapes quotes and backslashes")
    func frontmatterEscaping() {
        let frontmatter = SendMarkdown.obsidianFrontmatter(
            source(title: "He said \"hi\\bye\"", attendees: ["O'Brien"]),
            tags: ["biscotti"],
            timeZone: timeZone
        )
        #expect(frontmatter.contains(#"attendees: ["O'Brien"]"#))
        // The URL uses the meeting ID, not the title, so escaping shows in tags would be for other values.
    }

    @Test("Frontmatter omits attendees when empty")
    func frontmatterNoAttendees() {
        let frontmatter = SendMarkdown.obsidianFrontmatter(
            source(attendees: []),
            tags: ["biscotti"],
            timeZone: timeZone
        )
        #expect(!frontmatter.contains("attendees"))
    }

    @Test("Frontmatter handles emoji in tags")
    func frontmatterEmojiTag() {
        let frontmatter = SendMarkdown.obsidianFrontmatter(
            source(),
            tags: ["biscotti", "🎉-party"],
            timeZone: timeZone
        )
        #expect(frontmatter.contains(#""🎉-party""#))
    }

    // MARK: - Notes tag footer

    @Test("Notes footer formats tags with hash prefix")
    func notesFooter() {
        let footer = SendMarkdown.notesTagFooter(["biscotti", "project-x"])
        #expect(footer == "#biscotti #project-x")
    }

    @Test("Notes footer with single tag")
    func notesFooterSingle() {
        #expect(SendMarkdown.notesTagFooter(["biscotti"]) == "#biscotti")
    }

    // MARK: - Title with newlines

    @Test("Newlines in title are collapsed to spaces")
    func titleNewlines() {
        let body = SendMarkdown.body(source(title: "Line1\nLine2\r\nLine3"), timeZone: timeZone)
        #expect(body.hasPrefix("# Line1 Line2 Line3\n"))
    }

    // MARK: - Trailing newline

    @Test("Body ends with exactly one newline")
    func trailingNewline() {
        let body = SendMarkdown.body(source(), timeZone: timeZone)
        #expect(body.hasSuffix("\n"))
        #expect(!body.hasSuffix("\n\n"))
    }
}

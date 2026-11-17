import DataStore
import Foundation
import Testing
@testable import ImportExport

@Suite("SendFilename")
struct FilenameTests {
    // swiftlint:disable:next force_unwrapping
    private let timeZone = TimeZone(identifier: "America/New_York")!
    /// 2026-10-21 14:00 UTC = 2026-10-21 10:00 EDT
    private let fixedDate = Date(timeIntervalSince1970: 1_792_591_200)
    // swiftlint:disable:next force_unwrapping
    private let fixedID = UUID(uuidString: "AABBCCDD-1122-3344-5566-778899AABBCC")!

    // MARK: - Disallowed characters (removed, not replaced)

    @Test("Asterisk is removed")
    func asterisk() {
        #expect(SendFilename.sanitize("a*b") == "ab")
    }

    @Test("Double quote is removed")
    func doubleQuote() {
        #expect(SendFilename.sanitize("a\"b") == "ab")
    }

    @Test("Backslash is removed")
    func backslash() {
        #expect(SendFilename.sanitize("a\\b") == "ab")
    }

    @Test("Forward slash is removed")
    func forwardSlash() {
        #expect(SendFilename.sanitize("a/b") == "ab")
    }

    @Test("Angle brackets are removed")
    func angleBrackets() {
        #expect(SendFilename.sanitize("a<b>c") == "abc")
    }

    @Test("Colon is removed")
    func colon() {
        #expect(SendFilename.sanitize("a:b") == "ab")
    }

    @Test("Pipe is removed")
    func pipe() {
        #expect(SendFilename.sanitize("a|b") == "ab")
    }

    @Test("Question mark is removed")
    func questionMark() {
        #expect(SendFilename.sanitize("a?b") == "ab")
    }

    @Test("Hash is removed")
    func hash() {
        #expect(SendFilename.sanitize("a#b") == "ab")
    }

    @Test("Caret is removed")
    func caret() {
        #expect(SendFilename.sanitize("a^b") == "ab")
    }

    @Test("Square brackets are removed")
    func squareBrackets() {
        #expect(SendFilename.sanitize("a[b]c") == "abc")
    }

    @Test("Control characters are removed")
    func controlChars() {
        #expect(SendFilename.sanitize("a\u{0001}b") == "ab")
    }

    // MARK: - Whitespace

    @Test("Whitespace runs are collapsed")
    func whitespaceCollapse() {
        #expect(SendFilename.sanitize("a   b") == "a b")
    }

    // MARK: - Leading dot

    @Test("Leading dot is stripped")
    func leadingDot() {
        #expect(SendFilename.sanitize(".hidden") == "hidden")
    }

    @Test("Multiple leading dots are stripped")
    func multipleLeadingDots() {
        #expect(SendFilename.sanitize("...hidden") == "hidden")
    }

    // MARK: - Truncation

    @Test("Truncates to 120 characters on a Character boundary")
    func truncation120() {
        let long = String(repeating: "a", count: 200)
        let result = SendFilename.sanitize(long)
        #expect(result.count == 120)
    }

    @Test("Truncation at emoji ZWJ boundary does not split the emoji")
    func truncationEmoji() {
        // 119 ASCII chars + a 1-character emoji (which is 1 Character) = 120
        let prefix = String(repeating: "a", count: 119)
        let result = SendFilename.sanitize(prefix + "🎉🎉🎉")
        #expect(result.count == 120)
        #expect(result.hasSuffix("🎉"))
    }

    // MARK: - Empty

    @Test("Empty title returns Untitled Meeting")
    func emptyTitle() {
        #expect(SendFilename.sanitize("") == "Untitled Meeting")
    }

    @Test("All-disallowed title returns Untitled Meeting")
    func allDisallowed() {
        #expect(SendFilename.sanitize("***") == "Untitled Meeting")
    }

    // MARK: - Obsidian name

    @Test("Obsidian name: <title> <date>")
    func obsidianName() {
        let src = ExportSource(
            meetingID: fixedID,
            title: "Weekly Sync",
            start: fixedDate
        )
        #expect(SendFilename.obsidianName(src, timeZone: timeZone) == "Weekly Sync 2026-10-21")
    }

    @Test("Obsidian name sanitizes the title")
    func obsidianNameSanitized() {
        let src = ExportSource(
            meetingID: fixedID,
            title: "a/b*c",
            start: fixedDate
        )
        #expect(SendFilename.obsidianName(src, timeZone: timeZone) == "abc 2026-10-21")
    }
}

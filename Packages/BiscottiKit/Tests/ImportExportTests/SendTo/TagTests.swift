import DataStore
import Foundation
import Testing
@testable import ImportExport

@Suite("SendTags")
struct TagTests {
    // MARK: - Bear

    @Test("Bear: whitespace runs become dashes")
    func bearWhitespace() {
        let tags = SendTags.tags(["hello world"], for: .bear)
        #expect(tags == ["biscotti", "hello-world"])
    }

    @Test("Bear: commas are removed")
    func bearComma() {
        let tags = SendTags.tags(["a,b"], for: .bear)
        #expect(tags == ["biscotti", "ab"])
    }

    @Test("Bear: hashes are removed")
    func bearHash() {
        let tags = SendTags.tags(["#topic"], for: .bear)
        #expect(tags == ["biscotti", "topic"])
    }

    @Test("Bear: slash is kept (nested tags)")
    func bearSlash() {
        let tags = SendTags.tags(["work/meetings"], for: .bear)
        #expect(tags == ["biscotti", "work/meetings"])
    }

    // MARK: - Obsidian

    @Test("Obsidian: whitespace runs become dashes")
    func obsidianWhitespace() {
        let tags = SendTags.tags(["hello world"], for: .obsidian)
        #expect(tags == ["biscotti", "hello-world"])
    }

    @Test("Obsidian: only letters/digits/_/-/slash kept")
    func obsidianAllowedChars() {
        let tags = SendTags.tags(["a!@$b"], for: .obsidian)
        #expect(tags == ["biscotti", "ab"])
    }

    @Test("Obsidian: slash at ends is trimmed")
    func obsidianSlashTrim() {
        let tags = SendTags.tags(["/topic/"], for: .obsidian)
        #expect(tags == ["biscotti", "topic"])
    }

    @Test("Obsidian: digits-only tag gets t prefix")
    func obsidianDigitsOnly() {
        let tags = SendTags.tags(["2024"], for: .obsidian)
        #expect(tags == ["biscotti", "t2024"])
    }

    @Test("Obsidian: keeps slash for nested tags")
    func obsidianSlash() {
        let tags = SendTags.tags(["work/meetings"], for: .obsidian)
        #expect(tags == ["biscotti", "work/meetings"])
    }

    // MARK: - Apple Notes

    @Test("Apple Notes: whitespace runs become dashes")
    func notesWhitespace() {
        let tags = SendTags.tags(["hello world"], for: .appleNotes)
        #expect(tags == ["biscotti", "hello-world"])
    }

    @Test("Apple Notes: only letters/digits/_/- kept")
    func notesAllowedChars() {
        let tags = SendTags.tags(["a/b!c"], for: .appleNotes)
        #expect(tags == ["biscotti", "abc"])
    }

    // MARK: - Shared rules

    @Test("biscotti is always first")
    func biscottiFirst() {
        let tags = SendTags.tags(["zebra", "alpha"], for: .bear)
        #expect(tags.first == "biscotti")
    }

    @Test("Meeting tag equal to biscotti (case-insensitive) is dropped")
    func biscottiDuplicate() {
        let tags = SendTags.tags(["Biscotti", "other"], for: .bear)
        // Only one biscotti
        #expect(tags == ["biscotti", "other"])
    }

    @Test("Mixed-case duplicates are deduped")
    func mixedCaseDedup() {
        let tags = SendTags.tags(["Alpha", "alpha", "ALPHA"], for: .bear)
        #expect(tags.count == 2) // biscotti + one alpha
    }

    @Test("Empty tag after sanitization is dropped")
    func emptyAfterCleanup() {
        let tags = SendTags.tags(["!!!", "valid"], for: .obsidian)
        #expect(tags == ["biscotti", "valid"])
    }

    @Test("Tags are sorted case-insensitively after biscotti")
    func sortOrder() {
        let tags = SendTags.tags(["Zebra", "alpha", "Beta"], for: .bear)
        #expect(tags == ["biscotti", "alpha", "Beta", "Zebra"])
    }

    @Test("No raw tags produces only biscotti")
    func emptyRaw() {
        let tags = SendTags.tags([], for: .bear)
        #expect(tags == ["biscotti"])
    }
}

import DataStore
import Foundation
import Testing
@testable import ImportExport

@Suite("SendPayload")
struct PayloadTests {
    // swiftlint:disable:next force_unwrapping
    private let timeZone = TimeZone(identifier: "America/New_York")!
    /// 2026-10-21 14:00 UTC = 2026-10-21 10:00 EDT
    private let fixedDate = Date(timeIntervalSince1970: 1_792_591_200)
    // swiftlint:disable:next force_unwrapping
    private let fixedID = UUID(uuidString: "AABBCCDD-1122-3344-5566-778899AABBCC")!

    private func source(
        title: String = "Weekly Sync",
        summary: String = "Summary",
        notes: String = "Notes",
        tags: [String] = ["project-x"]
    ) -> ExportSource {
        ExportSource(
            meetingID: fixedID,
            title: title,
            start: fixedDate,
            durationMinutes: 42,
            attendees: ["Alice"],
            summary: summary,
            notes: notes,
            tags: tags
        )
    }

    // MARK: - Hash format

    @Test("Hash is 64 lowercase hex characters")
    func hashFormat() {
        let payload = SendPayload.build(source(), for: .obsidian, timeZone: timeZone)
        let hash = payload.contentHash
        #expect(hash.count == 64)
        #expect(hash == hash.lowercased())
        // Verify all characters are hex digits (0-9, a-f)
        let nonHex = hash.unicodeScalars.contains { !CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
        #expect(!nonHex)
    }

    // MARK: - Stability

    @Test("Hash is stable across calls")
    func hashStable() {
        let src = source()
        let first = SendPayload.build(src, for: .obsidian, timeZone: timeZone)
        let second = SendPayload.build(src, for: .obsidian, timeZone: timeZone)
        #expect(first.contentHash == second.contentHash)
    }

    // MARK: - Changes

    @Test("Hash changes when title changes")
    func hashChangesTitle() {
        let first = SendPayload.build(source(title: "A"), for: .obsidian, timeZone: timeZone)
        let second = SendPayload.build(source(title: "B"), for: .obsidian, timeZone: timeZone)
        #expect(first.contentHash != second.contentHash)
    }

    @Test("Hash changes when summary changes")
    func hashChangesSummary() {
        let first = SendPayload.build(source(summary: "A"), for: .obsidian, timeZone: timeZone)
        let second = SendPayload.build(source(summary: "B"), for: .obsidian, timeZone: timeZone)
        #expect(first.contentHash != second.contentHash)
    }

    @Test("Hash changes when notes change")
    func hashChangesNotes() {
        let first = SendPayload.build(source(notes: "A"), for: .obsidian, timeZone: timeZone)
        let second = SendPayload.build(source(notes: "B"), for: .obsidian, timeZone: timeZone)
        #expect(first.contentHash != second.contentHash)
    }

    @Test("Hash changes when tags change")
    func hashChangesTags() {
        let first = SendPayload.build(source(tags: ["x"]), for: .obsidian, timeZone: timeZone)
        let second = SendPayload.build(source(tags: ["y"]), for: .obsidian, timeZone: timeZone)
        #expect(first.contentHash != second.contentHash)
    }

    // MARK: - Cross-destination

    @Test("Hash differs between destinations for the same source")
    func hashDiffersBetweenDestinations() {
        let src = source()
        let obsidian = SendPayload.build(src, for: .obsidian, timeZone: timeZone)
        let bear = SendPayload.build(src, for: .bear, timeZone: timeZone)
        let notes = SendPayload.build(src, for: .appleNotes, timeZone: timeZone)
        #expect(obsidian.contentHash != bear.contentHash)
        #expect(bear.contentHash != notes.contentHash)
        #expect(obsidian.contentHash != notes.contentHash)
    }

    // MARK: - Markdown assembly

    @Test("Obsidian payload includes frontmatter before body")
    func obsidianIncludesFrontmatter() {
        let payload = SendPayload.build(source(), for: .obsidian, timeZone: timeZone)
        #expect(payload.markdown.hasPrefix("---\n"))
        #expect(payload.markdown.contains("# Weekly Sync"))
    }

    @Test("Bear payload is the plain body")
    func bearIsPlainBody() {
        let payload = SendPayload.build(source(), for: .bear, timeZone: timeZone)
        #expect(payload.markdown.hasPrefix("# Weekly Sync"))
        #expect(!payload.markdown.contains("---"))
    }

    @Test("Apple Notes payload includes tag footer")
    func notesIncludesFooter() {
        let payload = SendPayload.build(source(), for: .appleNotes, timeZone: timeZone)
        #expect(payload.markdown.contains("#biscotti"))
        #expect(payload.markdown.hasSuffix("\n"))
    }
}

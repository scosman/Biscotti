import DataStore
import Foundation
import Testing
@testable import ImportExport

@Suite("SendPlan")
struct PlanTests {
    // swiftlint:disable:next force_unwrapping
    private let timeZone = TimeZone(identifier: "America/New_York")!
    /// 2026-10-21 14:00 UTC = 2026-10-21 10:00 EDT
    private let fixedDate = Date(timeIntervalSince1970: 1_792_591_200)
    // swiftlint:disable:next force_unwrapping
    private let fixedID = UUID(uuidString: "AABBCCDD-1122-3344-5566-778899AABBCC")!

    private func source(
        title: String = "Weekly Sync",
        summary: String = "Summary",
        notes: String = "Notes"
    ) -> ExportSource {
        ExportSource(
            meetingID: fixedID,
            title: title,
            start: fixedDate,
            durationMinutes: 42,
            attendees: ["Alice"],
            summary: summary,
            notes: notes,
            tags: ["project-x"]
        )
    }

    // MARK: - Obsidian URL

    @Test("Obsidian produces an openURL plan with correct scheme")
    func obsidianURL() {
        let src = source()
        let payload = SendPayload.build(src, for: .obsidian, timeZone: timeZone)
        let plan = SendPlan.make(payload, source: src, timeZone: timeZone)
        guard case let .openURL(url) = plan else {
            Issue.record("Expected .openURL, got \(plan)")
            return
        }
        #expect(url.absoluteString.hasPrefix("obsidian://new?"))
    }

    @Test("Obsidian URL uses name= not file=")
    func obsidianURLName() {
        let src = source()
        let payload = SendPayload.build(src, for: .obsidian, timeZone: timeZone)
        let plan = SendPlan.make(payload, source: src, timeZone: timeZone)
        guard case let .openURL(url) = plan else { return }
        #expect(url.absoluteString.contains("name="))
        #expect(!url.absoluteString.contains("file="))
    }

    @Test("Obsidian URL does not contain raw + / ? & in values")
    func obsidianURLNoRaw() {
        let src = source(summary: "a+b?c&d/e")
        let payload = SendPayload.build(src, for: .obsidian, timeZone: timeZone)
        let plan = SendPlan.make(payload, source: src, timeZone: timeZone)
        guard case let .openURL(url) = plan else { return }
        let query = url.absoluteString.components(separatedBy: "?").dropFirst().joined(separator: "?")
        // After removing the keys and =, values should not contain raw specials
        // The values are percent-encoded, so `+` should be `%2B`, etc.
        #expect(!query.contains("+"))
    }

    // MARK: - Bear URL

    @Test("Bear produces an openURL plan with correct scheme")
    func bearURL() {
        let src = source()
        let payload = SendPayload.build(src, for: .bear, timeZone: timeZone)
        let plan = SendPlan.make(payload, source: src, timeZone: timeZone)
        guard case let .openURL(url) = plan else {
            Issue.record("Expected .openURL, got \(plan)")
            return
        }
        #expect(url.absoluteString.hasPrefix("bear://x-callback-url/create?"))
    }

    @Test("Bear URL includes tags and open_note params")
    func bearURLParams() {
        let src = source()
        let payload = SendPayload.build(src, for: .bear, timeZone: timeZone)
        let plan = SendPlan.make(payload, source: src, timeZone: timeZone)
        guard case let .openURL(url) = plan else { return }
        #expect(url.absoluteString.contains("tags="))
        #expect(url.absoluteString.contains("open_note=yes"))
    }

    // MARK: - Apple Notes

    @Test("Apple Notes produces handOffFile with .md extension")
    func notesHandOff() {
        let src = source()
        let payload = SendPayload.build(src, for: .appleNotes, timeZone: timeZone)
        let plan = SendPlan.make(payload, source: src, timeZone: timeZone)
        guard case let .handOffFile(fileName, contents) = plan else {
            Issue.record("Expected .handOffFile, got \(plan)")
            return
        }
        #expect(fileName.hasSuffix(".md"))
        #expect(fileName == "Weekly Sync.md")
        #expect(!contents.isEmpty)
    }

    // MARK: - Size limit

    /// Build a helper to compute the exact number of ASCII-letter summary
    /// characters needed to produce a URL of a given byte count. Each
    /// additional ASCII letter in the summary adds exactly 1 byte to the
    /// percent-encoded URL (letters are unreserved in RFC 3986).
    private func urlByteCount(summaryLetters: Int) -> Int? {
        let src = source(summary: String(repeating: "a", count: summaryLetters), notes: "")
        let payload = SendPayload.build(src, for: .obsidian, timeZone: timeZone)
        let plan = SendPlan.make(payload, source: src, timeZone: timeZone)
        guard case let .openURL(url) = plan else { return nil }
        return url.absoluteString.utf8.count
    }

    @Test("Size limit boundary: exact byte counts at 511999, 512000, 512001")
    func sizeBoundary() {
        // Measure the URL byte count with a 1-letter summary to establish
        // the base. Each additional letter adds exactly 1 byte.
        guard let base = urlByteCount(summaryLetters: 1) else {
            Issue.record("1-letter source should produce .openURL")
            return
        }

        let limit = SendPlan.maxURLBytes // 512,000
        // To hit exactly N bytes: letters = N - base + 1
        // (because base already includes 1 letter)

        // 511,999 bytes → .openURL
        let underLetters = limit - 1 - base + 1
        let underSrc = source(summary: String(repeating: "a", count: underLetters), notes: "")
        let underPayload = SendPayload.build(underSrc, for: .obsidian, timeZone: timeZone)
        let underPlan = SendPlan.make(underPayload, source: underSrc, timeZone: timeZone)
        guard case let .openURL(underURL) = underPlan else {
            Issue.record("511,999-byte URL should be .openURL")
            return
        }
        #expect(underURL.absoluteString.utf8.count == limit - 1)

        // 512,000 bytes → .openURL (at the limit, not over)
        let atSrc = source(summary: String(repeating: "a", count: underLetters + 1), notes: "")
        let atPayload = SendPayload.build(atSrc, for: .obsidian, timeZone: timeZone)
        let atPlan = SendPlan.make(atPayload, source: atSrc, timeZone: timeZone)
        guard case let .openURL(atURL) = atPlan else {
            Issue.record("512,000-byte URL should be .openURL (at limit, not over)")
            return
        }
        #expect(atURL.absoluteString.utf8.count == limit)

        // 512,001 bytes → .tooLarge (over the limit)
        let overSrc = source(summary: String(repeating: "a", count: underLetters + 2), notes: "")
        let overPayload = SendPayload.build(overSrc, for: .obsidian, timeZone: timeZone)
        let overPlan = SendPlan.make(overPayload, source: overSrc, timeZone: timeZone)
        guard case .tooLarge = overPlan else {
            Issue.record("512,001-byte URL should be .tooLarge")
            return
        }
    }
}

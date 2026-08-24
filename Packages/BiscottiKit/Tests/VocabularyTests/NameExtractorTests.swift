import Testing
@testable import Vocabulary

@Suite("NameExtractor")
struct NameExtractorTests {
    @Test("Extracts first whitespace-separated token from names")
    func firstTokenExtracted() {
        let result = NameExtractor.firstNames(
            from: ["Alice Smith", "Bob Jones", "Charlie Brown"],
            rawInviteeCount: 3
        )
        #expect(result == ["Alice", "Bob", "Charlie"])
    }

    @Test("21 invitees returns empty (exceeds cap)")
    func inviteeCapExcludesNames() {
        let names = (1 ... 21).map { "Person\($0)" }
        let result = NameExtractor.firstNames(from: names, rawInviteeCount: 21)
        #expect(result.isEmpty)
    }

    @Test("20 invitees includes names (at cap)")
    func inviteeCapIncludesNames() {
        let names = (1 ... 20).map { "Person\($0)" }
        let result = NameExtractor.firstNames(from: names, rawInviteeCount: 20)
        #expect(result.count == 20)
    }

    @Test("Empty and whitespace-only names are skipped")
    func emptyNamesSkipped() {
        let result = NameExtractor.firstNames(
            from: ["", "   ", "Alice Smith"],
            rawInviteeCount: 3
        )
        #expect(result == ["Alice"])
    }

    @Test("Single-character first names are skipped")
    func shortNamesSkipped() {
        let result = NameExtractor.firstNames(
            from: ["A. Smith", "Al Jones"],
            rawInviteeCount: 2
        )
        // "A." → strip punctuation → "A" → 1 char → skipped
        // "Al" → 2 chars → kept
        #expect(result == ["Al"])
    }

    @Test("Trailing punctuation is stripped")
    func trailingPunctuationStripped() {
        let result = NameExtractor.firstNames(
            from: ["Alice.", "Bob,", "Charlie.,"],
            rawInviteeCount: 3
        )
        #expect(result == ["Alice", "Bob", "Charlie"])
    }

    @Test("All-caps name is lowercased per person, not globally")
    func allCapsNameLowercased() {
        let result = NameExtractor.firstNames(
            from: ["JOHN DOE", "Alice Smith"],
            rawInviteeCount: 2
        )
        // JOHN DOE is all-caps → "john"; Alice Smith is not → "Alice"
        #expect(result == ["john", "Alice"])
    }

    @Test("Name with only punctuation after stripping is skipped if too short")
    func punctuationOnlySkipped() {
        let result = NameExtractor.firstNames(
            from: [".,"],
            rawInviteeCount: 1
        )
        #expect(result.isEmpty)
    }

    @Test("Single-word name is still extracted")
    func singleWordName() {
        let result = NameExtractor.firstNames(
            from: ["Madonna"],
            rawInviteeCount: 1
        )
        #expect(result == ["Madonna"])
    }

    @Test("rawInviteeCount is checked, not the names array length")
    func rawCountVsArrayLength() {
        // 3 names passed but rawInviteeCount says 25 → over cap
        let result = NameExtractor.firstNames(
            from: ["Alice", "Bob", "Charlie"],
            rawInviteeCount: 25
        )
        #expect(result.isEmpty)
    }
}

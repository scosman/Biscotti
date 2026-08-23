import Foundation
import Testing
@testable import Vocabulary

@Suite("CommonWordList")
struct CommonWordListTests {
    @Test("Known common words are filtered out")
    func knownCommonWordsAreFiltered() throws {
        let candidates: Set = ["meeting", "project", "team", "report"]
        let result = try CommonWordList.uncommon(from: candidates)
        #expect(result.isEmpty, "All common words should be filtered")
    }

    @Test("Rare word is returned as uncommon")
    func rareWordIsReturned() throws {
        let candidates: Set = ["parakeet"]
        let result = try CommonWordList.uncommon(from: candidates)
        #expect(result.contains("parakeet"))
    }

    @Test("Mixed common and uncommon words")
    func mixedWords() throws {
        let candidates: Set = ["meeting", "parakeet", "project"]
        let result = try CommonWordList.uncommon(from: candidates)
        #expect(result == ["parakeet"])
    }

    @Test("Fully common candidates return empty set")
    func fullyCommonCandidatesReturnEmpty() throws {
        let candidates: Set = ["the", "and", "for", "with", "from"]
        let result = try CommonWordList.uncommon(from: candidates)
        #expect(result.isEmpty)
    }

    @Test("Empty candidates return empty set")
    func emptyCandidatesReturnEmpty() throws {
        let result = try CommonWordList.uncommon(from: [])
        #expect(result.isEmpty)
    }

    @Test("Parakeet is absent from the generated list (spec verification)")
    func parakeetAbsentFromList() throws {
        // If parakeet were in the common list, uncommon(from:) would return
        // an empty set. It should return {"parakeet"}.
        let result = try CommonWordList.uncommon(from: ["parakeet"])
        #expect(result.contains("parakeet"), "'parakeet' must not be in the common word list")
    }

    @Test("uncommonFilter returns a working closure")
    func uncommonFilterWorks() {
        let filter = CommonWordList.uncommonFilter(
            logger: .init(subsystem: "test", category: "test")
        )
        let result = filter(["parakeet", "meeting"])
        #expect(result.contains("parakeet"))
        #expect(!result.contains("meeting"))
    }

    @Test("The bundled word list loads and contains common English words")
    func wordListLoadsAndContainsCommonWords() throws {
        // Verifying indirectly: if the list were empty or missing, every
        // candidate would be returned as uncommon.
        let common: Set = [
            "meeting", "project", "team", "report", "work",
            "time", "people", "company", "data", "system"
        ]
        let result = try CommonWordList.uncommon(from: common)
        #expect(result.isEmpty, "All 10 common English words should be in the list")
    }

    @Test("The bundled word list is non-empty and sorted")
    func fileIsNonEmptyAndSorted() throws {
        guard let url = Bundle.module.url(forResource: "common_words_en", withExtension: "txt") else {
            Issue.record("common_words_en.txt resource is missing")
            return
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        #expect(!lines.isEmpty, "Word list must not be empty")

        for idx in 1 ..< lines.count {
            #expect(
                lines[idx - 1] <= lines[idx],
                "Lines out of order at index \(idx): \"\(lines[idx - 1])\" > \"\(lines[idx])\""
            )
        }
    }
}

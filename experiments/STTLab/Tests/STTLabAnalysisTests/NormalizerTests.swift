import Testing
@testable import STTLabAnalysis

@Suite("Normalizer")
struct NormalizerTests {

    func norm(_ text: String) -> [String] {
        let words = [EngineWord(text: text, segmentIndex: 0)]
        return Normalizer.tokens(for: words).map(\.text)
    }

    @Test("NFKC normalization")
    func nfkc() {
        // The fi ligature (U+FB01) decomposes to "fi" under NFKC.
        #expect(norm("\u{FB01}nish") == ["finish"])
    }

    @Test("Lowercase")
    func lowercase() {
        #expect(norm("Hello") == ["hello"])
        #expect(norm("WORLD") == ["world"])
    }

    @Test("Apostrophe normalization")
    func apostrophes() {
        // Right single quote -> apostrophe, then contraction expanded.
        #expect(norm("don\u{2019}t") == ["do", "not"])
    }

    @Test("Symbol: percent")
    func percent() {
        #expect(norm("50%") == ["fifty", "percent"])
    }

    @Test("Symbol: ampersand")
    func ampersand() {
        #expect(norm("Q&A") == ["q", "and", "a"])
    }

    @Test("Symbol: dollar")
    func dollar() {
        #expect(norm("$100") == ["one", "hundred", "dollars"])
    }

    @Test("Symbol: plus")
    func plus() {
        #expect(norm("A+B") == ["a", "plus", "b"])
    }

    @Test("Hyphen splitting")
    func hyphen() {
        #expect(norm("well-known") == ["well", "known"])
    }

    @Test("Em dash splitting")
    func emDash() {
        #expect(norm("hello\u{2014}world") == ["hello", "world"])
    }

    @Test("Slash splitting")
    func slash() {
        #expect(norm("yes/no") == ["yes", "no"])
    }

    @Test("Strip non-letter/digit/apostrophe characters")
    func stripSymbols() {
        #expect(norm("hello!") == ["hello"])
        #expect(norm("(test)") == ["test"])
    }

    @Test("Contraction expansion")
    func contractions() {
        #expect(norm("I'm") == ["i", "am"])
        #expect(norm("can't") == ["can", "not"])
        #expect(norm("won't") == ["will", "not"])
        #expect(norm("gonna") == ["going", "to"])
        #expect(norm("okay") == ["ok"])
    }

    @Test("Possessive removal")
    func possessive() {
        #expect(norm("John's") == ["john"])
    }

    @Test("Number spell-out")
    func numbers() {
        #expect(norm("42") == ["forty", "two"])
        #expect(norm("1000") == ["one", "thousand"])
    }

    @Test("Ordinal spell-out")
    func ordinals() {
        #expect(norm("1st") == ["first"])
        #expect(norm("2nd") == ["second"])
        #expect(norm("3rd") == ["third"])
        #expect(norm("21st") == ["twenty", "first"])
    }

    @Test("Decimal expansion")
    func decimals() {
        #expect(norm("3.5") == ["three", "point", "five"])
    }

    @Test("Filler removal")
    func fillers() {
        let words = [
            EngineWord(text: "um", segmentIndex: 0),
            EngineWord(text: "hello", segmentIndex: 0),
            EngineWord(text: "uh", segmentIndex: 0),
        ]
        let tokens = Normalizer.tokens(for: words)
        #expect(tokens.map(\.text) == ["hello"])
    }

    @Test("Source index preservation")
    func sourceIndex() {
        let words = [
            EngineWord(text: "don't", segmentIndex: 0),
            EngineWord(text: "stop", segmentIndex: 0),
        ]
        let tokens = Normalizer.tokens(for: words)
        // "don't" expands to ["do", "not"], both with sourceIndex 0.
        // "stop" keeps sourceIndex 1.
        #expect(tokens.count == 3)
        #expect(tokens[0].sourceIndex == 0)
        #expect(tokens[1].sourceIndex == 0)
        #expect(tokens[2].sourceIndex == 1)
    }

    @Test("Comma-separated numbers: 1,000 becomes 1000 via stripping")
    func commaNumbers() {
        // After step 4, comma is stripped, so "1,000" -> "1000" -> spelled out.
        #expect(norm("1,000") == ["one", "thousand"])
    }
}

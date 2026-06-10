import Testing

@Suite("TextNormalize")
struct TextNormalizeTests {
    // MARK: - normalize

    @Test("lowercases text")
    func lowercases() {
        #expect(TextNormalize.normalize("Hello WORLD") == "hello world")
    }

    @Test("trims leading and trailing whitespace")
    func trims() {
        #expect(TextNormalize.normalize("  hello  ") == "hello")
    }

    @Test("collapses internal whitespace to single space")
    func collapsesWhitespace() {
        #expect(TextNormalize.normalize("hello    world") == "hello world")
    }

    @Test("strips punctuation characters")
    func stripsPunctuation() {
        #expect(TextNormalize.normalize("Hello, world! It's a \"test\".") == "hello world its a test")
    }

    @Test("handles all specified punctuation marks")
    func allPunctuation() {
        // . , ! ? ' " : ;
        #expect(TextNormalize.normalize("a.b,c!d?e'f\"g:h;i") == "abcdefghi")
    }

    @Test("empty string returns empty")
    func emptyString() {
        #expect(TextNormalize.normalize("") == "")
    }

    @Test("whitespace-only string returns empty")
    func whitespaceOnly() {
        #expect(TextNormalize.normalize("   ") == "")
    }

    @Test("combined normalization: lowercase + trim + collapse + strip")
    func combined() {
        let input = "  Hello,   I'm person NUMBER  two!  "
        #expect(TextNormalize.normalize(input) == "hello im person number two")
    }

    // MARK: - words

    @Test("splits normalized text into words")
    func wordsBasic() {
        #expect(TextNormalize.words("Hello, world!") == ["hello", "world"])
    }

    @Test("words from empty string returns empty array")
    func wordsEmpty() {
        #expect(TextNormalize.words("").isEmpty)
    }

    @Test("words handles single word")
    func wordsSingle() {
        #expect(TextNormalize.words("Hello") == ["hello"])
    }

    @Test("words strips punctuation before splitting")
    func wordsWithPunctuation() {
        #expect(TextNormalize.words("NASA, Kubernetes; Postgres!") == ["nasa", "kubernetes", "postgres"])
    }
}

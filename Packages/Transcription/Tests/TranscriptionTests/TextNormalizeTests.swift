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

    @Test("words splits on slash separators")
    func wordsWithSlash() {
        // The model emits "NASA/Kubernetes" when asked to say the two as a
        // list. Both terms must stay visible to the word matcher.
        #expect(TextNormalize.words("NASA/Kubernetes, Postgres.") == ["nasa", "kubernetes", "postgres"])
    }

    @Test("words does not split on hyphens")
    func wordsKeepsHyphens() {
        // Splitting here would let a mis-transcribed "Llama-ish" count as a
        // match for "Llama", masking the failure this evaluator exists to catch.
        #expect(TextNormalize.words("Llama-ish") == ["llama-ish"])
    }

    @Test("words collapses repeated slash separators")
    func wordsRepeatedSlashes() {
        #expect(TextNormalize.words("NASA//Kubernetes") == ["nasa", "kubernetes"])
    }
}

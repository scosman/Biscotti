import Testing

@Suite("WordMatch")
struct WordMatchTests {
    @Test("all terms present")
    func allPresent() {
        let transcript = "NASA Kubernetes Postgres"
        let expected = ["NASA", "Kubernetes", "Postgres"]
        let result = WordMatch.evaluate(transcript: transcript, expected: expected)
        #expect(result.matched == ["NASA", "Kubernetes", "Postgres"])
        #expect(result.missed.isEmpty)
    }

    @Test("no terms present")
    func nonePresent() {
        let transcript = "hello world nothing here"
        let expected = ["NASA", "Kubernetes"]
        let result = WordMatch.evaluate(transcript: transcript, expected: expected)
        #expect(result.matched.isEmpty)
        #expect(result.missed == ["NASA", "Kubernetes"])
    }

    @Test("partial match")
    func partialMatch() {
        let transcript = "NASA is great but not Postgres"
        let expected = ["NASA", "Kubernetes", "Postgres"]
        let result = WordMatch.evaluate(transcript: transcript, expected: expected)
        #expect(result.matched == ["NASA", "Postgres"])
        #expect(result.missed == ["Kubernetes"])
    }

    @Test("case insensitive matching")
    func caseInsensitive() {
        let transcript = "nasa kubernetes postgres"
        let expected = ["NASA", "Kubernetes", "Postgres"]
        let result = WordMatch.evaluate(transcript: transcript, expected: expected)
        #expect(result.matched == ["NASA", "Kubernetes", "Postgres"])
        #expect(result.missed.isEmpty)
    }

    @Test("punctuation stripped before matching")
    func punctuationStripped() {
        let transcript = "NASA, Kubernetes; Postgres!"
        let expected = ["NASA", "Kubernetes", "Postgres"]
        let result = WordMatch.evaluate(transcript: transcript, expected: expected)
        #expect(result.matched == ["NASA", "Kubernetes", "Postgres"])
    }

    @Test("empty transcript matches nothing")
    func emptyTranscript() {
        let result = WordMatch.evaluate(transcript: "", expected: ["NASA"])
        #expect(result.matched.isEmpty)
        #expect(result.missed == ["NASA"])
    }

    @Test("empty expected list produces empty results")
    func emptyExpected() {
        let result = WordMatch.evaluate(transcript: "NASA Kubernetes", expected: [])
        #expect(result.matched.isEmpty)
        #expect(result.missed.isEmpty)
    }

    @Test("full vocab terms test")
    func fullVocabTerms() {
        let transcript = "NASA Kubernetes Postgres Qwen Mistral Llama Croissant gnocci Paella Facade"
        let result = WordMatch.evaluate(
            transcript: transcript, expected: GroundTruth.vocabTerms
        )
        #expect(result.matched.count == 10)
        #expect(result.missed.isEmpty)
    }
}

import Testing
@testable import STTLabAnalysis

@Suite("TextQuality")
struct TextQualityTests {

    func makeWords(_ texts: [String]) -> [EngineWord] {
        texts.map { EngineWord(text: $0, segmentIndex: 0) }
    }

    @Test("Punctuation count per 100 words")
    func punctuationCount() {
        let words = makeWords(["Hello,", "world.", "How", "are", "you?"])
        let result = TextQuality.compute(displayText: "Hello, world. How are you?", words: words)
        // 3 punctuation marks (comma, period, question mark), 5 words => 60 per 100.
        #expect(result.punctuationPer100Words != nil)
        #expect(abs(result.punctuationPer100Words! - 60.0) < 0.001)
    }

    @Test("Sentence count")
    func sentenceCount() {
        let words = makeWords(["Hello.", "World.", "Done"])
        let result = TextQuality.compute(displayText: "Hello. World. Done", words: words)
        // Two sentences ending with "." plus one trailing without ender = 3.
        #expect(result.sentenceCount == 3)
    }

    @Test("Sentence start capitalization")
    func sentenceStartCap() {
        let words = makeWords(["Hello.", "world.", "Done"])
        let result = TextQuality.compute(displayText: "Hello. world. Done", words: words)
        // 3 sentences: "Hello." (cap), "world." (not cap), "Done" (cap).
        // 2/3 capitalized.
        #expect(result.sentenceStartCapitalizedShare != nil)
        #expect(abs(result.sentenceStartCapitalizedShare! - 2.0 / 3.0) < 0.001)
    }

    @Test("Mid-sentence capitalization excludes I")
    func midSentenceCap() {
        let words = makeWords(["Hello", "I", "am", "Bob", "today."])
        let result = TextQuality.compute(displayText: "Hello I am Bob today.", words: words)
        // Mid-sentence words (excluding first): "I" (excluded), "am" (lower), "Bob" (upper),
        // "today." (lower).
        // 1 capitalized / 3 total.
        #expect(result.midSentenceCapitalizedShare != nil)
        #expect(abs(result.midSentenceCapitalizedShare! - 1.0 / 3.0) < 0.001)
    }

    @Test("Filler word counting")
    func fillerCounting() {
        let words = makeWords(["um", "hello", "uh", "world", "um"])
        let result = TextQuality.compute(displayText: "um hello uh world um", words: words)
        #expect(result.fillerTotal == 3)
        #expect(result.fillerCounts["um"] == 2)
        #expect(result.fillerCounts["uh"] == 1)
        #expect(result.fillerPer1000Words != nil)
        // 3/5 * 1000 = 600.
        #expect(abs(result.fillerPer1000Words! - 600.0) < 0.001)
    }

    @Test("Zero words returns nil rates")
    func zeroWords() {
        let result = TextQuality.compute(displayText: "", words: [])
        #expect(result.punctuationPer100Words == nil)
        #expect(result.fillerPer1000Words == nil)
    }
}

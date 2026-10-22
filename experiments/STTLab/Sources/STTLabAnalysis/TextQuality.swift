import Foundation

/// Text-quality metrics for one engine's output.
public struct TextQualityResult: Codable, Sendable, Equatable {
    public var wordCount: Int
    public var punctuationPer100Words: Double?
    public var sentenceCount: Int
    public var sentenceStartCapitalizedShare: Double?
    public var midSentenceCapitalizedShare: Double?
    public var fillerCounts: [String: Int]
    public var fillerTotal: Int
    public var fillerPer1000Words: Double?

    public init(wordCount: Int, punctuationPer100Words: Double?,
                sentenceCount: Int, sentenceStartCapitalizedShare: Double?,
                midSentenceCapitalizedShare: Double?,
                fillerCounts: [String: Int], fillerTotal: Int,
                fillerPer1000Words: Double?) {
        self.wordCount = wordCount
        self.punctuationPer100Words = punctuationPer100Words
        self.sentenceCount = sentenceCount
        self.sentenceStartCapitalizedShare = sentenceStartCapitalizedShare
        self.midSentenceCapitalizedShare = midSentenceCapitalizedShare
        self.fillerCounts = fillerCounts
        self.fillerTotal = fillerTotal
        self.fillerPer1000Words = fillerPer1000Words
    }
}

/// Computes text-quality metrics on an engine's display text and words.
public enum TextQuality {

    /// The punctuation marks to count.
    static let punctuationMarks: Set<Character> = [".", ",", "?", "!", ";", ":", "\u{2026}"]

    /// Compute text quality metrics.
    public static func compute(displayText: String, words: [EngineWord]) -> TextQualityResult {
        let wordCount = words.count

        // Punctuation count on display text.
        let punctCount = displayText.filter { punctuationMarks.contains($0) }.count
        let punctPer100 = wordCount > 0 ? Double(punctCount) / Double(wordCount) * 100 : nil

        // Sentence detection: runs of text ended by sentence-ending punctuation.
        let sentences = detectSentences(words)

        // Sentence start capitalization.
        let sentenceStartCap = capitalizationAtSentenceStarts(sentences)

        // Mid-sentence capitalization.
        let midSentenceCap = midSentenceCapitalization(sentences)

        // Filler word counts on lowercased words stripped of punctuation.
        let (fillerCounts, fillerTotal) = countFillers(words)
        let fillerRate = wordCount > 0 ? Double(fillerTotal) / Double(wordCount) * 1000 : nil

        return TextQualityResult(
            wordCount: wordCount,
            punctuationPer100Words: punctPer100,
            sentenceCount: sentences.count,
            sentenceStartCapitalizedShare: sentenceStartCap,
            midSentenceCapitalizedShare: midSentenceCap,
            fillerCounts: fillerCounts,
            fillerTotal: fillerTotal,
            fillerPer1000Words: fillerRate
        )
    }

    // MARK: - Sentence detection

    /// Sentence-ending characters.
    static let sentenceEnders: Set<Character> = [".", "?", "!", "\u{2026}"]

    /// A sentence is a run of words; a sentence ends when a word's text ends
    /// with a sentence-ending mark.
    struct Sentence {
        var words: [EngineWord]
    }

    static func detectSentences(_ words: [EngineWord]) -> [Sentence] {
        var sentences: [Sentence] = []
        var current: [EngineWord] = []

        for word in words {
            current.append(word)
            if let last = word.text.last, sentenceEnders.contains(last) {
                sentences.append(Sentence(words: current))
                current = []
            }
        }

        // Trailing words without a sentence ender form a final sentence.
        if !current.isEmpty {
            sentences.append(Sentence(words: current))
        }

        return sentences
    }

    // MARK: - Capitalization

    /// Share of sentence-first words that start with a capital letter.
    static func capitalizationAtSentenceStarts(_ sentences: [Sentence]) -> Double? {
        var total = 0
        var capitalized = 0

        for sentence in sentences {
            guard let first = sentence.words.first else { continue }
            guard let firstChar = first.text.first, firstChar.isLetter else { continue }
            total += 1
            if firstChar.isUppercase { capitalized += 1 }
        }

        return total > 0 ? Double(capitalized) / Double(total) : nil
    }

    /// Share of mid-sentence words that start with a capital letter,
    /// excluding "I" and its contractions.
    static let iExclusions: Set<String> = ["I", "I'm", "I've", "I'll", "I'd"]

    static func midSentenceCapitalization(_ sentences: [Sentence]) -> Double? {
        var total = 0
        var capitalized = 0

        for sentence in sentences {
            // Skip the first word (it is a sentence start).
            for word in sentence.words.dropFirst() {
                guard let firstChar = word.text.first, firstChar.isLetter else { continue }
                // Exclude I and its contractions.
                let stripped = stripPunctuation(word.text)
                if iExclusions.contains(stripped) { continue }
                total += 1
                if firstChar.isUppercase { capitalized += 1 }
            }
        }

        return total > 0 ? Double(capitalized) / Double(total) : nil
    }

    // MARK: - Filler counting

    static func countFillers(_ words: [EngineWord]) -> ([String: Int], Int) {
        var counts: [String: Int] = [:]
        var total = 0

        for word in words {
            let cleaned = stripPunctuation(word.text).lowercased()
            if Normalizer.fillers.contains(cleaned) {
                counts[cleaned, default: 0] += 1
                total += 1
            }
        }

        return (counts, total)
    }

    // MARK: - Helpers

    /// Strip leading and trailing punctuation from a word.
    static func stripPunctuation(_ text: String) -> String {
        var s = text
        while let first = s.first, !first.isLetter && !first.isNumber { s.removeFirst() }
        while let last = s.last, !last.isLetter && !last.isNumber { s.removeLast() }
        return s
    }
}

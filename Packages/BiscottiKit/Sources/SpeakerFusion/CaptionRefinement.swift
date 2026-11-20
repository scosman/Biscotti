import Foundation

// MARK: - Caption text as a second opinion on words

public extension CaptionAligner {
    /// Whisper words under this mean probability may be replaced.
    static let replaceBelow: Float = 0.6

    /// Replaces words Whisper wasn't sure of with the caption's words.
    ///
    /// Caption and transcript are lined up on the words they agree on. Between
    /// two agreed words, if Whisper's words there were low-confidence and the
    /// caption has different words, the caption's words take their place,
    /// spread over the same time and kept on the same voice. Words Whisper
    /// was confident of are never touched. Returns the new words and how many
    /// were replaced.
    static func refine(_ words: [FusionWord], captions: [CaptionLine], tuning: Tuning = Tuning()) -> (words: [FusionWord], replaced: Int) {
        var result = words
        var replaced = 0
        // Later captions first, so index ranges of earlier ones stay valid.
        for caption in captions.sorted(by: { $0.start > $1.start }) {
            let parts = captionWords(caption.text)
            guard parts.count >= tuning.minimumMatches else { continue }
            let window = result.indices.filter {
                result[$0].start >= caption.start - tuning.lead && result[$0].end <= caption.end + tuning.tail
                    && !normalize(result[$0].text).isEmpty
            }
            let pairs = commonPairs(parts.map(\.token), window.map { normalize(result[$0].text) })
            guard pairs.count >= tuning.minimumMatches,
                  Double(pairs.count) / Double(parts.count) >= tuning.minimumShare else { continue }
            for (left, right) in zip(pairs, pairs.dropFirst()).reversed() {
                let wordRange = (window[left.word] + 1) ..< window[right.word]
                let captionRange = (left.caption + 1) ..< right.caption
                guard let swap = replacement(
                    result[wordRange], with: captionRange.map { parts[$0].raw }
                ) else { continue }
                result.replaceSubrange(wordRange, with: swap)
                replaced += wordRange.count
            }
        }
        return (result, replaced)
    }

    /// The caption's words for a gap of low-confidence Whisper words, or nil
    /// to leave them alone.
    internal static func replacement(_ gap: ArraySlice<FusionWord>, with captionWords: [String]) -> [FusionWord]? {
        guard let first = gap.first, let last = gap.last, !captionWords.isEmpty,
              captionWords.count <= gap.count * 3 + 2 else { return nil }
        let mean = gap.reduce(Float(0)) { $0 + $1.probability } / Float(gap.count)
        guard mean < replaceBelow else { return nil }
        let start = first.start
        let step = max(last.end - start, 0.05) / Double(captionWords.count)
        return captionWords.enumerated().map { index, text in
            FusionWord(
                text: " " + text,
                start: start + Double(index) * step,
                end: start + Double(index + 1) * step,
                probability: replaceBelow,
                clusterID: first.clusterID
            )
        }
    }

    /// Caption words with their normalized form, empties dropped.
    internal static func captionWords(_ text: String) -> [(raw: String, token: String)] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
            .map { ($0, normalize($0)) }
            .filter { !$0.token.isEmpty }
    }

    /// Index pairs (caption, word) of the longest common subsequence.
    internal static func commonPairs(_ caption: [String], _ words: [String]) -> [(caption: Int, word: Int)] {
        guard !caption.isEmpty, !words.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: words.count + 1), count: caption.count + 1)
        for row in 1 ... caption.count {
            for column in 1 ... words.count {
                table[row][column] = caption[row - 1] == words[column - 1]
                    ? table[row - 1][column - 1] + 1
                    : max(table[row - 1][column], table[row][column - 1])
            }
        }
        var pairs: [(caption: Int, word: Int)] = []
        var row = caption.count
        var column = words.count
        while row > 0, column > 0 {
            if caption[row - 1] == words[column - 1] {
                pairs.append((row - 1, column - 1))
                row -= 1
                column -= 1
            } else if table[row - 1][column] >= table[row][column - 1] {
                row -= 1
            } else {
                column -= 1
            }
        }
        return pairs.reversed()
    }
}

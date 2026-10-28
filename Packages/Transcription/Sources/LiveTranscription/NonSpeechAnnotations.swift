import Foundation
import LiveTranscriptModel

/// Whisper's descriptions of sounds that are not speech: "[BLANK_AUDIO]",
/// "[typing]", "(laughs)", "*cough*", "♪". On the echo-cancelled mic track,
/// whisper-small wrote one for nearly every keyboard tap and cough, and a
/// decode that ended inside one let local agreement settle a fragment such as
/// "[BLANK" (hardware review, 25 October 2026). The final pass, large-v3 on
/// both tracks mixed, rarely writes them and keeps no filter.
enum NonSpeechAnnotations {
    /// A decode's words without annotations.
    struct Filtered: Equatable {
        var words: [TimedWord]
        /// Where an annotation starts that the decode's last words leave
        /// open. Its words are left out and must not settle: the caller
        /// holds back from here, so the next decode sees the whole of it.
        var openFrom: TimeInterval?
        /// With an annotation open, the words read as if its opener were
        /// stray: only the opener left out. For a decode that no later one
        /// can hear more than, such as one in silence or at Stop.
        var wordsWithoutOpener: [TimedWord]?
    }

    /// An opener with no closer within this many words or seconds is not an
    /// annotation: only the opener goes, so a stray "(" or "*" cannot take
    /// the rest of the decode with it.
    static let maxAnnotationWords = 6
    static let maxAnnotationDuration: TimeInterval = 3

    /// The character that ends an annotation, by the one that opens it.
    private static let closers: [Character: Character] = ["[": "]", "(": ")", "*": "*"]

    /// The words without annotations and without words made only of
    /// punctuation or symbols (a dash or dots left beside one, a music note).
    /// A lone combining mark, such as a Thai tone mark that WhisperKit splits
    /// into a word of its own, stays. An annotation still open at the
    /// decode's end is left out and reported in `openFrom`.
    /// TODO(live annotations): the stray reading can let a real annotation's
    /// inner words through, such as " Silence" from " [", " Silence", " ]"
    /// with the closer cut past the window's end. Keep dropping everything
    /// after "[", and read only "*" and "(" as stray.
    static func removed(from words: [TimedWord]) -> Filtered {
        let held = filter(words, openIsStray: false)
        guard held.openFrom != nil else { return held }
        return Filtered(words: held.words, openFrom: held.openFrom, wordsWithoutOpener: filter(words, openIsStray: true).words)
    }

    private static func filter(_ words: [TimedWord], openIsStray: Bool) -> Filtered {
        var kept: [TimedWord] = []
        var index = 0
        while index < words.count {
            let text = trimmed(words[index])
            if let first = text.first, let closer = closers[first], !text.dropFirst().contains(closer) {
                switch annotationEnd(openedAt: index, closer: closer, in: words) {
                case let .closed(end):
                    index = end + 1
                case .open where !openIsStray:
                    return Filtered(words: kept, openFrom: words[index].start)
                case .open, .tooLong:
                    index += 1
                }
                continue
            }
            let isAnnotation = text.first.map { closers[$0] != nil } ?? false
            let isPunctuationOrSymbols = text.allSatisfy { $0.isPunctuation || $0.isSymbol || $0.isWhitespace }
            if !isAnnotation, !isPunctuationOrSymbols {
                kept.append(words[index])
            }
            index += 1
        }
        return Filtered(words: kept, openFrom: nil)
    }

    private enum AnnotationEnd {
        /// Closed by the word at this index.
        case closed(Int)
        /// The decode ends first, within the limits.
        case open
        /// No closer within the limits.
        case tooLong
    }

    private static func annotationEnd(openedAt opener: Int, closer: Character, in words: [TimedWord]) -> AnnotationEnd {
        let start = words[opener].start
        for index in words.indices.dropFirst(opener + 1) {
            if index - opener > maxAnnotationWords || words[index].end - start > maxAnnotationDuration {
                return .tooLong
            }
            if trimmed(words[index]).contains(closer) {
                return .closed(index)
            }
        }
        return .open
    }

    private static func trimmed(_ word: TimedWord) -> String {
        word.text.trimmingCharacters(in: .whitespaces)
    }
}

import Foundation
import LiveTranscriptModel
import Testing
import WhisperKit
@testable import LiveTranscription

/// Words spaced 0.5 s apart, as a decode returns them.
private func words(_ texts: [String]) -> [TimedWord] {
    texts.enumerated().map { index, text in
        TimedWord(text: text, start: Double(index) * 0.5, end: Double(index) * 0.5 + 0.4)
    }
}

private func kept(_ texts: [String]) -> [String] {
    NonSpeechAnnotations.removed(from: words(texts)).words.map(\.text)
}

@Suite("Non-speech annotations in live decodes")
struct NonSpeechAnnotationsTests {
    @Test("Bracketed, parenthesized and asterisked annotations go; the real words of the row stay, with their times")
    func annotationsGoAndWordsStay() {
        let filtered = NonSpeechAnnotations.removed(from: words([" [COUGH]", " [coughing]", " Excuse", " me.", " (laughs)", " *cough*", " Right."]))

        #expect(filtered.words.map(\.text) == [" Excuse", " me.", " Right."])
        #expect(filtered.words.map(\.start) == [1, 1.5, 3])
        #expect(filtered.openFrom == nil)
    }

    @Test("An annotation the decode's last words leave open goes, and its start is reported so it does not settle")
    func openAnnotationIsReported() {
        let fragment = NonSpeechAnnotations.removed(from: words([" So", " [BLANK"]))
        #expect(fragment.words.map(\.text) == [" So"])
        #expect(fragment.openFrom == 0.5)
        #expect(fragment.wordsWithoutOpener?.map(\.text) == [" So"])

        #expect(NonSpeechAnnotations.removed(from: words([" ["])) == .init(words: [], openFrom: 0, wordsWithoutOpener: []))
        #expect(NonSpeechAnnotations.removed(from: words([" Well", " (", "laughs"])).openFrom == 0.5)
    }

    @Test("With a description open, the words read as if the opener were stray are there for a decode no later one can hear more than")
    func openAnnotationOffersTheStrayReading() {
        let filtered = NonSpeechAnnotations.removed(from: words([" Five", " *", " three", " is", " 15."]))

        #expect(filtered.words.map(\.text) == [" Five"])
        #expect(filtered.openFrom == 0.5)
        #expect(filtered.wordsWithoutOpener?.map(\.text) == [" Five", " three", " is", " 15."])
        #expect(NonSpeechAnnotations.removed(from: words([" Five", " three"])).wordsWithoutOpener == nil)
    }

    @Test("An annotation split across words goes whole, and the words after it stay")
    func splitAnnotationGoesWhole() {
        #expect(kept([" [BLANK", "_AUDIO]", " yes", " *", "cough", "*", " no"]) == [" yes", " no"])
        // "[ Silence ]" on the system track in the late-start run.
        #expect(kept([" [", " Silence", " ]", " Okay."]) == [" Okay."])
        #expect(kept([" [ Silence ]"]).isEmpty)
    }

    @Test("An opener with no closer within six words or 3 s is not an annotation: only the opener goes")
    func strayOpenerTakesOnlyItself() {
        #expect(kept([" Hello", " (", " and", " more", " words", " follow", " here", " now", " too"])
            == [" Hello", " and", " more", " words", " follow", " here", " now", " too"])
        let slow = [
            TimedWord(text: " Five", start: 0, end: 0.4),
            TimedWord(text: " *", start: 0.5, end: 0.6),
            TimedWord(text: " three", start: 1, end: 1.4),
            TimedWord(text: " is", start: 4, end: 4.2)
        ]
        let filtered = NonSpeechAnnotations.removed(from: slow)
        #expect(filtered.words.map(\.text) == [" Five", " three", " is"])
        #expect(filtered.openFrom == nil)
    }

    @Test("Words made only of punctuation or symbols go, such as a dash left beside an annotation or a music note; numbers stay")
    func punctuationAndSymbolWordsGo() {
        #expect(kept([" *cough*", " *cough*", " -", " Yeah.", " ♪", " 4.5", " euros", " ...", " —", " $"]) == [" Yeah.", " 4.5", " euros"])
    }

    @Test("Numbers, currency and combining marks stay: WhisperKit splits Thai into one word per token")
    func numbersAndCombiningMarksStay() {
        let decoded = words([" 2", " $5", " 50%", "ก", "\u{0E48}", "า"])
        #expect(NonSpeechAnnotations.removed(from: decoded).words.map(\.text) == [" 2", " $5", " 50%", "ก", "\u{0E48}", "า"])
    }

    @Test("The live decoder's words leave annotations out and report one left open")
    func decoderLeavesAnnotationsOut() {
        let timings = [" [typing]", " Okay.", " [BLANK"].enumerated().map { index, text in
            WordTiming(word: text, tokens: [], start: Float(index), end: Float(index) + 0.5, probability: 0.9)
        }
        let segment = TranscriptionSegment(avgLogprob: -0.2, noSpeechProb: 0.1, words: timings)

        let spoken = WhisperKitLiveDecoder.spokenWords(in: [segment], audioStart: 0, leadIn: 0, windowEnd: 5)

        #expect(spoken.words.map(\.text) == [" Okay."])
        #expect(spoken.openFrom == 2)
        #expect(spoken.wordsWithoutOpener?.map(\.text) == [" Okay."])
    }
}

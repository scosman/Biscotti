import Foundation
import Testing
@testable import LiveTranscriptModel

@Suite("LocalAgreementReducer prompt context")
struct LocalAgreementPromptTests {
    @Test("The prompt gets the last 100 characters of settled text before the window, from a word start")
    func settledTextBeforeTheWindowFeedsThePrompt() {
        var reducer = LocalAgreementReducer(track: .mic)
        let spoken = words(
            "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango",
            from: 0
        )
        _ = reducer.reduce(decode(spoken, window: 0 ... 10.5))
        _ = reducer.reduce(decode(spoken, window: 0 ... 10.5))

        #expect(reducer.settledText(before: 0).isEmpty)
        #expect(reducer.settledText(before: 5) == "alpha bravo charlie delta echo foxtrot golf hotel india juliet")
        let recent = "echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango"
        #expect(reducer.settledText(before: 10.5) == recent)

        _ = reducer.reduce(decode([], window: 10.5 ... 12))
        #expect(reducer.settledText(before: 10.5) == recent, "Pruning keeps enough words for the prompt")
    }

    @Test("Text without spaces still gets a prompt, cut at a word")
    func settledTextWithoutSpacesFeedsThePrompt() {
        var reducer = LocalAgreementReducer(track: .mic)
        let spoken = (0 ..< 120).map { TimedWord(text: "字", start: Double($0) * 0.1, end: Double($0) * 0.1 + 0.08) }
        _ = reducer.reduce(Hypothesis(words: spoken, windowStart: 0, windowEnd: 12.5))
        _ = reducer.reduce(Hypothesis(words: spoken, windowStart: 0, windowEnd: 12.5))
        #expect(reducer.settledText(before: 12.5) == String(repeating: "字", count: 100))
    }
}

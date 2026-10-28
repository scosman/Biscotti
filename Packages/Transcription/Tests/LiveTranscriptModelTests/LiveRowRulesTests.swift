import Foundation
import Testing
@testable import LiveTranscriptModel

/// The rules that close a row besides a pause: long rows end at a sentence
/// or a word, and the other track starting to speak ends the row there.
@Suite("Live rows in conversation order")
struct LiveRowRulesTests {
    /// Words 0.5 s apart from `start`, each 0.25 s long; the last one ends a sentence when asked.
    private static func phrase(_ count: Int, from start: TimeInterval, endingSentence: Bool = false) -> [TimedWord] {
        (0 ..< count).map { index in
            let wordStart = start + Double(index) * 0.5
            let text = " w\(index)" + (endingSentence && index == count - 1 ? "." : "")
            return TimedWord(text: text, start: wordStart, end: wordStart + 0.25)
        }
    }

    private static func settledRows(_ builder: inout LiveRowBuilder, _ words: [TimedWord]) -> RowLog {
        var log = RowLog()
        builder.settle(words)
        builder.setTail([])
        log.apply(builder.takeChanges(since: []))
        return log
    }

    @Test("A row closes at its first sentence end once it is 8 s long")
    func rowClosesAtSentenceEndAfterEightSeconds() {
        var builder = LiveRowBuilder(track: .system)
        // A sentence ends at 8.25 s, 8.25 s into the row; the next word starts a row.
        let words = Self.phrase(17, from: 0, endingSentence: true) + Self.phrase(3, from: 8.5)
        let log = Self.settledRows(&builder, words)

        #expect(log.rows.map(\.startTime) == [0, 8.5])
        #expect(log.rows.first?.settledText.hasSuffix("w16.") == true)
        #expect(log.rows.first?.isClosed == true)
    }

    @Test("A sentence end before 8 s keeps the row open")
    func rowStaysOpenBeforeEightSeconds() {
        var builder = LiveRowBuilder(track: .system)
        // The sentence ends at 7.75 s, 7.75 s into the row.
        let words = Self.phrase(16, from: 0, endingSentence: true) + Self.phrase(3, from: 8)
        let log = Self.settledRows(&builder, words)

        #expect(log.rows.map(\.startTime) == [0])
    }

    @Test("A row with no sentence end closes at a word once it is 20 s long")
    func rowClosesAtWordBoundaryAfterTwentySeconds() {
        var builder = LiveRowBuilder(track: .mic)
        // Word 40 ends at 20.25 s; word 41 starts the next row.
        let log = Self.settledRows(&builder, Self.phrase(50, from: 0))

        #expect(log.rows.map(\.startTime) == [0, 20.5])
        #expect(log.rows.first?.endTime == 20.25)
    }

    @Test("A break closes the row before the words from the break on")
    func breakClosesRowBeforeLaterWords() {
        var builder = LiveRowBuilder(track: .mic)
        var log = RowLog()
        builder.settle(words("a b c", from: 0))
        builder.setTail([])
        log.apply(builder.takeChanges(since: []))
        builder.breakRow(at: 1.2)
        builder.settle(words("d e", from: 1.5))
        builder.setTail([])
        log.apply(builder.takeChanges(since: []))

        #expect(log.settledText == "a b c | d e")
        #expect(log.rows.first?.isClosed == true)
    }

    @Test("A break moves the tail words after it to the tail's own row, which keeps its ID once settled")
    func breakSplitsTheTail() throws {
        var reducer = LocalAgreementReducer(track: .mic)
        var log = RowLog()
        let spoken = words("a b c d e", from: 0)
        log.apply(reducer.reduce(decode(Array(spoken.prefix(2)), window: 0 ... 1)))
        log.apply(reducer.reduce(decode(spoken, window: 0 ... 2.5)))
        let openID = try #require(log.rows.first?.id)

        log.apply(reducer.breakRow(at: 1.4))
        #expect(log.rows.map { $0.settledText + $0.tailText } == ["a b c", "d e"])
        let tailID = try #require(log.rows.last?.id)

        log.apply(reducer.finish())
        #expect(log.settledText == "a b c | d e")
        #expect(log.rows.map(\.id) == [openID, tailID])
    }

    @Test("A break before the row started changes nothing")
    func breakBeforeRowStartIsIgnored() {
        var builder = LiveRowBuilder(track: .mic)
        var log = RowLog()
        builder.settle(words("a", from: 5))
        builder.setTail([])
        log.apply(builder.takeChanges(since: []))
        builder.breakRow(at: 4)
        builder.settle(words("b c", from: 5.5))
        builder.setTail([])
        log.apply(builder.takeChanges(since: []))

        #expect(log.settledText == "a b c")
    }

    @Test("A break that comes before the row exists still splits it")
    func breakBeforeAnyRowAppliesToTheNextRow() {
        var builder = LiveRowBuilder(track: .mic)
        var log = RowLog()
        builder.breakRow(at: 1.2)
        builder.settle(words("a b c d", from: 0))
        builder.setTail([])
        log.apply(builder.takeChanges(since: []))

        #expect(log.settledText == "a b c | d")
    }

    @Test("Speech starts only after a pause, not where a long row splits")
    func speechStartIgnoresRuleSplits() {
        var builder = LiveRowBuilder(track: .system)
        builder.settle(Self.phrase(50, from: 3))
        builder.setTail([])
        #expect(builder.latestSpeechStart == 3, "The 20 s split is not new speech")

        builder.setTail(words("again", from: 30))
        #expect(builder.latestSpeechStart == 30, "A tail after a pause is new speech")
        builder.settle(words("x y", from: 30.5))
        builder.setTail([])
        #expect(builder.latestSpeechStart == 30.5, "A settled word after a pause is new speech")

        builder.breakRow(at: 31.4)
        builder.settle(words("z", from: 31.5))
        builder.setTail([])
        #expect(builder.latestSpeechStart == 30.5, "A row split by a break is not new speech")
    }

    @Test("Row IDs stay stable while a long row's tail splits off and settles")
    func rowIDsStayStableAcrossSplits() {
        var reducer = LocalAgreementReducer(track: .system)
        var log = RowLog()
        // A sentence ends 8.25 s into the row; the words after it show in a
        // row of their own while they are still tail.
        let spoken = Self.phrase(17, from: 0, endingSentence: true) + Self.phrase(4, from: 8.5)
        log.apply(reducer.reduce(decode(Array(spoken.prefix(17)), window: 0 ... 9)))
        log.apply(reducer.reduce(decode(spoken, window: 0 ... 10.5)))
        #expect(log.rows.count == 2)
        let ids = log.rows.map(\.id)

        log.apply(reducer.reduce(decode(spoken, window: 0 ... 11)))
        log.apply(reducer.finish())
        #expect(log.rows.map(\.id) == ids)
        #expect(log.rows.map(\.startTime) == [0, 8.5])
    }
}

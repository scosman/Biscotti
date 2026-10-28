import Foundation
import Testing
@testable import LiveTranscriptModel

@Suite("LocalAgreementReducer")
struct LocalAgreementReducerTests {
    // MARK: - Agreement

    @Test("The shared prefix of two decodes is committed; the rest is tail")
    func sharedPrefixOfTwoDecodesIsCommitted() throws {
        var reducer = LocalAgreementReducer(track: .mic)
        let first = reducer.reduce(decode(words("hello there my", from: 1), window: 0 ... 3))
        let firstRow = try #require(first.rows.first)
        #expect(first.rows.count == 1)
        #expect(firstRow.settledText.isEmpty)
        #expect(firstRow.tailText == "hello there my")

        let second = reducer.reduce(decode(words("hello there friend", from: 1), window: 0 ... 4))
        let row = try #require(second.rows.first)
        #expect(second.rows.count == 1)
        #expect(row.id == firstRow.id)
        #expect(row.track == .mic)
        #expect(row.settledText == "hello there")
        #expect(row.tailText == " friend")
        #expect(row.startTime == 1)
        #expect(row.endTime == 2.25)
        #expect(!row.isClosed)
        #expect(reducer.hasTail)
    }

    @Test("A catch-up word decoded again at a window boundary, its end slightly later, is committed once")
    func catchUpWordAtWindowBoundaryIsNotRepeated() throws {
        var reducer = LocalAgreementReducer(track: .mic)
        _ = reducer.commitCatchUp([word("so", 28, 28.3), word("yes", 28.6, 28.9)])
        let rows = reducer.commitCatchUp([word("yes", 28.62, 29.1), word("right", 29.5, 29.8)])

        let row = try #require(rows.last)
        #expect(row.settledText == "so yes right")
    }

    @Test("Decodes that disagree from the first word commit nothing")
    func disagreementCommitsNothing() throws {
        var reducer = LocalAgreementReducer(track: .system)
        _ = reducer.reduce(decode(words("hello there", from: 1), window: 0 ... 2))
        let result = reducer.reduce(decode(words("yellow there", from: 1), window: 0 ... 2.5))

        let row = try #require(result.rows.first)
        #expect(row.settledText.isEmpty)
        #expect(row.tailText == "yellow there")
        #expect(reducer.settledThrough == 0)
    }

    @Test("A phrase said twice is kept when a decode loses the first one")
    func repeatedPhraseIsKeptWhenTimesDiffer() {
        var reducer = LocalAgreementReducer(track: .mic)
        var log = RowLog()
        let firstThanks = words("thank you", from: 1.0)
        let secondThanks = words("thank you", from: 2.5)

        log.apply(reducer.reduce(decode(firstThanks, window: 0 ... 2)))
        log.apply(reducer.reduce(decode(secondThanks, window: 0 ... 3.5)))
        #expect(log.settledText.isEmpty, "Same text at a different time is not agreement")

        log.apply(reducer.reduce(decode(firstThanks + secondThanks, window: 0 ... 3.75)))
        log.apply(reducer.reduce(decode(firstThanks + secondThanks, window: 0 ... 4)))
        #expect(log.settledText == "thank you thank you")
    }

    @Test("A repeated word just after the committed boundary is kept")
    func repeatedWordJustAfterCommittedBoundaryIsKept() {
        var reducer = LocalAgreementReducer(track: .system)
        var log = RowLog()
        let firstYes = word("yes", 0.6, 1.0)
        let secondYes = word("yes", 1.1, 1.3)

        log.apply(reducer.reduce(decode([firstYes], window: 0 ... 1.2)))
        log.apply(reducer.reduce(decode([firstYes, secondYes], window: 0 ... 1.5)))
        #expect(log.settledText == "yes")

        log.apply(reducer.reduce(decode([firstYes, secondYes], window: 0 ... 2)))
        #expect(log.settledText == "yes yes")
    }

    @Test("Words match after lowercasing and removing punctuation")
    func normalizationIgnoresCaseAndPunctuation() {
        #expect(LocalAgreementReducer.normalize(" Hello, World!") == "hello world")
        #expect(LocalAgreementReducer.normalize("Don\u{2019}t") == "don't")
        #expect(LocalAgreementReducer.normalize("  it's   fine.  ") == "it's fine")
        #expect(LocalAgreementReducer.normalize("\u{4ECA}\u{65E5}\u{306F}\u{3002}") == "\u{4ECA}\u{65E5}\u{306F}")

        var reducer = LocalAgreementReducer(track: .mic)
        var log = RowLog()
        log.apply(reducer.reduce(decode([word("Hello,", 1, 1.3)], window: 0 ... 2)))
        log.apply(reducer.reduce(decode([word("hello", 1, 1.3)], window: 0 ... 2.5)))
        #expect(log.settledText == "hello", "The later decode's spelling is committed")
    }

    // MARK: - Watermarks

    @Test("Silence and empty decodes advance settledThrough unless a tail is pending")
    func silenceAdvancesSettledThrough() {
        var reducer = LocalAgreementReducer(track: .mic, startTime: 2)
        #expect(reducer.settledThrough == 2)

        reducer.resolveSilence(through: 4)
        #expect(reducer.transcribedThrough == 4)
        #expect(reducer.settledThrough == 4)

        _ = reducer.reduce(decode([word("hello", 5, 5.4)], window: 4 ... 6))
        reducer.resolveSilence(through: 8)
        #expect(reducer.transcribedThrough == 8)
        #expect(reducer.settledThrough == 4, "The unconfirmed tail keeps its audio unresolved")

        _ = reducer.reduce(decode([], window: 4 ... 9))
        #expect(!reducer.hasTail)
        #expect(reducer.settledThrough == 9)
        #expect(reducer.transcribedThrough == 9)
    }

    @Test("A sentence-end trim does not commit re-decoded words twice")
    func overlapWithCommittedTextIsRemovedAfterTrim() throws {
        var reducer = LocalAgreementReducer(track: .mic)
        var log = RowLog()
        let opening = [word("Hello", 1.0, 1.3), word("there.", 1.4, 1.7), word("How", 1.8, 2.1), word("are", 2.2, 2.5)]

        log.apply(reducer.reduce(decode(opening, window: 0 ... 3)))
        let committing = reducer.reduce(decode(opening + [word("you", 2.6, 2.9)], window: 0 ... 3.2))
        log.apply(committing)
        #expect(log.settledText == "Hello there. How are")
        let trim = try #require(committing.trimPoint)
        #expect(trim == 1.7)

        // The session drops audio before the trim; the next window re-decodes "How are" with shifted times.
        let redecoded = [word("How", 1.85, 2.15), word("are", 2.25, 2.55), word("you", 2.65, 2.95), word("doing?", 3.0, 3.4)]
        log.apply(reducer.reduce(decode(redecoded, window: trim ... 4)))
        #expect(log.settledText == "Hello there. How are you")
        #expect(log.rows.last?.tailText == " doing?")
    }

    // MARK: - Rows

    @Test("A pause of 1.5 s starts a new row; 1.4 s does not")
    func pauseOfOnePointFiveSecondsStartsNewRow() throws {
        var reducer = LocalAgreementReducer(track: .mic)
        let paused = [word("hi", 0, 0.5), word("there", 2.0, 2.4)]
        _ = reducer.reduce(decode(paused, window: 0 ... 3))
        let result = reducer.reduce(decode(paused, window: 0 ... 3.5))

        #expect(result.rows.map(\.settledText) == ["hi", "there"])
        #expect(result.rows.map(\.isClosed) == [true, false])
        #expect(result.rows.first?.endTime == 0.5)

        var close = LocalAgreementReducer(track: .mic)
        let unpaused = [word("hi", 0, 0.5), word("there", 1.9, 2.3)]
        _ = close.reduce(decode(unpaused, window: 0 ... 3))
        let joined = try #require(close.reduce(decode(unpaused, window: 0 ... 3.5)).rows.first)
        #expect(joined.settledText == "hi there")
    }

    @Test("The open row keeps its ID while its tail changes and settles")
    func rowIDStaysStableAsTailChanges() throws {
        var reducer = LocalAgreementReducer(track: .system)
        let decodes = ["we should", "we should go", "we should ship it", "we should ship it today"]
        var ids: Set<UUID> = []
        for (index, text) in decodes.enumerated() {
            let result = reducer.reduce(decode(words(text, from: 1), window: 0 ... 3 + Double(index)))
            ids.formUnion(result.rows.map(\.id))
        }
        #expect(ids.count == 1)

        let final = try #require(reducer.finish().first)
        #expect(ids == [final.id])
        #expect(final.settledText == "we should ship it today")
    }

    @Test("A tail shown on its own row after a pause keeps that row once settled")
    func tailAfterPauseKeepsItsRowWhenSettled() throws {
        var reducer = LocalAgreementReducer(track: .mic)
        let hello = word("hello", 0, 0.5)
        let again = word("again", 3.0, 3.4)
        _ = reducer.reduce(decode([hello], window: 0 ... 1))
        let opened = try #require(reducer.reduce(decode([hello], window: 0 ... 1.5)).rows.first)

        let tailResult = reducer.reduce(decode([hello, again], window: 0 ... 3.6))
        let tailRow = try #require(tailResult.rows.first)
        #expect(tailResult.rows.count == 1)
        #expect(tailRow.id != opened.id)
        #expect(tailRow.settledText.isEmpty)
        #expect(tailRow.tailText == "again")

        let settled = reducer.reduce(decode([hello, again], window: 0 ... 4))
        #expect(settled.rows.map(\.id) == [opened.id, tailRow.id])
        #expect(settled.rows.map(\.isClosed) == [true, false])
        #expect(settled.rows.last?.settledText == "again")
    }

    @Test("A tail that moves back to the open row empties its row, whose ID goes to the next row")
    func retractedTailEmptiesItsRowAndReusesItsID() throws {
        var reducer = LocalAgreementReducer(track: .mic)
        let hello = word("hello", 0, 0.5)
        _ = reducer.reduce(decode([hello], window: 0 ... 1))
        let open = try #require(reducer.reduce(decode([hello], window: 0 ... 1.5)).rows.first)

        let farTail = reducer.reduce(decode([hello, word("there", 2.5, 2.8)], window: 0 ... 3))
        let tailRow = try #require(farTail.rows.first)

        let nearTail = reducer.reduce(decode([hello, word("there", 1.5, 1.8)], window: 0 ... 3.2))
        #expect(nearTail.rows.map(\.id) == [open.id, tailRow.id])
        #expect(nearTail.rows.first?.tailText == " there")
        #expect(nearTail.rows.last?.hasText == false)

        _ = reducer.reduce(decode([hello, word("there", 1.5, 1.8)], window: 0 ... 3.4))
        let later = reducer.reduce(decode([hello, word("there", 1.5, 1.8), word("now", 5, 5.3)], window: 0 ... 5.5))
        #expect(later.rows.map(\.id) == [tailRow.id])
        #expect(later.rows.first?.tailText == "now")
    }

    @Test("With a 30 s window and no agreement, early words are committed at a forced boundary")
    func forcedBoundaryAtThirtySecondsMarksRow() throws {
        var reducer = LocalAgreementReducer(track: .mic)
        let first = reducer.reduce(decode(words("a b c d e f g h i j", from: 22), window: 0 ... 29.5))
        #expect(first.rows.map(\.settledText) == [""])
        #expect(first.trimPoint == nil)

        // Ends 22.25 ... 26.75 in 0.5 s steps; six end before windowEnd - 5 s = 25.
        let result = reducer.reduce(decode(words("one two three four five six seven eight nine ten", from: 22), window: 0 ... 30))
        let row = try #require(result.rows.first)
        #expect(row.settledText == "one two three four five six")
        #expect(row.tailText == " seven eight nine ten")
        #expect(row.isForcedBoundary)
        #expect(result.trimPoint == 24.75)
        #expect(reducer.settledThrough == 24.75)
    }

    @Test("A forced boundary with no early words trims before the first remaining word")
    func forcedBoundaryWithoutEarlyWordsTrimsBeforeRemainingWords() {
        var reducer = LocalAgreementReducer(track: .mic)
        let result = reducer.reduce(decode([word("late", 24.5, 25.5)], window: 0 ... 30))
        #expect(result.trimPoint == 24.5)
        #expect(result.rows.allSatisfy { !$0.isForcedBoundary })

        var silent = LocalAgreementReducer(track: .mic)
        #expect(silent.reduce(decode([], window: 0 ... 30)).trimPoint == 25)
    }

    // MARK: - Trimming

    @Test("The trim point is the end of the last committed sentence inside the window")
    func trimPointFollowsSentenceEnd() {
        var reducer = LocalAgreementReducer(track: .mic)
        let spoken = [word("Hi.", 1.0, 1.3), word("Then", 1.5, 1.8), word("more", 1.9, 2.2)]
        _ = reducer.reduce(decode(spoken, window: 0 ... 3))
        #expect(reducer.reduce(decode(spoken, window: 0 ... 3.5)).trimPoint == 1.3)

        let next = spoken.dropFirst() + [word("stuff", 2.3, 2.6)]
        #expect(reducer.reduce(decode(Array(next), window: 1.3 ... 4)).trimPoint == nil, "Hi. is no longer in the window")

        var quoted = LocalAgreementReducer(track: .mic)
        let question = [word("ready?\u{201D}", 1.0, 1.4), word("yes", 1.5, 1.8)]
        _ = quoted.reduce(decode(question, window: 0 ... 2))
        #expect(quoted.reduce(decode(question, window: 0 ... 2.5)).trimPoint == 1.4)
    }

    @Test("Past 25 s of window, the trim point falls back to the last committed word")
    func trimPointFallsBackToLastCommittedWordAfterTwentyFiveSeconds() {
        let spoken = words("no sentence end here", from: 20)
        var short = LocalAgreementReducer(track: .mic)
        _ = short.reduce(decode(spoken, window: 0 ... 23.5))
        #expect(short.reduce(decode(spoken, window: 0 ... 24)).trimPoint == nil)

        var long = LocalAgreementReducer(track: .mic)
        _ = long.reduce(decode(spoken, window: 0 ... 25.5))
        #expect(long.reduce(decode(spoken, window: 0 ... 26)).trimPoint == spoken.last?.end)
    }

    // MARK: - Finish

    @Test("finish commits the tail, closes the row and settles through the window")
    func finishCommitsTailAndClosesRow() throws {
        var reducer = LocalAgreementReducer(track: .system)
        _ = reducer.reduce(decode(words("see you", from: 1), window: 0 ... 2))
        let rows = reducer.finish()

        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.settledText == "see you")
        #expect(row.tailText.isEmpty)
        #expect(row.isClosed)
        #expect(!reducer.hasTail)
        #expect(reducer.settledThrough == 2)
        #expect(reducer.transcribedThrough == 2)

        let afterGap = reducer.reduce(decode(words("welcome back", from: 10), window: 9 ... 11))
        #expect(afterGap.rows.map(\.id) != [row.id], "Text after finish opens a new row")
    }

    @Test("finish closes both the open row and a tail row after a pause")
    func finishClosesTailRowAfterPause() {
        var reducer = LocalAgreementReducer(track: .mic)
        let hello = word("hello", 0, 0.5)
        _ = reducer.reduce(decode([hello], window: 0 ... 1))
        _ = reducer.reduce(decode([hello], window: 0 ... 1.5))
        _ = reducer.reduce(decode([hello, word("bye", 4, 4.3)], window: 0 ... 5))

        let rows = reducer.finish()
        #expect(rows.map(\.settledText) == ["hello", "bye"])
        #expect(rows.map(\.isClosed) == [true, true])
    }
}

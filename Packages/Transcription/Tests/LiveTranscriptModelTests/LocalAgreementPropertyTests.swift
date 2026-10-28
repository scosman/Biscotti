import Foundation
import Testing
@testable import LiveTranscriptModel

/// Drives the reducer with noisy decodes of a growing window, as Whisper
/// produces them, and checks the guarantees the drawer relies on.
@Suite("LocalAgreementReducer properties")
struct LocalAgreementPropertyTests {
    @Test("Settled text is append-only across 500 seeded runs, with the other track breaking rows at random")
    func settledTextIsAppendOnly() {
        for seed in UInt64(1) ... 500 {
            var generator = SeededGenerator(seed: seed)
            var checker = InvariantChecker(seed: seed)
            var reducer = LocalAgreementReducer(track: .mic)
            let speech = Self.speech(using: &generator)
            let speechEnd = speech.last?.end ?? 0

            var windowStart: TimeInterval = 0
            var windowEnd: TimeInterval = 0.5
            while windowEnd < speechEnd + 3 {
                windowEnd += Double.random(in: 0.5 ... 2, using: &generator)
                let heard = Self.noisyDecode(of: speech, in: windowStart ... windowEnd, using: &generator)
                let result = reducer.reduce(Hypothesis(words: heard, windowStart: windowStart, windowEnd: windowEnd))
                checker.check(result.rows, reducer: reducer)
                if let trim = result.trimPoint {
                    checker.expect(trim > windowStart && trim <= windowEnd, "trim point inside the window")
                    windowStart = trim
                }
                if Double.random(in: 0 ... 1, using: &generator) < 0.15 {
                    let otherSpeaks = Double.random(in: windowStart ... windowEnd + 1, using: &generator)
                    checker.check(reducer.breakRow(at: otherSpeaks), reducer: reducer)
                }
            }
            checker.check(reducer.finish(), reducer: reducer)
            checker.expect(checker.rowsWithText.allSatisfy(\.isClosed), "finish closes every row with text")
            if checker.failed { break }
        }
    }

    /// Words from a small vocabulary so phrases repeat, with short gaps,
    /// occasional long pauses and occasional sentence ends.
    private static func speech(using generator: inout SeededGenerator) -> [TimedWord] {
        let vocabulary = ["yes", "no", "the", "plan", "ship", "it", "we", "so", "okay", "right"]
        var time = Double.random(in: 0 ... 2, using: &generator)
        return (0 ..< Int.random(in: 5 ... 60, using: &generator)).map { _ in
            let length = Double.random(in: 0.15 ... 0.5, using: &generator)
            let ending = Double.random(in: 0 ... 1, using: &generator) < 0.1 ? "." : ""
            let spoken = TimedWord(text: " " + (vocabulary.randomElement(using: &generator) ?? "so") + ending, start: time, end: time + length)
            let pause = Double.random(in: 0 ... 1, using: &generator) < 0.1 ? 1.0 ... 3.0 : 0.05 ... 0.4
            time += length + Double.random(in: pause, using: &generator)
            return spoken
        }
    }

    /// The words heard so far, with jittered times, a changed or missing last
    /// word now and then, and an occasional dropped word.
    private static func noisyDecode(
        of speech: [TimedWord],
        in window: ClosedRange<TimeInterval>,
        using generator: inout SeededGenerator
    ) -> [TimedWord] {
        var heard = speech
            .filter { $0.start >= window.lowerBound - 0.2 && $0.end <= window.upperBound }
            .map { spoken in
                var word = spoken
                let jitter = Double.random(in: -0.25 ... 0.25, using: &generator)
                word.start = max(window.lowerBound, word.start + jitter)
                word.end = min(window.upperBound, max(word.start, word.end + jitter))
                return word
            }
        let roll = Double.random(in: 0 ... 1, using: &generator)
        if roll < 0.2, !heard.isEmpty {
            heard[heard.count - 1].text = " maybe"
        } else if roll < 0.35 {
            heard.removeLast(min(heard.count, Int.random(in: 1 ... 2, using: &generator)))
        } else if roll < 0.4, !heard.isEmpty {
            heard.remove(at: Int.random(in: 0 ..< heard.count, using: &generator))
        }
        return heard
    }
}

/// Records every version of every row and reports the first broken guarantee.
private struct InvariantChecker {
    let seed: UInt64
    private var latest: [UUID: LiveRow] = [:]
    private var settledThrough: TimeInterval = 0
    private var transcribedThrough: TimeInterval = 0
    private(set) var failed = false

    init(seed: UInt64) {
        self.seed = seed
    }

    var rowsWithText: [LiveRow] {
        latest.values.filter(\.hasText)
    }

    mutating func check(_ rows: [LiveRow], reducer: LocalAgreementReducer) {
        expect(rows.map(\.startTime) == rows.map(\.startTime).sorted(), "rows arrive in time order")
        for row in rows {
            if let previous = latest[row.id] {
                expect(!previous.isClosed, "a closed row never changes")
                expect(row.settledText.hasPrefix(previous.settledText), "settled text only grows")
            }
            expect(!row.isClosed || row.tailText.isEmpty, "a closed row has no tail")
            // 20 s, then at most one more word after a pause shorter than 1.5 s.
            expect(!row.isClosed || row.endTime - row.startTime <= LiveRowBuilder.maxRowLength + 2.5, "a row closes once it is 20 s long")
            expect(row.track == .mic, "rows keep the reducer's track")
            latest[row.id] = row
        }
        expect(reducer.settledThrough >= settledThrough, "settledThrough never decreases")
        expect(reducer.transcribedThrough >= transcribedThrough, "transcribedThrough never decreases")
        expect(reducer.settledThrough <= reducer.transcribedThrough, "settled audio was transcribed")
        settledThrough = reducer.settledThrough
        transcribedThrough = reducer.transcribedThrough
    }

    mutating func expect(_ condition: Bool, _ guarantee: String) {
        guard !condition, !failed else { return }
        failed = true
        Issue.record("Seed \(seed): \(guarantee)")
    }
}

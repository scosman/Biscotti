import Foundation
@testable import LiveTranscriptModel

/// Words spelled as Whisper spells them (leading space), `step` seconds apart, each `length` long.
/// The defaults are exact binary fractions, so expected times compare exactly.
func words(_ text: String, from start: TimeInterval, step: TimeInterval = 0.5, length: TimeInterval = 0.25) -> [TimedWord] {
    text.split(separator: " ").enumerated().map { index, word in
        let wordStart = start + Double(index) * step
        return TimedWord(text: " " + word, start: wordStart, end: wordStart + length)
    }
}

func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedWord {
    TimedWord(text: " " + text, start: start, end: end)
}

func decode(_ words: [TimedWord], window: ClosedRange<TimeInterval>) -> Hypothesis {
    Hypothesis(words: words, windowStart: window.lowerBound, windowEnd: window.upperBound)
}

/// The latest version of every row a reducer emitted, as a consumer store would hold them.
struct RowLog {
    private(set) var latest: [UUID: LiveRow] = [:]

    mutating func apply(_ rows: [LiveRow]) {
        for row in rows {
            latest[row.id] = row
        }
    }

    mutating func apply(_ result: AgreementResult) {
        apply(result.rows)
    }

    var rows: [LiveRow] {
        latest.values.filter(\.hasText).sorted { $0.startTime < $1.startTime }
    }

    /// Settled text of every row with text, rows separated by " | ".
    var settledText: String {
        rows.map(\.settledText).joined(separator: " | ")
    }
}

/// SplitMix64, so randomized tests replay exactly from their seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

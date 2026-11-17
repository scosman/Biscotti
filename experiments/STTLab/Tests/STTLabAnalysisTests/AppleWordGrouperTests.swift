import Testing
@testable import STTLabAnalysis
import STTLabCore

@Suite("AppleWordGrouper")
struct AppleWordGrouperTests {

    /// Helper: build an AppleRun with timing.
    func timedRun(_ text: String, offset: Int, length: Int,
                  startSec: Double, durationSec: Double,
                  confidence: Double? = nil) -> AppleRun {
        AppleRun(
            text: text,
            charOffset: offset,
            charLength: length,
            timeStart: CMTimeValue(value: Int64(startSec * 1_000_000), timescale: 1_000_000,
                                   flags: 1, epoch: 0, seconds: startSec),
            timeDuration: CMTimeValue(value: Int64(durationSec * 1_000_000), timescale: 1_000_000,
                                      flags: 1, epoch: 0, seconds: durationSec),
            confidence: confidence
        )
    }

    /// Helper: build an untimed run.
    func untimedRun(_ text: String, offset: Int, length: Int) -> AppleRun {
        AppleRun(text: text, charOffset: offset, charLength: length)
    }

    @Test("Basic word grouping: two words with timed runs")
    func basicGrouping() {
        // "Hello world" -> tokens at [0,5) and [6,11)
        let result = AppleResult(
            index: 0,
            rangeStart: CMTimeValue(value: 0, timescale: 1, flags: 1, epoch: 0, seconds: 0),
            rangeDuration: CMTimeValue(value: 5, timescale: 1, flags: 1, epoch: 0, seconds: 5),
            resultsFinalizationTime: CMTimeValue(value: 5, timescale: 1, flags: 1, epoch: 0,
                                                  seconds: 5),
            isFinal: true,
            text: "Hello world",
            runs: [
                timedRun("Hello", offset: 0, length: 5, startSec: 0.0, durationSec: 0.5,
                         confidence: 0.9),
                timedRun(" ", offset: 5, length: 1, startSec: 0.5, durationSec: 0.1),
                timedRun("world", offset: 6, length: 5, startSec: 0.6, durationSec: 0.4,
                         confidence: 0.8),
            ]
        )

        let (words, stats) = AppleWordGrouper.group(results: [result], audioDuration: 10)

        #expect(words.count == 2)
        #expect(words[0].text == "Hello")
        #expect(words[0].start == 0.0)
        #expect(words[0].confidence == 0.9)
        #expect(words[1].text == "world")
        #expect(words[1].start == 0.6)
        #expect(stats.totalRuns == 3)
    }

    @Test("Untimed word: no timing data when no timed runs overlap")
    func untimedWord() {
        let result = AppleResult(
            index: 0,
            rangeStart: CMTimeValue(value: 0, timescale: 1, flags: 1, epoch: 0, seconds: 0),
            rangeDuration: CMTimeValue(value: 2, timescale: 1, flags: 1, epoch: 0, seconds: 2),
            resultsFinalizationTime: CMTimeValue(value: 2, timescale: 1, flags: 1, epoch: 0,
                                                  seconds: 2),
            isFinal: true,
            text: "hello",
            runs: [untimedRun("hello", offset: 0, length: 5)]
        )

        let (words, stats) = AppleWordGrouper.group(results: [result], audioDuration: 10)
        #expect(words.count == 1)
        #expect(words[0].start == nil)
        #expect(words[0].end == nil)
        #expect(stats.anomalyCounts[RunAnomaly.untimedRun.rawValue] == 1)
    }

    @Test("RunClass: punctuation only")
    func punctuationOnlyClass() {
        let result = AppleResult(
            index: 0,
            rangeStart: CMTimeValue(value: 0, timescale: 1, flags: 1, epoch: 0, seconds: 0),
            rangeDuration: CMTimeValue(value: 2, timescale: 1, flags: 1, epoch: 0, seconds: 2),
            resultsFinalizationTime: CMTimeValue(value: 2, timescale: 1, flags: 1, epoch: 0,
                                                  seconds: 2),
            isFinal: true,
            text: "Hi, there",
            runs: [
                timedRun("Hi", offset: 0, length: 2, startSec: 0.0, durationSec: 0.3),
                timedRun(", ", offset: 2, length: 2, startSec: 0.3, durationSec: 0.05),
                timedRun("there", offset: 4, length: 5, startSec: 0.35, durationSec: 0.3),
            ]
        )

        let (_, stats) = AppleWordGrouper.group(results: [result], audioDuration: 10)
        // "Hi" and "there" are wholeWord; ", " is punctuationOnly.
        #expect(stats.classCounts[RunClass.wholeWord.rawValue] == 2)
        #expect(stats.classCounts[RunClass.punctuationOnly.rawValue] == 1)
    }

    @Test("Anomaly: zero-length duration")
    func zeroLengthAnomaly() {
        let result = AppleResult(
            index: 0,
            rangeStart: CMTimeValue(value: 0, timescale: 1, flags: 1, epoch: 0, seconds: 0),
            rangeDuration: CMTimeValue(value: 1, timescale: 1, flags: 1, epoch: 0, seconds: 1),
            resultsFinalizationTime: CMTimeValue(value: 1, timescale: 1, flags: 1, epoch: 0,
                                                  seconds: 1),
            isFinal: true,
            text: "test",
            runs: [timedRun("test", offset: 0, length: 4, startSec: 0.5, durationSec: 0.0)]
        )

        let (_, stats) = AppleWordGrouper.group(results: [result], audioDuration: 10)
        #expect(stats.anomalyCounts[RunAnomaly.zeroLength.rawValue] == 1)
    }

    @Test("Anomaly: out of order")
    func outOfOrderAnomaly() {
        let result = AppleResult(
            index: 0,
            rangeStart: CMTimeValue(value: 0, timescale: 1, flags: 1, epoch: 0, seconds: 0),
            rangeDuration: CMTimeValue(value: 3, timescale: 1, flags: 1, epoch: 0, seconds: 3),
            resultsFinalizationTime: CMTimeValue(value: 3, timescale: 1, flags: 1, epoch: 0,
                                                  seconds: 3),
            isFinal: true,
            text: "A B",
            runs: [
                timedRun("A", offset: 0, length: 1, startSec: 1.0, durationSec: 0.5),
                timedRun(" ", offset: 1, length: 1, startSec: 1.5, durationSec: 0.1),
                timedRun("B", offset: 2, length: 1, startSec: 0.5, durationSec: 0.3),
            ]
        )

        let (_, stats) = AppleWordGrouper.group(results: [result], audioDuration: 10)
        #expect(stats.anomalyCounts[RunAnomaly.outOfOrder.rawValue] == 1)
    }

    @Test("Emoji in text: surrogate pairs do not crash tokenizer")
    func emojiInText() {
        // "Hello 👋 world" — the wave emoji is a supplementary-plane character that
        // encodes as a surrogate pair in UTF-16 (0xD83D 0xDC4B). The tokenizer must
        // not crash on it.
        let result = AppleResult(
            index: 0,
            rangeStart: CMTimeValue(value: 0, timescale: 1, flags: 1, epoch: 0, seconds: 0),
            rangeDuration: CMTimeValue(value: 3, timescale: 1, flags: 1, epoch: 0, seconds: 3),
            resultsFinalizationTime: CMTimeValue(value: 3, timescale: 1, flags: 1, epoch: 0,
                                                  seconds: 3),
            isFinal: true,
            text: "Hello 👋 world",
            runs: [
                timedRun("Hello", offset: 0, length: 5, startSec: 0.0, durationSec: 0.3),
                untimedRun(" ", offset: 5, length: 1),
                // Emoji is 2 UTF-16 code units (surrogate pair).
                timedRun("👋", offset: 6, length: 2, startSec: 0.3, durationSec: 0.2),
                untimedRun(" ", offset: 8, length: 1),
                timedRun("world", offset: 9, length: 5, startSec: 0.5, durationSec: 0.3),
            ]
        )

        let (words, stats) = AppleWordGrouper.group(results: [result], audioDuration: 10)

        // Three tokens: "Hello", "👋", "world".
        #expect(words.count == 3)
        #expect(words[0].text == "Hello")
        #expect(words[1].text == "👋")
        #expect(words[1].start == 0.3)
        #expect(words[2].text == "world")
        #expect(stats.totalRuns == 5)
    }

    @Test("Anomaly: outside audio")
    func outsideAudioAnomaly() {
        let result = AppleResult(
            index: 0,
            rangeStart: CMTimeValue(value: 0, timescale: 1, flags: 1, epoch: 0, seconds: 0),
            rangeDuration: CMTimeValue(value: 2, timescale: 1, flags: 1, epoch: 0, seconds: 2),
            resultsFinalizationTime: CMTimeValue(value: 2, timescale: 1, flags: 1, epoch: 0,
                                                  seconds: 2),
            isFinal: true,
            text: "late",
            runs: [timedRun("late", offset: 0, length: 4, startSec: 9.8, durationSec: 1.5)]
        )

        // Audio is 10s, run ends at 11.3 which is > 10 + 0.5.
        let (_, stats) = AppleWordGrouper.group(results: [result], audioDuration: 10)
        #expect(stats.anomalyCounts[RunAnomaly.outsideAudio.rawValue] == 1)
    }
}

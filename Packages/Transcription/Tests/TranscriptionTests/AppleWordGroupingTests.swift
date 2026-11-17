import Foundation
import SpeakerKit
import Testing
import WhisperKit
@testable import Transcription

@Suite("AppleWordGrouping - word extraction")
struct AppleWordGroupingWordTests {
    @Test("whole-word runs produce one word per token")
    func wholeWordRuns() {
        // "Hello world" with two runs, each covering one word.
        let result = AppleResultInput(
            text: "Hello world",
            rangeStart: 0.0, rangeDuration: 2.0,
            runs: [
                AppleRunInput(
                    text: "Hello", charOffset: 0, charLength: 5,
                    start: 0.0, duration: 1.0, confidence: 0.9
                ),
                AppleRunInput(
                    text: "world", charOffset: 6, charLength: 5,
                    start: 1.0, duration: 1.0, confidence: 0.8
                )
            ]
        )

        let words = AppleWordGrouping.words(in: result)
        #expect(words.count == 2)
        #expect(words[0].text == "Hello")
        #expect(words[0].start == 0.0)
        #expect(words[0].end == 1.0)
        #expect(words[0].confidence == 0.9)
        #expect(words[1].text == "world")
        #expect(words[1].start == 1.0)
        #expect(words[1].end == 2.0)
        #expect(words[1].confidence == 0.8)
    }

    @Test("leading-space runs still assign times correctly")
    func leadingSpaceRuns() {
        // " Oh," at [0,4) — the run includes leading space, token "Oh," is [1,4).
        let result = AppleResultInput(
            text: " Oh, hi",
            rangeStart: 0.0, rangeDuration: 2.0,
            runs: [
                AppleRunInput(
                    text: " Oh,", charOffset: 0, charLength: 4,
                    start: 0.0, duration: 1.0, confidence: 0.95
                ),
                AppleRunInput(
                    text: " hi", charOffset: 4, charLength: 3,
                    start: 1.0, duration: 0.5, confidence: 0.85
                )
            ]
        )

        let words = AppleWordGrouping.words(in: result)
        #expect(words.count == 2)
        #expect(words[0].text == "Oh,")
        #expect(words[0].start == 0.0)
        #expect(words[1].text == "hi")
        #expect(words[1].start == 1.0)
    }

    @Test("multi-run token gets min start / max end / mean confidence")
    func multiRunToken() throws {
        // A single word "testing" covered by two overlapping runs.
        let result = AppleResultInput(
            text: "testing",
            rangeStart: 0.0, rangeDuration: 2.0,
            runs: [
                AppleRunInput(
                    text: "test", charOffset: 0, charLength: 4,
                    start: 0.5, duration: 0.5, confidence: 0.8
                ),
                AppleRunInput(
                    text: "ing", charOffset: 4, charLength: 3,
                    start: 0.8, duration: 0.7, confidence: 0.6
                )
            ]
        )

        let words = AppleWordGrouping.words(in: result)
        #expect(words.count == 1)
        #expect(words[0].text == "testing")
        #expect(words[0].start == 0.5) // min of 0.5, 0.8
        #expect(words[0].end == 1.5) // max of 1.0, 1.5
        #expect(try #require(words[0].confidence) - 0.7 < 0.001) // mean of 0.8, 0.6
    }

    @Test("untimed runs produce nil timing")
    func untimedRuns() {
        let result = AppleResultInput(
            text: "Hello",
            rangeStart: 0.0, rangeDuration: 1.0,
            runs: [
                AppleRunInput(
                    text: "Hello", charOffset: 0, charLength: 5,
                    start: nil, duration: nil, confidence: nil
                )
            ]
        )

        let words = AppleWordGrouping.words(in: result)
        #expect(words.count == 1)
        #expect(words[0].start == nil)
        #expect(words[0].end == nil)
        #expect(words[0].confidence == nil)
    }
}

@Suite("AppleWordGrouping - untimed fill")
struct AppleWordGroupingFillTests {
    @Test("untimed word uses previous timed word's end")
    func previousEnd() {
        let result = AppleResultInput(
            text: "a b c", rangeStart: 0.0, rangeDuration: 3.0, runs: []
        )
        let words = [
            AppleWord(text: "a", start: 0.0, end: 1.0, confidence: nil),
            AppleWord(text: "b", start: nil, end: nil, confidence: nil),
            AppleWord(text: "c", start: 2.0, end: 3.0, confidence: nil)
        ]

        let filled = AppleWordGrouping.fillUntimed(words, result: result)
        #expect(filled.count == 3)
        #expect(filled[1].start == 1.0) // previous end
        #expect(filled[1].end == 1.0)
    }

    @Test("untimed word before any timed word uses next timed word's start")
    func nextStart() {
        let result = AppleResultInput(
            text: "a b", rangeStart: 0.0, rangeDuration: 2.0, runs: []
        )
        let words = [
            AppleWord(text: "a", start: nil, end: nil, confidence: nil),
            AppleWord(text: "b", start: 1.0, end: 2.0, confidence: nil)
        ]

        let filled = AppleWordGrouping.fillUntimed(words, result: result)
        #expect(filled[0].start == 1.0) // next start
        #expect(filled[0].end == 1.0)
    }

    @Test("all-untimed words spread evenly across range")
    func allUntimedSpread() {
        let result = AppleResultInput(
            text: "a b c", rangeStart: 0.0, rangeDuration: 3.0, runs: []
        )
        let words = [
            AppleWord(text: "a", start: nil, end: nil, confidence: nil),
            AppleWord(text: "b", start: nil, end: nil, confidence: nil),
            AppleWord(text: "c", start: nil, end: nil, confidence: nil)
        ]

        let filled = AppleWordGrouping.fillUntimed(words, result: result)
        #expect(filled.count == 3)
        #expect(filled[0].start == 0.0)
        #expect(filled[0].end == 1.0)
        #expect(filled[1].start == 1.0)
        #expect(filled[1].end == 2.0)
        #expect(filled[2].start == 2.0)
        #expect(filled[2].end == 3.0)
    }

    @Test("no words are dropped during fill")
    func noWordDropped() {
        let result = AppleResultInput(
            text: "x y z", rangeStart: 5.0, rangeDuration: 1.0, runs: []
        )
        let words = [
            AppleWord(text: "x", start: nil, end: nil, confidence: nil),
            AppleWord(text: "y", start: 5.5, end: 5.6, confidence: nil),
            AppleWord(text: "z", start: nil, end: nil, confidence: nil)
        ]

        let filled = AppleWordGrouping.fillUntimed(words, result: result)
        #expect(filled.count == 3)
        #expect(filled.allSatisfy { $0.start != nil })
    }
}

@Suite("AppleWordGrouping - bridge to TranscriptionResult")
struct AppleWordGroupingBridgeTests {
    @Test("one segment per result, empty results dropped")
    func oneSegmentPerResult() {
        let results = [
            AppleResultInput(
                text: "Hello world",
                rangeStart: 0.0, rangeDuration: 2.0,
                runs: [
                    AppleRunInput(
                        text: "Hello", charOffset: 0, charLength: 5,
                        start: 0.0, duration: 1.0, confidence: 0.9
                    ),
                    AppleRunInput(
                        text: "world", charOffset: 6, charLength: 5,
                        start: 1.0, duration: 1.0, confidence: 0.8
                    )
                ]
            ),
            // Empty result (no text).
            AppleResultInput(
                text: "", rangeStart: 2.0, rangeDuration: 0.5, runs: []
            ),
            AppleResultInput(
                text: "Goodbye",
                rangeStart: 3.0, rangeDuration: 1.0,
                runs: [
                    AppleRunInput(
                        text: "Goodbye", charOffset: 0, charLength: 7,
                        start: 3.0, duration: 1.0, confidence: 0.95
                    )
                ]
            )
        ]

        let transcriptionResults = AppleWordGrouping.transcriptionResults(
            from: results, language: "en_US"
        )
        #expect(transcriptionResults.count == 1)

        let segments = transcriptionResults[0].segments
        #expect(segments.count == 2)
        #expect(segments[0].text == "Hello world")
        #expect(segments[0].start == 0.0)
        #expect(segments[0].end == 2.0)
        #expect(segments[1].text == "Goodbye")
        #expect(segments[1].start == 3.0)
    }

    @Test("nil confidence defaults to probability 1.0")
    func confidenceDefault() {
        let results = [
            AppleResultInput(
                text: "Hi",
                rangeStart: 0.0, rangeDuration: 1.0,
                runs: [
                    AppleRunInput(
                        text: "Hi", charOffset: 0, charLength: 2,
                        start: 0.0, duration: 1.0, confidence: nil
                    )
                ]
            )
        ]

        let transcriptionResults = AppleWordGrouping.transcriptionResults(
            from: results, language: "en_US"
        )
        let words = transcriptionResults[0].segments[0].words
        #expect(words != nil)
        #expect(words?[0].probability == 1.0)
    }

    @Test("language is set correctly")
    func languageSet() {
        let results = [
            AppleResultInput(
                text: "Test",
                rangeStart: 0.0, rangeDuration: 1.0,
                runs: [
                    AppleRunInput(
                        text: "Test", charOffset: 0, charLength: 4,
                        start: 0.0, duration: 1.0, confidence: 0.9
                    )
                ]
            )
        ]

        let transcriptionResults = AppleWordGrouping.transcriptionResults(
            from: results, language: "fr_FR"
        )
        #expect(transcriptionResults[0].language == "fr_FR")
    }

    @Test("results are sorted by start time")
    func sortedByStartTime() {
        let results = [
            AppleResultInput(
                text: "Second",
                rangeStart: 2.0, rangeDuration: 1.0,
                runs: [
                    AppleRunInput(
                        text: "Second", charOffset: 0, charLength: 6,
                        start: 2.0, duration: 1.0, confidence: 0.9
                    )
                ]
            ),
            AppleResultInput(
                text: "First",
                rangeStart: 0.0, rangeDuration: 1.0,
                runs: [
                    AppleRunInput(
                        text: "First", charOffset: 0, charLength: 5,
                        start: 0.0, duration: 1.0, confidence: 0.9
                    )
                ]
            )
        ]

        let transcriptionResults = AppleWordGrouping.transcriptionResults(
            from: results, language: "en"
        )
        let segments = transcriptionResults[0].segments
        #expect(segments[0].text == "First")
        #expect(segments[1].text == "Second")
        // IDs should be re-indexed after sort.
        #expect(segments[0].id == 0)
        #expect(segments[1].id == 1)
    }

    @Test("word timings have leading space prefix")
    func wordTimingsHaveLeadingSpace() throws {
        let results = [
            AppleResultInput(
                text: "Hello",
                rangeStart: 0.0, rangeDuration: 1.0,
                runs: [
                    AppleRunInput(
                        text: "Hello", charOffset: 0, charLength: 5,
                        start: 0.0, duration: 1.0, confidence: 0.9
                    )
                ]
            )
        ]

        let transcriptionResults = AppleWordGrouping.transcriptionResults(
            from: results, language: "en"
        )
        let wordTimings = try #require(transcriptionResults[0].segments[0].words)
        #expect(wordTimings[0].word == " Hello")
    }
}

@Suite("AppleWordGrouping - bridge then assemble assigns speakers")
struct AppleWordGroupingIntegrationTests {
    /// Two Apple results: speaker 0 talks at 0-2s, speaker 1 at 3-5s.
    private static func makeTwoSpeakerAppleResults() -> [AppleResultInput] {
        [
            AppleResultInput(
                text: "Hello world",
                rangeStart: 0.0, rangeDuration: 2.0,
                runs: [
                    AppleRunInput(
                        text: "Hello", charOffset: 0, charLength: 5,
                        start: 0.0, duration: 1.0, confidence: 0.9
                    ),
                    AppleRunInput(
                        text: "world", charOffset: 6, charLength: 5,
                        start: 1.0, duration: 1.0, confidence: 0.8
                    )
                ]
            ),
            AppleResultInput(
                text: "Goodbye all",
                rangeStart: 3.0, rangeDuration: 2.0,
                runs: [
                    AppleRunInput(
                        text: "Goodbye", charOffset: 0, charLength: 7,
                        start: 3.0, duration: 1.0, confidence: 0.95
                    ),
                    AppleRunInput(
                        text: "all", charOffset: 8, charLength: 3,
                        start: 4.0, duration: 1.0, confidence: 0.85
                    )
                ]
            )
        ]
    }

    /// Synthetic diarization: speaker 0 active at 0-2.5s, speaker 1 at 2.5-5.5s.
    private static func makeTwoSpeakerDiarization() -> DiarizationResult {
        let frameRate: Float = 10.0
        return DiarizationResult(
            speakerCount: 2,
            totalFrames: 55,
            frameRate: frameRate,
            segments: [
                SpeakerSegment(
                    speaker: .speakerId(0),
                    startTime: 0.0, endTime: 2.5, frameRate: frameRate
                ),
                SpeakerSegment(
                    speaker: .speakerId(1),
                    startTime: 2.5, endTime: 5.5, frameRate: frameRate
                )
            ]
        )
    }

    /// Bridged Apple results flow through addSpeakerInfo + SegmentBuilder and
    /// produce segments with the expected speaker IDs. No models needed.
    @Test("bridged results through speaker attribution produce expected speaker IDs")
    func bridgeThenAssembleAssignsSpeakers() throws {
        let bridged = AppleWordGrouping.transcriptionResults(
            from: Self.makeTwoSpeakerAppleResults(), language: "en_US"
        )
        #expect(bridged.count == 1)
        #expect(bridged[0].segments.count == 2)

        let diarization = Self.makeTwoSpeakerDiarization()
        let speakerGroups = diarization.addSpeakerInfo(
            to: bridged, strategy: .subsegment
        )
        let segments = SegmentBuilder.buildSegments(from: speakerGroups)
        #expect(!segments.isEmpty)

        let speaker0Segs = segments.filter { $0.speakerID == 0 }
        let speaker1Segs = segments.filter { $0.speakerID == 1 }
        #expect(!speaker0Segs.isEmpty, "Speaker 0 should have segments")
        #expect(!speaker1Segs.isEmpty, "Speaker 1 should have segments")

        // "Hello world" (0-2s) -> speaker 0.
        let helloSeg = try #require(speaker0Segs.first { $0.text.contains("Hello") })
        #expect(helloSeg.speakerID == 0)

        // "Goodbye all" (3-5s) -> speaker 1.
        let goodbyeSeg = try #require(speaker1Segs.first { $0.text.contains("Goodbye") })
        #expect(goodbyeSeg.speakerID == 1)
    }
}

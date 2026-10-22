import Testing
@testable import STTLabAnalysis

@Suite("Flags")
struct FlagsTests {

    @Test("WER ratio flag triggers when ratio > 2 and both > 0.02")
    func werRatioTriggers() {
        let flag = Flags.checkWERRatio(appleWER: 0.05, whisperWER: 0.12)
        #expect(flag != nil)
        if case .werRatio(let a, let w) = flag {
            #expect(a == 0.05)
            #expect(w == 0.12)
        }
    }

    @Test("WER ratio does not trigger when smaller <= 0.02")
    func werRatioSmallWER() {
        let flag = Flags.checkWERRatio(appleWER: 0.01, whisperWER: 0.10)
        #expect(flag == nil)
    }

    @Test("WER ratio does not trigger when ratio <= 2")
    func werRatioCloseWERs() {
        let flag = Flags.checkWERRatio(appleWER: 0.10, whisperWER: 0.15)
        #expect(flag == nil)
    }

    @Test("WER ratio returns nil when one WER is nil")
    func werRatioNilWER() {
        let flag = Flags.checkWERRatio(appleWER: nil, whisperWER: 0.10)
        #expect(flag == nil)
    }

    @Test("Empty result flag for engine with zero words")
    func emptyResultFlag() {
        let transcript = EngineTranscript(engine: .apple, words: [], displayText: "")
        let flags = Flags.checkEmpty(transcripts: [(.apple, transcript)])
        #expect(flags.count == 1)
        if case .emptyResult(let e) = flags[0] {
            #expect(e == .apple)
        }
    }

    @Test("Empty result flag not triggered when transcript has words")
    func emptyResultNotTriggered() {
        let transcript = EngineTranscript(
            engine: .apple,
            words: [EngineWord(text: "hello", segmentIndex: 0)],
            displayText: "hello"
        )
        let flags = Flags.checkEmpty(transcripts: [(.apple, transcript)])
        #expect(flags.isEmpty)
    }

    @Test("Empty result flag not triggered for nil transcript")
    func emptyResultNil() {
        let flags = Flags.checkEmpty(transcripts: [(.apple, nil)])
        #expect(flags.isEmpty)
    }

    @Test("Dropped stretch: 40s gap with other engines having words inside")
    func droppedStretchTriggered() {
        // Apple has a 40s gap from 10 to 50.
        let appleWords: [EngineWord] = [
            EngineWord(text: "hello", start: 1, end: 2, segmentIndex: 0),
            EngineWord(text: "world", start: 50, end: 51, segmentIndex: 0),
        ]
        let apple = EngineTranscript(engine: .apple, words: appleWords, displayText: "hello world")

        // Whisper has words inside the gap.
        let whisperWords: [EngineWord] = (0..<10).map {
            EngineWord(text: "w\($0)", start: Double(15 + $0 * 3), end: Double(16 + $0 * 3),
                       segmentIndex: 0)
        }
        let whisper = EngineTranscript(engine: .whisper, words: whisperWords, displayText: "...")

        // Reference has words too.
        let refWords: [EngineWord] = (0..<5).map {
            EngineWord(text: "r\($0)", start: Double(20 + $0 * 5), end: Double(21 + $0 * 5),
                       segmentIndex: 0)
        }
        let reference = EngineTranscript(engine: .reference, words: refWords, displayText: "...")

        let flags = Flags.checkDroppedStretches(
            transcripts: [(.apple, apple), (.whisper, whisper), (.reference, reference)],
            audioDuration: 60
        )
        #expect(!flags.isEmpty)
        if case .droppedStretch(let engine, _, _) = flags[0] {
            #expect(engine == .apple)
        }
    }

    @Test("Dropped stretch: gap < 30s does not trigger")
    func droppedStretchShortGap() {
        let appleWords: [EngineWord] = [
            EngineWord(text: "hello", start: 1, end: 2, segmentIndex: 0),
            EngineWord(text: "world", start: 25, end: 26, segmentIndex: 0),
        ]
        let apple = EngineTranscript(engine: .apple, words: appleWords, displayText: "hello world")
        let whisper = EngineTranscript(engine: .whisper,
                                       words: [EngineWord(text: "w", start: 10, end: 11,
                                                          segmentIndex: 0)],
                                       displayText: "w")
        let flags = Flags.checkDroppedStretches(
            transcripts: [(.apple, apple), (.whisper, whisper)],
            audioDuration: 30
        )
        #expect(flags.isEmpty)
    }
}

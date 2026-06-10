import Foundation
import Testing
import Transcription

@Suite("TranscriptChunker")
struct TranscriptChunkerTests {
    @Test("single segment produces one chunk")
    func singleSegment() {
        let result = makeResult(segments: [
            seg(speaker: 0, text: "Hello", start: 0, end: 1)
        ])
        let chunks = TranscriptChunker.chunks(from: result)
        #expect(chunks.count == 1)
        #expect(chunks[0].speakerID == 0)
        #expect(chunks[0].text == "Hello")
        #expect(chunks[0].start == 0)
        #expect(chunks[0].end == 1)
    }

    @Test("adjacent segments with same speaker are merged")
    func sameSpeakerMerge() {
        let result = makeResult(segments: [
            seg(speaker: 0, text: "Hello", start: 0, end: 1),
            seg(speaker: 0, text: "world", start: 1, end: 2)
        ])
        let chunks = TranscriptChunker.chunks(from: result)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "Hello world")
        #expect(chunks[0].start == 0)
        #expect(chunks[0].end == 2)
    }

    @Test("A/B/A pattern produces 3 chunks with 2 distinct speakers")
    func alternatingPattern() {
        let result = makeResult(segments: [
            seg(speaker: 0, text: "First", start: 0, end: 1),
            seg(speaker: 1, text: "Second", start: 1, end: 2),
            seg(speaker: 0, text: "Third", start: 2, end: 3)
        ])
        let chunks = TranscriptChunker.chunks(from: result)
        #expect(chunks.count == 3)
        let speakerIDs: [Int] = chunks.compactMap(\.speakerID)
        let distinctSpeakers = Set(speakerIDs)
        #expect(distinctSpeakers.count == 2)
    }

    @Test("A/B/C pattern produces 3 chunks with 3 distinct speakers")
    func threeDistinctSpeakers() {
        let result = makeResult(segments: [
            seg(speaker: 0, text: "One", start: 0, end: 1),
            seg(speaker: 1, text: "Two", start: 1, end: 2),
            seg(speaker: 2, text: "Three", start: 2, end: 3)
        ])
        let chunks = TranscriptChunker.chunks(from: result)
        #expect(chunks.count == 3)
        #expect(chunks[0].speakerID == 0)
        #expect(chunks[1].speakerID == 1)
        #expect(chunks[2].speakerID == 2)
    }

    @Test("nil speakerID segments merge together")
    func nilSpeakerMerge() {
        let noSpeaker: Int? = nil
        let result = makeResult(segments: [
            seg(speaker: noSpeaker, text: "Hello", start: 0, end: 1),
            seg(speaker: noSpeaker, text: "world", start: 1, end: 2)
        ])
        let chunks = TranscriptChunker.chunks(from: result)
        #expect(chunks.count == 1)
        #expect(chunks[0].speakerID == nil)
        #expect(chunks[0].text == "Hello world")
    }

    @Test("nil vs non-nil speaker creates separate chunks")
    func nilVsNonNil() {
        let noSpeaker: Int? = nil
        let result = makeResult(segments: [
            seg(speaker: noSpeaker, text: "Unknown", start: 0, end: 1),
            seg(speaker: 0, text: "Known", start: 1, end: 2)
        ])
        let chunks = TranscriptChunker.chunks(from: result)
        #expect(chunks.count == 2)
        #expect(chunks[0].speakerID == nil)
        #expect(chunks[1].speakerID == 0)
    }

    @Test("empty result produces no chunks")
    func emptyResult() {
        let result = makeResult(segments: [])
        let chunks = TranscriptChunker.chunks(from: result)
        #expect(chunks.isEmpty)
    }

    @Test("out-of-order segments with different speakers are sorted then chunked")
    func unsortedDifferentSpeakers() {
        // Input: [speaker 1 @ t=2, speaker 0 @ t=0, speaker 1 @ t=3]
        // After sort by startTime: [speaker 0 @ t=0, speaker 1 @ t=2, speaker 1 @ t=3]
        // Chunked: speaker 0 ("B"), then speaker 1 ("A C" merged)
        let result = makeResult(segments: [
            seg(speaker: 1, text: "A", start: 2, end: 3),
            seg(speaker: 0, text: "B", start: 0, end: 1),
            seg(speaker: 1, text: "C", start: 3, end: 4)
        ])
        let chunks = TranscriptChunker.chunks(from: result)
        #expect(chunks.count == 2)
        #expect(chunks[0].speakerID == 0)
        #expect(chunks[0].text == "B")
        #expect(chunks[1].speakerID == 1)
        #expect(chunks[1].text == "A C")
    }

    @Test("segments are sorted by start time before chunking")
    func unsortedSegments() {
        let result = makeResult(segments: [
            seg(speaker: 0, text: "Second", start: 2, end: 3),
            seg(speaker: 0, text: "First", start: 0, end: 1)
        ])
        let chunks = TranscriptChunker.chunks(from: result)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "First Second")
    }

    @Test("3-speaker ground-truth scenario: B has two segments merged")
    func groundTruthScenario() {
        let result = makeResult(segments: [
            seg(speaker: 0, text: "Hello, this is a test of the system.", start: 0.8, end: 2.5),
            seg(speaker: 1, text: "Hello, I am person number two.", start: 4.5, end: 6.0),
            seg(speaker: 1, text: "I am saying something back.", start: 6.0, end: 8.0),
            seg(speaker: 2, text: "Hi, I'm person number three and you two are banana heads.",
                start: 9.7, end: 13.0)
        ])
        let chunks = TranscriptChunker.chunks(from: result)
        #expect(chunks.count == 3)
        let speakerIDs: [Int] = chunks.compactMap(\.speakerID)
        #expect(Set(speakerIDs).count == 3)
        #expect(chunks[1].text
            == "Hello, I am person number two. I am saying something back.")
    }
}

// MARK: - Test helpers

private func seg(
    speaker: Int?, text: String, start: TimeInterval, end: TimeInterval
) -> TranscriptSegment {
    TranscriptSegment(
        speakerID: speaker,
        speakerLabel: speaker.map { "Speaker \($0)" } ?? "Unknown",
        startTime: start,
        endTime: end,
        text: text,
        confidence: 0,
        noSpeechProbability: 0,
        words: nil
    )
}

private func makeResult(segments: [TranscriptSegment]) -> TranscriptResult {
    TranscriptResult(
        transcriptionMethodId: "test",
        language: "en",
        speakerCount: Set(segments.compactMap(\.speakerID)).count,
        segments: segments,
        speakerEmbeddings: [:],
        processingDuration: 0
    )
}

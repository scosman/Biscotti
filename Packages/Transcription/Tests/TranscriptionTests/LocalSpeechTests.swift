import Foundation
import Testing
@testable import Transcription

/// Your own words stay apart from remote voices when voices are separated
/// on the call audio alone.
struct LocalSpeechTests {
    private static func word(_ text: String, _ start: Double, speaker: Int) -> TranscriptWord {
        TranscriptWord(word: " " + text, startTime: start, endTime: start + 0.4, probability: 0.9, speakerID: speaker)
    }

    @Test func wordsOutsideEveryCallVoiceGetTheirOwnSpeaker() {
        // Diarization gave everything to voice 0; only 5-7 s was remote.
        let words = [
            Self.word("Can", 1, speaker: 0), Self.word("you", 1.5, speaker: 0), Self.word("hear", 2, speaker: 0),
            Self.word("Yes", 5, speaker: 0), Self.word("I", 5.5, speaker: 0), Self.word("can", 6, speaker: 0)
        ]
        let segment = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0", startTime: 1, endTime: 6.4,
            text: "Can you hear Yes I can", confidence: 0.9, noSpeechProbability: 0, words: words
        )
        var result = TranscriptResult(
            transcriptionMethodId: "test", language: "en", speakerCount: 1, segments: [segment], processingDuration: 0
        )
        result.speakerSpans = [DiarizedSpan(speakerID: 0, start: 5, end: 7)]

        let separated = LocalSpeech.separate(result, spans: result.speakerSpans)
        #expect(separated.segments.map(\.text) == ["Can you hear", "Yes I can"])
        #expect(separated.segments.map(\.speakerID) == [1, 0])
        #expect(separated.speakerCount == 2)
        #expect(separated.speakerSpans == result.speakerSpans)
    }

    @Test func aTranscriptFullyInsideCallVoicesIsUnchanged() {
        let words = [Self.word("Hello", 5, speaker: 0)]
        let segment = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0", startTime: 5, endTime: 5.4,
            text: "Hello", confidence: 0.9, noSpeechProbability: 0, words: words
        )
        let result = TranscriptResult(
            transcriptionMethodId: "test", language: "en", speakerCount: 1, segments: [segment], processingDuration: 0
        )
        #expect(LocalSpeech.separate(result, spans: [DiarizedSpan(speakerID: 0, start: 4, end: 6)]) == result)
    }
}

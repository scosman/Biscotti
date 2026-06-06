import Foundation
import Testing
@testable import Transcription

@Suite("TranscriptSanitizer")
struct SanitizerTests {
    // MARK: - Helpers

    private func makeWord(
        _ text: String,
        start: TimeInterval,
        end: TimeInterval,
        probability: Float = 0.9,
        speakerID: Int? = 0
    ) -> TranscriptWord {
        TranscriptWord(
            word: text,
            startTime: start,
            endTime: end,
            probability: probability,
            speakerID: speakerID
        )
    }

    private func makeSegment(
        start: TimeInterval,
        end: TimeInterval,
        text: String = "Hello",
        confidence: Float = 0.0,
        words: [TranscriptWord]? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            speakerID: 0,
            speakerLabel: "Speaker 0",
            startTime: start,
            endTime: end,
            text: text,
            confidence: confidence,
            noSpeechProbability: 0.05,
            words: words
        )
    }

    private func makeResult(segments: [TranscriptSegment]) -> TranscriptResult {
        TranscriptResult(
            transcriptionMethodId: "large-v3_turbo",
            language: "en",
            speakerCount: 1,
            segments: segments,
            speakerEmbeddings: [:],
            processingDuration: 5.0
        )
    }

    // MARK: - Segment past audio duration (the regression case)

    @Test("Drops segment timestamped past audio length (52.5s on 25.1s clip)")
    func dropsSegmentPastAudioDuration() {
        let validSegment = makeSegment(start: 0.0, end: 10.0, text: "Valid speech")
        let hallucinatedSegment = makeSegment(
            start: 52.5, end: 55.0, text: "Thank you."
        )

        let result = makeResult(segments: [validSegment, hallucinatedSegment])
        let sanitized = TranscriptSanitizer.sanitize(result, audioDuration: 25.1)

        #expect(sanitized.segments.count == 1)
        #expect(sanitized.segments[0].text == "Valid speech")
    }

    @Test("Keeps segments within audio duration")
    func keepsInRangeSegments() {
        let seg1 = makeSegment(start: 0.0, end: 5.0, text: "First")
        let seg2 = makeSegment(start: 5.0, end: 10.0, text: "Second")
        let seg3 = makeSegment(start: 10.0, end: 15.0, text: "Third")

        let result = makeResult(segments: [seg1, seg2, seg3])
        let sanitized = TranscriptSanitizer.sanitize(result, audioDuration: 20.0)

        #expect(sanitized.segments.count == 3)
    }

    @Test("Clamps endTime that exceeds audio duration")
    func clampsEndTimePastDuration() {
        let segment = makeSegment(start: 20.0, end: 30.0, text: "Overlapping end")

        let result = makeResult(segments: [segment])
        let sanitized = TranscriptSanitizer.sanitize(result, audioDuration: 25.0)

        #expect(sanitized.segments.count == 1)
        #expect(sanitized.segments[0].endTime == 25.0)
        #expect(sanitized.segments[0].startTime == 20.0)
        #expect(sanitized.segments[0].text == "Overlapping end")
    }

    @Test("Drops segment whose startTime equals audio duration")
    func dropsSegmentAtExactDuration() {
        let segment = makeSegment(start: 25.1, end: 27.0, text: "At boundary")

        let result = makeResult(segments: [segment])
        let sanitized = TranscriptSanitizer.sanitize(result, audioDuration: 25.1)

        #expect(sanitized.segments.isEmpty)
    }

    // MARK: - Confidence derivation

    @Test("Derives confidence from word-level probability, ignoring segment confidence==0")
    func derivesConfidenceFromWords() throws {
        let words = [
            makeWord("hello", start: 0, end: 0.5, probability: 0.8),
            makeWord("world", start: 0.5, end: 1.0, probability: 0.6)
        ]

        // segment confidence is 0 (unreliable SDK value) -- should be ignored
        let segment = makeSegment(
            start: 0.0, end: 1.0, text: "hello world",
            confidence: 0.0, words: words
        )

        let derived = TranscriptSanitizer.deriveConfidence(from: segment)
        #expect(derived != nil)

        // Average of 0.8 and 0.6 = 0.7
        let expected: Float = 0.7
        #expect(try abs(#require(derived) - expected) < 0.001)
    }

    @Test("Returns nil confidence when no words are available")
    func nilConfidenceWithoutWords() {
        let segment = makeSegment(start: 0, end: 1, confidence: 0.5, words: nil)
        #expect(TranscriptSanitizer.deriveConfidence(from: segment) == nil)
    }

    @Test("Returns nil confidence for empty words array")
    func nilConfidenceEmptyWords() {
        let segment = makeSegment(start: 0, end: 1, confidence: 0.5, words: [])
        #expect(TranscriptSanitizer.deriveConfidence(from: segment) == nil)
    }

    // MARK: - Trailing low-confidence single-word segments

    @Test("Drops trailing single-word segment with low probability")
    func dropsLowConfidenceTrailingSingleWord() {
        let goodSegment = makeSegment(
            start: 0, end: 5, text: "Good speech",
            words: [makeWord("Good", start: 0, end: 2, probability: 0.9),
                    makeWord("speech", start: 2, end: 5, probability: 0.85)]
        )
        let badTrailing = makeSegment(
            start: 5, end: 6, text: "um",
            words: [makeWord("um", start: 5, end: 6, probability: 0.1)]
        )

        let result = makeResult(segments: [goodSegment, badTrailing])
        let sanitized = TranscriptSanitizer.sanitize(result, audioDuration: 10.0)

        #expect(sanitized.segments.count == 1)
        #expect(sanitized.segments[0].text == "Good speech")
    }

    @Test("Keeps trailing single-word segment with high probability")
    func keepsHighConfidenceTrailingSingleWord() {
        let goodSegment = makeSegment(
            start: 0, end: 5, text: "Good speech",
            words: [makeWord("Good", start: 0, end: 2, probability: 0.9),
                    makeWord("speech", start: 2, end: 5, probability: 0.85)]
        )
        let goodTrailing = makeSegment(
            start: 5, end: 6, text: "goodbye",
            words: [makeWord("goodbye", start: 5, end: 6, probability: 0.8)]
        )

        let result = makeResult(segments: [goodSegment, goodTrailing])
        let sanitized = TranscriptSanitizer.sanitize(result, audioDuration: 10.0)

        #expect(sanitized.segments.count == 2)
    }

    @Test("Does not drop trailing multi-word segment even with low probability")
    func keepsLowConfidenceMultiWordTrailing() {
        let trailing = makeSegment(
            start: 5, end: 7, text: "um ah",
            words: [
                makeWord("um", start: 5, end: 6, probability: 0.1),
                makeWord("ah", start: 6, end: 7, probability: 0.1)
            ]
        )

        let result = makeResult(segments: [trailing])
        let sanitized = TranscriptSanitizer.sanitize(result, audioDuration: 10.0)

        #expect(sanitized.segments.count == 1)
    }

    // MARK: - Result metadata preservation

    @Test("Sanitization preserves result metadata")
    func preservesMetadata() {
        let segment = makeSegment(start: 0, end: 5, text: "Test")
        let result = makeResult(segments: [segment])

        let sanitized = TranscriptSanitizer.sanitize(result, audioDuration: 10.0)

        #expect(sanitized.id == result.id)
        #expect(sanitized.createdAt == result.createdAt)
        #expect(sanitized.transcriptionMethodId == result.transcriptionMethodId)
        #expect(sanitized.language == result.language)
        #expect(sanitized.speakerCount == result.speakerCount)
        #expect(sanitized.processingDuration == result.processingDuration)
    }

    @Test("Empty result stays empty after sanitization")
    func emptyResultStaysEmpty() {
        let result = makeResult(segments: [])
        let sanitized = TranscriptSanitizer.sanitize(result, audioDuration: 10.0)

        #expect(sanitized.segments.isEmpty)
    }

    // MARK: - Combined scenario

    @Test("Full regression scenario: hallucinated segment at 52.5s on 25.1s clip is dropped")
    func fullRegressionScenario() throws {
        let realWords = [
            makeWord("Hello", start: 0, end: 0.5, probability: 0.95),
            makeWord("everyone", start: 0.5, end: 1.2, probability: 0.88)
        ]
        let hallucinatedWords = [
            makeWord("Thank", start: 52.5, end: 53.0, probability: 0.4),
            makeWord("you", start: 53.0, end: 53.5, probability: 0.35)
        ]

        let realSegment = makeSegment(
            start: 0, end: 1.2, text: "Hello everyone",
            confidence: 0, words: realWords
        )
        let hallucinatedSegment = makeSegment(
            start: 52.5, end: 53.5, text: "Thank you",
            confidence: 0, words: hallucinatedWords
        )

        let result = makeResult(segments: [realSegment, hallucinatedSegment])
        let sanitized = TranscriptSanitizer.sanitize(result, audioDuration: 25.1)

        #expect(sanitized.segments.count == 1)
        #expect(sanitized.segments[0].text == "Hello everyone")

        // Confidence derived from word probabilities, not segment-level confidence==0
        let derivedConf = TranscriptSanitizer.deriveConfidence(from: sanitized.segments[0])
        #expect(derivedConf != nil)
        let expected: Float = (0.95 + 0.88) / 2.0
        #expect(try abs(#require(derivedConf) - expected) < 0.001)
    }
}

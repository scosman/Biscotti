import Foundation
import Testing
@testable import Transcription

@Suite("TranscriptResult Codable & Structure")
struct ResultCodableTests {
    // MARK: - TranscriptWord

    @Test("TranscriptWord round-trips through JSON")
    func transcriptWordCodable() throws {
        let word = TranscriptWord(
            word: "hello",
            startTime: 1.5,
            endTime: 2.0,
            probability: 0.95,
            speakerID: 0
        )

        let data = try JSONEncoder().encode(word)
        let decoded = try JSONDecoder().decode(TranscriptWord.self, from: data)

        #expect(decoded.word == "hello")
        #expect(decoded.startTime == 1.5)
        #expect(decoded.endTime == 2.0)
        #expect(decoded.probability == 0.95)
        #expect(decoded.speakerID == 0)
    }

    @Test("TranscriptWord with nil speakerID round-trips")
    func transcriptWordNilSpeaker() throws {
        let word = TranscriptWord(
            word: "test",
            startTime: 0,
            endTime: 0.5,
            probability: 0.8,
            speakerID: nil
        )

        let data = try JSONEncoder().encode(word)
        let decoded = try JSONDecoder().decode(TranscriptWord.self, from: data)

        #expect(decoded.speakerID == nil)
    }

    // MARK: - TranscriptSegment

    @Test("TranscriptSegment has all expected fields and round-trips")
    func transcriptSegmentCodable() throws {
        let words = [
            TranscriptWord(word: "Hi", startTime: 0, endTime: 0.3, probability: 0.9, speakerID: 1),
            TranscriptWord(word: "there", startTime: 0.3, endTime: 0.8, probability: 0.85, speakerID: 1)
        ]

        let segment = TranscriptSegment(
            speakerID: 1,
            speakerLabel: "Speaker 1",
            startTime: 0.0,
            endTime: 0.8,
            text: "Hi there",
            confidence: -0.3,
            noSpeechProbability: 0.05,
            words: words
        )

        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)

        #expect(decoded.id == segment.id)
        #expect(decoded.speakerID == 1)
        #expect(decoded.speakerLabel == "Speaker 1")
        #expect(decoded.startTime == 0.0)
        #expect(decoded.endTime == 0.8)
        #expect(decoded.text == "Hi there")
        #expect(decoded.confidence == -0.3)
        #expect(decoded.noSpeechProbability == 0.05)
        #expect(decoded.words?.count == 2)
    }

    @Test("TranscriptSegment with nil words round-trips")
    func transcriptSegmentNilWords() throws {
        let segment = TranscriptSegment(
            speakerID: nil,
            speakerLabel: "Unknown",
            startTime: 5.0,
            endTime: 8.0,
            text: "some text",
            confidence: -0.5,
            noSpeechProbability: 0.1,
            words: nil
        )

        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)

        #expect(decoded.speakerID == nil)
        #expect(decoded.speakerLabel == "Unknown")
        #expect(decoded.words == nil)
    }

    @Test("TranscriptSegment conforms to Identifiable")
    func transcriptSegmentIdentifiable() {
        let segment = TranscriptSegment(
            speakerID: 0,
            speakerLabel: "Speaker 0",
            startTime: 0,
            endTime: 1,
            text: "test",
            confidence: 0,
            noSpeechProbability: 0,
            words: nil
        )

        let _: UUID = segment.id
    }

    // MARK: - TranscriptResult

    @Test("TranscriptResult round-trips through JSON")
    func transcriptResultCodable() throws {
        let segment = TranscriptSegment(
            speakerID: 0,
            speakerLabel: "Speaker 0",
            startTime: 0,
            endTime: 3.5,
            text: "Hello world",
            confidence: -0.2,
            noSpeechProbability: 0.02,
            words: nil
        )

        let result = TranscriptResult(
            transcriptionMethodId: "large-v3_turbo",
            language: "en",
            speakerCount: 2,
            segments: [segment],
            speakerEmbeddings: [0: [0.1, 0.2, 0.3], 1: [0.4, 0.5, 0.6]],
            processingDuration: 12.5
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TranscriptResult.self, from: data)

        #expect(decoded.id == result.id)
        #expect(decoded.transcriptionMethodId == "large-v3_turbo")
        #expect(decoded.language == "en")
        #expect(decoded.speakerCount == 2)
        #expect(decoded.segments.count == 1)
        #expect(decoded.segments[0].text == "Hello world")
        #expect(decoded.processingDuration == 12.5)
    }

    @Test("Speaker embeddings dictionary survives Codable round-trip")
    func speakerEmbeddingsCodable() throws {
        let embeddings: [Int: [Float]] = [
            0: [0.1, 0.2, 0.3, 0.4, 0.5],
            1: [-0.1, -0.2, -0.3, -0.4, -0.5],
            2: [1.0, 0.0, -1.0, 0.5, -0.5]
        ]

        let result = TranscriptResult(
            transcriptionMethodId: "test",
            language: "en",
            speakerCount: 3,
            segments: [],
            speakerEmbeddings: embeddings,
            processingDuration: 0
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TranscriptResult.self, from: data)

        #expect(decoded.speakerEmbeddings.count == 3)
        #expect(decoded.speakerEmbeddings[0] == [0.1, 0.2, 0.3, 0.4, 0.5])
        #expect(decoded.speakerEmbeddings[1] == [-0.1, -0.2, -0.3, -0.4, -0.5])
        #expect(decoded.speakerEmbeddings[2] == [1.0, 0.0, -1.0, 0.5, -0.5])
    }

    @Test("TranscriptResult conforms to Identifiable")
    func transcriptResultIdentifiable() {
        let result = TranscriptResult(
            transcriptionMethodId: "test",
            language: "en",
            speakerCount: 0,
            segments: [],
            speakerEmbeddings: [:],
            processingDuration: 0
        )

        let _: UUID = result.id
    }

    @Test("TranscriptResult with empty segments round-trips")
    func emptySegmentsRoundTrip() throws {
        let result = TranscriptResult(
            transcriptionMethodId: "large-v3_turbo_1307MB",
            language: "fr",
            speakerCount: 0,
            segments: [],
            speakerEmbeddings: [:],
            processingDuration: 0.5
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TranscriptResult.self, from: data)

        #expect(decoded.segments.isEmpty)
        #expect(decoded.speakerEmbeddings.isEmpty)
        #expect(decoded.language == "fr")
    }

    @Test("JSON contains expected field names")
    func jsonFieldNames() throws {
        let result = TranscriptResult(
            transcriptionMethodId: "test",
            language: "en",
            speakerCount: 1,
            segments: [],
            speakerEmbeddings: [:],
            processingDuration: 1.0
        )

        let data = try JSONEncoder().encode(result)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        #expect(jsonString.contains("\"transcriptionMethodId\""))
        #expect(jsonString.contains("\"language\""))
        #expect(jsonString.contains("\"speakerCount\""))
        #expect(jsonString.contains("\"segments\""))
        #expect(jsonString.contains("\"speakerEmbeddings\""))
        #expect(jsonString.contains("\"processingDuration\""))
        #expect(jsonString.contains("\"createdAt\""))
    }
}

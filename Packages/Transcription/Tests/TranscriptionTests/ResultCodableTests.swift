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

    // MARK: - Embedding types

    @Test("EmbeddingKind round-trips through JSON")
    func embeddingKindCodable() throws {
        for kind in EmbeddingKind.allCases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(EmbeddingKind.self, from: data)
            #expect(decoded == kind)
        }
    }

    @Test("SpeakerEmbeddingSet round-trips through JSON")
    func embeddingSetCodable() throws {
        let set = SpeakerEmbeddingSet(
            kind: .plda,
            space: "pyannote-v3/W8A16+plda:pyannote-v4/W32A32",
            vectors: [0: [0.1, 0.2], 1: [0.3, 0.4]]
        )

        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(SpeakerEmbeddingSet.self, from: data)

        #expect(decoded.kind == .plda)
        #expect(decoded.space == "pyannote-v3/W8A16+plda:pyannote-v4/W32A32")
        #expect(decoded.vectors.count == 2)
        #expect(decoded.vectors[0] == [0.1, 0.2])
        #expect(decoded.vectors[1] == [0.3, 0.4])
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

        let sets = [
            SpeakerEmbeddingSet(
                kind: .raw, space: "pyannote-v3/W8A16",
                vectors: [0: [0.1, 0.2, 0.3], 1: [0.4, 0.5, 0.6]]
            ),
            SpeakerEmbeddingSet(
                kind: .plda, space: "pyannote-v3/W8A16+plda:pyannote-v4/W32A32",
                vectors: [0: [0.7, 0.8], 1: [0.9, 1.0]]
            )
        ]

        let result = TranscriptResult(
            transcriptionMethodId: "large-v3_turbo",
            language: "en",
            speakerCount: 2,
            segments: [segment],
            embeddingSets: sets,
            speakerSpeechDurations: [0: 45.0, 1: 120.5],
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
        #expect(decoded.embeddingSets.count == 2)
        #expect(decoded.embeddingSets[0].kind == .raw)
        #expect(decoded.embeddingSets[1].kind == .plda)
        #expect(decoded.speakerSpeechDurations[0] == 45.0)
        #expect(decoded.speakerSpeechDurations[1] == 120.5)
        #expect(decoded.processingDuration == 12.5)
    }

    @Test("TranscriptResult conforms to Identifiable")
    func transcriptResultIdentifiable() {
        let result = TranscriptResult(
            transcriptionMethodId: "test",
            language: "en",
            speakerCount: 0,
            segments: [],
            processingDuration: 0
        )

        let _: UUID = result.id
    }

    @Test("TranscriptResult with empty sets and durations round-trips")
    func emptyEmbeddingSetsRoundTrip() throws {
        let result = TranscriptResult(
            transcriptionMethodId: "large-v3_turbo_1307MB",
            language: "fr",
            speakerCount: 0,
            segments: [],
            processingDuration: 0.5
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TranscriptResult.self, from: data)

        #expect(decoded.segments.isEmpty)
        #expect(decoded.embeddingSets.isEmpty)
        #expect(decoded.speakerSpeechDurations.isEmpty)
        #expect(decoded.language == "fr")
    }

    @Test("JSON contains expected field names")
    func jsonFieldNames() throws {
        let result = TranscriptResult(
            transcriptionMethodId: "test",
            language: "en",
            speakerCount: 1,
            segments: [],
            embeddingSets: [
                SpeakerEmbeddingSet(kind: .raw, space: "test", vectors: [0: [1.0]])
            ],
            speakerSpeechDurations: [0: 30.0],
            processingDuration: 1.0
        )

        let data = try JSONEncoder().encode(result)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        #expect(jsonString.contains("\"transcriptionMethodId\""))
        #expect(jsonString.contains("\"language\""))
        #expect(jsonString.contains("\"speakerCount\""))
        #expect(jsonString.contains("\"segments\""))
        #expect(jsonString.contains("\"embeddingSets\""))
        #expect(jsonString.contains("\"speakerSpeechDurations\""))
        #expect(jsonString.contains("\"processingDuration\""))
        #expect(jsonString.contains("\"createdAt\""))
    }
}

import DataStore
import Foundation
import Testing
import Transcription

@Suite("Segment and word mapping from TranscriptResult")
struct SegmentMappingTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    private func makeTwoSegmentResult() -> TranscriptResult {
        TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 2,
            segments: [
                TranscriptSegment(
                    speakerID: 0,
                    speakerLabel: "Speaker 0",
                    startTime: 0.0,
                    endTime: 3.5,
                    text: "Hello world",
                    confidence: 0.9,
                    noSpeechProbability: 0.01,
                    words: nil
                ),
                TranscriptSegment(
                    speakerID: 1,
                    speakerLabel: "Speaker 1",
                    startTime: 3.5,
                    endTime: 7.0,
                    text: "Hi there",
                    confidence: 0.85,
                    noSpeechProbability: 0.02,
                    words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 2.0
        )
    }

    @Test("Segments are mapped with correct index ordering and fields")
    func segmentMappingOrder() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Segment test")

        let transcriptID = try await store.addTranscript(
            makeTwoSegmentResult(),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            let transcript = meeting?.transcripts.first(where: { $0.id == transcriptID })
            let segments = transcript?.segments.sorted(by: { $0.index < $1.index }) ?? []

            #expect(segments.count == 2)

            // First segment
            #expect(segments[0].index == 0)
            #expect(segments[0].speakerID == 0)
            #expect(segments[0].speakerLabel == "Speaker 0")
            #expect(segments[0].startTime == 0.0)
            #expect(segments[0].endTime == 3.5)
            #expect(segments[0].text == "Hello world")
            #expect(segments[0].noSpeechProbability == 0.01)

            // Second segment
            #expect(segments[1].index == 1)
            #expect(segments[1].speakerID == 1)
            #expect(segments[1].speakerLabel == "Speaker 1")
            #expect(segments[1].startTime == 3.5)
            #expect(segments[1].endTime == 7.0)
            #expect(segments[1].text == "Hi there")
        }
    }

    @Test("Words are mapped with correct index ordering and fields")
    func wordMappingOrder() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Word test")

        let words = [
            TranscriptWord(word: "Hello", startTime: 0.0, endTime: 0.5, probability: 0.95, speakerID: 0),
            TranscriptWord(word: "world", startTime: 0.5, endTime: 1.0, probability: 0.88, speakerID: 0),
            TranscriptWord(word: "test", startTime: 1.0, endTime: 1.5, probability: 0.92, speakerID: nil)
        ]

        let result = TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 1,
            segments: [
                TranscriptSegment(
                    speakerID: 0,
                    speakerLabel: "Speaker 0",
                    startTime: 0.0,
                    endTime: 1.5,
                    text: "Hello world test",
                    confidence: 0.9,
                    noSpeechProbability: 0.01,
                    words: words
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 1.0
        )

        let transcriptID = try await store.addTranscript(
            result,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        try await store.read { store in
            let transcript = try store.meeting(id: meetingID)?.transcripts.first(where: { $0.id == transcriptID })
            let mappedWords = transcript?.segments.first?.words.sorted(by: { $0.index < $1.index }) ?? []

            #expect(mappedWords.count == 3)

            #expect(mappedWords[0].index == 0)
            #expect(mappedWords[0].word == "Hello")
            #expect(mappedWords[0].startTime == 0.0)
            #expect(mappedWords[0].endTime == 0.5)
            #expect(mappedWords[0].probability == 0.95)
            #expect(mappedWords[0].speakerID == 0)

            #expect(mappedWords[1].index == 1)
            #expect(mappedWords[1].word == "world")
            #expect(mappedWords[1].probability == 0.88)

            #expect(mappedWords[2].index == 2)
            #expect(mappedWords[2].word == "test")
            #expect(mappedWords[2].speakerID == nil)
        }
    }

    @Test("Segment with nil speakerID is preserved")
    func nilSpeakerID() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Nil speaker")

        let result = TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 0,
            segments: [
                TranscriptSegment(
                    speakerID: nil,
                    speakerLabel: "Unknown",
                    startTime: 0.0,
                    endTime: 2.0,
                    text: "No speaker",
                    confidence: 0.5,
                    noSpeechProbability: 0.1,
                    words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 0.5
        )

        let transcriptID = try await store.addTranscript(
            result,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            let transcript = meeting?.transcripts.first(where: { $0.id == transcriptID })
            let segment = transcript?.segments.first
            #expect(segment?.speakerID == nil)
            #expect(segment?.speakerLabel == "Unknown")
        }
    }

    @Test("Segment with no words results in empty words array")
    func segmentWithNoWords() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No words")

        let result = TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 1,
            segments: [
                TranscriptSegment(
                    speakerID: 0,
                    speakerLabel: "Speaker 0",
                    startTime: 0.0,
                    endTime: 2.0,
                    text: "Hello",
                    confidence: 0.9,
                    noSpeechProbability: 0.01,
                    words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 0.5
        )

        let transcriptID = try await store.addTranscript(
            result,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            let transcript = meeting?.transcripts.first(where: { $0.id == transcriptID })
            let segment = transcript?.segments.first
            #expect(segment?.words.isEmpty == true)
        }
    }

    @Test("Transcript output fields (language, speakerCount) round-trip correctly")
    func outputFieldsRoundTrip() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Output fields")

        let result = TranscriptResult(
            transcriptionMethodId: "v1",
            language: "fr",
            speakerCount: 3,
            segments: [],
            speakerEmbeddings: [:],
            processingDuration: 5.0
        )

        let transcriptID = try await store.addTranscript(
            result,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            let transcript = meeting?.transcripts.first(where: { $0.id == transcriptID })
            #expect(transcript?.language == "fr")
            #expect(transcript?.speakerCount == 3)
        }
    }
}

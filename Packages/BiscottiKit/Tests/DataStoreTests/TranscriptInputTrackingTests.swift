import DataStore
import Foundation
import Testing
import Transcription

@Suite("Transcript input tracking and staleness")
struct TranscriptInputTrackingTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    private func makeResult(methodId: String = "v1") -> TranscriptResult {
        TranscriptResult(
            transcriptionMethodId: methodId,
            language: "en",
            speakerCount: 1,
            segments: [
                TranscriptSegment(
                    speakerID: 0,
                    speakerLabel: "Speaker 0",
                    startTime: 0,
                    endTime: 5,
                    text: "Hello world",
                    confidence: 0.9,
                    noSpeechProbability: 0.01,
                    words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 1.0
        )
    }

    @Test("addTranscript persists transcriptionMethodId")
    func persistsMethodId() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Method tracking")
        let transcriptID = try await store.addTranscript(
            makeResult(methodId: "v1"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            let transcript = meeting?.transcripts.first(where: { $0.id == transcriptID })
            #expect(transcript?.transcriptionMethodId == "v1")
        }
    }

    @Test("addTranscript persists vocabularyUsed")
    func persistsVocabulary() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Vocab tracking")
        let vocab = ["Biscotti", "SwiftData"]
        let transcriptID = try await store.addTranscript(
            makeResult(),
            vocabularyUsed: vocab,
            mappedEventIdentifier: nil,
            to: meetingID
        )

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            let transcript = meeting?.transcripts.first(where: { $0.id == transcriptID })
            #expect(transcript?.vocabularyUsed == vocab)
        }
    }

    @Test("addTranscript persists mappedEventIdentifier")
    func persistsMappedEvent() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Event tracking")
        let transcriptID = try await store.addTranscript(
            makeResult(),
            vocabularyUsed: [],
            mappedEventIdentifier: "event-123",
            to: meetingID
        )

        try await store.read { store in
            let meeting = try store.meeting(id: meetingID)
            let transcript = meeting?.transcripts.first(where: { $0.id == transcriptID })
            #expect(transcript?.mappedEventIdentifier == "event-123")
        }
    }

    @Test("preferredTranscriptIsStale returns false for identical inputs")
    func notStaleWhenIdentical() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Not stale")
        let vocab = ["Biscotti"]
        let transcriptID = try await store.addTranscript(
            makeResult(methodId: "v1"),
            vocabularyUsed: vocab,
            mappedEventIdentifier: "event-1",
            to: meetingID
        )
        try await store.setPreferredTranscript(transcriptID, for: meetingID)

        let stale = try await store.preferredTranscriptIsStale(
            meetingID: meetingID,
            currentMethodId: "v1",
            currentVocabulary: vocab,
            currentEventIdentifier: "event-1"
        )
        #expect(stale == false)
    }

    @Test("preferredTranscriptIsStale returns true when method id differs")
    func staleOnMethodChange() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Stale method")
        let transcriptID = try await store.addTranscript(
            makeResult(methodId: "v1"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await store.setPreferredTranscript(transcriptID, for: meetingID)

        let stale = try await store.preferredTranscriptIsStale(
            meetingID: meetingID,
            currentMethodId: "v2",
            currentVocabulary: [],
            currentEventIdentifier: nil
        )
        #expect(stale == true)
    }

    @Test("preferredTranscriptIsStale returns true when vocabulary differs")
    func staleOnVocabChange() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Stale vocab")
        let transcriptID = try await store.addTranscript(
            makeResult(methodId: "v1"),
            vocabularyUsed: ["old"],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await store.setPreferredTranscript(transcriptID, for: meetingID)

        let stale = try await store.preferredTranscriptIsStale(
            meetingID: meetingID,
            currentMethodId: "v1",
            currentVocabulary: ["new"],
            currentEventIdentifier: nil
        )
        #expect(stale == true)
    }

    @Test("preferredTranscriptIsStale returns true when event mapping differs")
    func staleOnEventChange() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Stale event")
        let transcriptID = try await store.addTranscript(
            makeResult(methodId: "v1"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await store.setPreferredTranscript(transcriptID, for: meetingID)

        let stale = try await store.preferredTranscriptIsStale(
            meetingID: meetingID,
            currentMethodId: "v1",
            currentVocabulary: [],
            currentEventIdentifier: "event-new"
        )
        #expect(stale == true)
    }

    @Test("preferredTranscriptIsStale returns false when no preferred transcript set")
    func notStaleWithNoPreferred() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No preferred")
        // Add a transcript but don't set it as preferred
        _ = try await store.addTranscript(
            makeResult(),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        let stale = try await store.preferredTranscriptIsStale(
            meetingID: meetingID,
            currentMethodId: "v1",
            currentVocabulary: [],
            currentEventIdentifier: nil
        )
        #expect(stale == false)
    }
}

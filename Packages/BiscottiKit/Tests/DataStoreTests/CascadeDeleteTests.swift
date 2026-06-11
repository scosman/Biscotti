import DataStore
import Foundation
import Testing
import Transcription

@Suite("Cascade delete verification")
struct CascadeDeleteTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    private func makeResult() -> TranscriptResult {
        let words = [
            TranscriptWord(
                word: "Hello",
                startTime: 0.0,
                endTime: 0.5,
                probability: 0.95,
                speakerID: 0
            ),
            TranscriptWord(
                word: "world",
                startTime: 0.5,
                endTime: 1.0,
                probability: 0.9,
                speakerID: 0
            )
        ]
        let segments = [
            TranscriptSegment(
                speakerID: 0,
                speakerLabel: "Speaker 0",
                startTime: 0.0,
                endTime: 5.0,
                text: "Hello world",
                confidence: 0.9,
                noSpeechProbability: 0.01,
                words: words
            ),
            TranscriptSegment(
                speakerID: 1,
                speakerLabel: "Speaker 1",
                startTime: 5.0,
                endTime: 10.0,
                text: "Goodbye world",
                confidence: 0.85,
                noSpeechProbability: 0.02,
                words: nil
            )
        ]
        return TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 2,
            segments: segments,
            speakerEmbeddings: [:],
            processingDuration: 1.0
        )
    }

    @Test("Deleting a meeting cascades to transcripts, segments, words, audio refs, and snapshot but not Person")
    func cascadeDeleteRemovesChildren() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Cascade test")

        // Add a transcript with segments and words
        _ = try await store.addTranscript(
            makeResult(),
            vocabularyUsed: ["test"],
            mappedEventIdentifier: "ev-1",
            to: meetingID
        )

        // Attach audio refs
        let mic = AudioFileRef(role: .mic, path: "/tmp/mic.aac", byteSize: 1024)
        let system = AudioFileRef(
            role: .system, path: "/tmp/sys.aac", byteSize: 2048
        )
        try await store.attachAudio([mic, system], to: meetingID)

        // Set a calendar snapshot
        let snapshot = CalendarSnapshot(
            eventIdentifier: "ek-999",
            compositeKey: "cascade|test",
            title: "Cascade Event"
        )
        try await store.setSnapshot(snapshot, for: meetingID)

        // Add a participant (shared Person -- should survive deletion)
        let personID = try await store.findOrCreatePerson(
            name: "Alice", email: "alice@test.com"
        )
        try await store.setParticipants(
            [personID], organizer: personID, for: meetingID
        )

        // Verify children exist before delete
        #expect(try await store.fetchAllTranscripts().count == 1)
        #expect(try await store.fetchAllSegments().count == 2)
        #expect(try await store.fetchAllWords().count == 2)
        #expect(try await store.fetchAllAudioRefs().count == 2)
        #expect(try await store.fetchAllSnapshots().count == 1)
        #expect(try await store.fetchAllPersons().count == 1)

        // Delete the meeting
        try await store.delete(meetingID: meetingID)

        // All owned children should be cascade-deleted
        #expect(try await store.fetchAllTranscripts().isEmpty)
        #expect(try await store.fetchAllSegments().isEmpty)
        #expect(try await store.fetchAllWords().isEmpty)
        #expect(try await store.fetchAllAudioRefs().isEmpty)
        #expect(try await store.fetchAllSnapshots().isEmpty)

        // Shared Person should survive
        #expect(try await store.fetchAllPersons().count == 1)
    }

    @Test("Deleting one meeting preserves shared Person linked to another meeting")
    func deleteOnePreservesSharedPerson() async throws {
        let store = try makeStore()

        // Create two meetings
        let id1 = try await store.createMeeting(title: "Meeting A")
        let id2 = try await store.createMeeting(title: "Meeting B")

        // Create a person shared across both meetings
        let personID = try await store.findOrCreatePerson(
            name: "Bob", email: "bob@test.com"
        )
        try await store.setParticipants(
            [personID], organizer: personID, for: id1
        )
        try await store.setParticipants(
            [personID], organizer: personID, for: id2
        )

        // Give Meeting A a calendar snapshot (cascade target)
        let snapshot = CalendarSnapshot(
            eventIdentifier: "ev-shared",
            compositeKey: "shared|test",
            title: "Shared Event"
        )
        try await store.setSnapshot(snapshot, for: id1)

        // Verify setup
        #expect(try await store.fetchAllPersons().count == 1)
        #expect(try await store.fetchAllSnapshots().count == 1)

        // Delete Meeting A
        try await store.delete(meetingID: id1)

        // Meeting B and the shared Person must survive
        #expect(try await store.meeting(id: id2) != nil)
        #expect(try await store.meeting(id: id2)?.title == "Meeting B")
        #expect(try await store.fetchAllPersons().count == 1)
        #expect(try await store.fetchAllPersons().first?.name == "Bob")

        // Meeting A's snapshot should be gone (cascade)
        #expect(try await store.fetchAllSnapshots().isEmpty)

        // Meeting A should be gone
        #expect(try await store.meeting(id: id1) == nil)
    }
}

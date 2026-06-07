import DataStore
import Foundation
import Testing
import Transcription

@Suite("Transcript versioning")
struct TranscriptVersioningTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    private func makeResult(methodId: String = "v1", segmentCount: Int = 1) -> TranscriptResult {
        let segments = (0 ..< segmentCount).map { idx in
            TranscriptSegment(
                speakerID: 0,
                speakerLabel: "Speaker 0",
                startTime: Double(idx) * 5.0,
                endTime: Double(idx) * 5.0 + 5.0,
                text: "Segment \(idx)",
                confidence: 0.9,
                noSpeechProbability: 0.01,
                words: nil
            )
        }
        return TranscriptResult(
            transcriptionMethodId: methodId,
            language: "en",
            speakerCount: 1,
            segments: segments,
            speakerEmbeddings: [:],
            processingDuration: 1.0
        )
    }

    @Test("Adding multiple transcripts preserves all versions")
    func multipleVersionsPreserved() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Versioned")

        let id1 = try await store.addTranscript(
            makeResult(methodId: "v1"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        let id2 = try await store.addTranscript(
            makeResult(methodId: "v2"),
            vocabularyUsed: ["Biscotti"],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        let meeting = try await store.meeting(id: meetingID)
        #expect(meeting?.transcripts.count == 2)

        let ids = meeting?.transcripts.map(\.id) ?? []
        #expect(ids.contains(id1))
        #expect(ids.contains(id2))
    }

    @Test("Adding a new version never drops prior versions")
    func addingNeverDropsPrior() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "History")

        let first = try await store.addTranscript(
            makeResult(methodId: "v1"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        // Add a second
        _ = try await store.addTranscript(
            makeResult(methodId: "v2"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        // First should still be there
        let meeting = try await store.meeting(id: meetingID)
        #expect(meeting?.transcripts.contains(where: { $0.id == first }) == true)
    }

    @Test("setPreferredTranscript updates preferredTranscriptID")
    func setPreferredUpdates() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Preferred")

        let id1 = try await store.addTranscript(
            makeResult(methodId: "v1"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        let id2 = try await store.addTranscript(
            makeResult(methodId: "v2"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        try await store.setPreferredTranscript(id1, for: meetingID)
        var meeting = try await store.meeting(id: meetingID)
        #expect(meeting?.preferredTranscriptID == id1)

        try await store.setPreferredTranscript(id2, for: meetingID)
        meeting = try await store.meeting(id: meetingID)
        #expect(meeting?.preferredTranscriptID == id2)
    }

    @Test("addTranscript to non-existent meeting throws notFound")
    func addToMissingMeeting() async throws {
        let store = try makeStore()
        let bogus = UUID()
        await #expect(throws: DataStoreError.notFound(bogus)) {
            try await store.addTranscript(
                makeResult(),
                vocabularyUsed: [],
                mappedEventIdentifier: nil,
                to: bogus
            )
        }
    }

    @Test("setPreferredTranscript on non-existent meeting throws notFound")
    func setPreferredMissingMeeting() async throws {
        let store = try makeStore()
        let bogus = UUID()
        await #expect(throws: DataStoreError.notFound(bogus)) {
            try await store.setPreferredTranscript(UUID(), for: bogus)
        }
    }

    @Test("setPreferredTranscript throws notFound for transcript not belonging to meeting")
    func setPreferredForeignTranscript() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Guarded")

        // Add a real transcript so the meeting has one
        _ = try await store.addTranscript(
            makeResult(methodId: "v1"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        // Try to set a bogus transcript ID that doesn't belong to this meeting
        let bogusTranscriptID = UUID()
        await #expect(throws: DataStoreError.notFound(bogusTranscriptID)) {
            try await store.setPreferredTranscript(bogusTranscriptID, for: meetingID)
        }
    }
}

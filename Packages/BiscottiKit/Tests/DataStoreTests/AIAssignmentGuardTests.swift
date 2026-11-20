import DataStore
import Foundation
import Testing
import Transcription

/// The AI can't put a hand-assigned person on another speaker.
struct AIAssignmentGuardTests {
    @Test func aiCannotReuseAHandAssignedPerson() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Guard")
        let sam = try await store.findOrCreatePerson(name: "Sam Carter", email: nil)
        let jordan = try await store.findOrCreatePerson(name: "Jordan Kelbo", email: nil)
        let transcriptID = try await store.addTranscript(
            .init(transcriptionMethodId: "v2", language: "en", speakerCount: 3, segments: [], processingDuration: 0),
            vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setSpeakerAssignment(speakerID: 0, personID: sam, for: transcriptID)
        try await store.setSpeakerAssignments([2: sam, 1: jordan], for: transcriptID)
        let names = try #require(try await store.transcript(id: transcriptID)).speakerAssignments
        #expect(names[0]?.name == "Sam Carter")
        #expect(names[2] == nil)
        #expect(names[1]?.name == "Jordan Kelbo")
    }
}

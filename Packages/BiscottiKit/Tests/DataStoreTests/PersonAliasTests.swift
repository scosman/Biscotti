import DataStore
import Foundation
import Testing
import Transcription

/// One person under every name they show up as.
struct PersonAliasTests {
    @Test func namesInAnotherOrderFindTheSamePerson() async throws {
        let store = try DataStore(storage: .inMemory)
        let maria = try await store.findOrCreatePerson(name: "Maria Lopez", email: nil)
        #expect(try await store.findOrCreatePerson(name: "Lopez, Maria", email: nil) == maria)
        #expect(try await store.findOrCreatePerson(name: "Lopez, Maria (AGENCY)", email: nil) == maria)
        #expect(PersonAlias.key("Lopez, Maria (AGENCY)") == "maria lopez")
    }

    @Test func correctingAScreenNameTeachesAnAlias() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Alias")
        let transcriptID = try await store.addTranscript(
            .init(transcriptionMethodId: "v2", language: "en", speakerCount: 2, segments: [], processingDuration: 0),
            vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        let wrong = try await store.findOrCreatePerson(name: "W. Lopez", email: nil)
        try await store.setSpeakerAssignment(
            speakerID: 1, personID: wrong,
            provenance: SpeakerNameProvenance(source: .screen, confidence: .high), for: transcriptID
        )
        let maria = try await store.findOrCreatePerson(name: "Maria Lopez", email: nil)
        try await store.setSpeakerAssignment(speakerID: 1, personID: maria, for: transcriptID)
        #expect(try await store.findOrCreatePerson(name: "W. Lopez", email: nil) == maria)
    }

    @Test func junkPeopleAndTheirAutomaticNamesAreRemoved() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Junk")
        let transcriptID = try await store.addTranscript(
            .init(transcriptionMethodId: "v2", language: "en", speakerCount: 2, segments: [], processingDuration: 0),
            vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        let junk = try await store.findOrCreatePerson(name: "Live Captions", email: nil)
        try await store.setSpeakerAssignment(
            speakerID: 1, personID: junk,
            provenance: SpeakerNameProvenance(source: .screen, confidence: .high), for: transcriptID
        )
        let removed = try await store.removeJunkPeople { $0.lowercased().contains("caption") }
        #expect(removed == 1)
        #expect(try await store.transcript(id: transcriptID)?.speakerAssignments[1] == nil)
    }
}

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

    @Test func twoRealPeopleWhoShareAFirstNameAreNeverMerged() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Two Marias")
        let transcriptID = try await store.addTranscript(
            .init(transcriptionMethodId: "v2", language: "en", speakerCount: 2, segments: [], processingDuration: 0),
            vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        // Both are invitees with their own email: the screen picked the
        // wrong Maria, which must not become a rule.
        let lopez = try await store.findOrCreatePerson(name: "Maria Lopez", email: "lopez@example.com")
        try await store.setSpeakerAssignment(
            speakerID: 1, personID: lopez,
            provenance: SpeakerNameProvenance(source: .screen, confidence: .high), for: transcriptID
        )
        let reyes = try await store.findOrCreatePerson(name: "Maria Reyes", email: "reyes@example.com")
        try await store.setSpeakerAssignment(speakerID: 1, personID: reyes, for: transcriptID)
        #expect(try await store.findOrCreatePerson(name: "Maria Lopez", email: nil) == lopez)
    }

    @Test func correctingTheWrongPersonTeachesNoAlias() async throws {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Wrong person")
        let transcriptID = try await store.addTranscript(
            .init(transcriptionMethodId: "v2", language: "en", speakerCount: 2, segments: [], processingDuration: 0),
            vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        // The screen highlighted Nora, but it was Owen talking.
        let nora = try await store.findOrCreatePerson(name: "Nora Hale", email: nil)
        try await store.setSpeakerAssignment(
            speakerID: 1, personID: nora,
            provenance: SpeakerNameProvenance(source: .screen, confidence: .high), for: transcriptID
        )
        let owen = try await store.findOrCreatePerson(name: "Owen Price", email: nil)
        try await store.setSpeakerAssignment(speakerID: 1, personID: owen, for: transcriptID)
        #expect(try await store.findOrCreatePerson(name: "Nora Hale", email: nil) == nora)
        #expect(!PersonAlias.sharesAName("Nora Hale", "Owen Price"))
        #expect(PersonAlias.sharesAName("Lopez, Maria (AGENCY)", "Maria Reyes"))
    }

    @Test func aNameOrderMatchNeedsExactlyOnePerson() async throws {
        let store = try DataStore(storage: .inMemory)
        _ = try await store.findOrCreatePerson(name: "Sam Carter", email: "sam@one.example")
        #expect(try await store.personMatchingAlias("Carter, Sam") != nil)
        _ = try await store.findOrCreatePerson(name: "Sam Carter", email: "sam@two.example")
        #expect(try await store.personMatchingAlias("Carter, Sam") == nil)
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

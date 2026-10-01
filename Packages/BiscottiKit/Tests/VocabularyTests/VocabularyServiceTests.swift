import DataStore
import Foundation
import Testing
@testable import Vocabulary

private func makeStore() throws -> DataStore {
    try DataStore(storage: .inMemory)
}

@Suite("VocabularyService")
struct VocabularyServiceTests {
    @Test("Effective vocabulary integrates user terms with calendar data")
    func effectiveVocabulary() async throws {
        let store = try makeStore()

        // Set up user vocabulary terms.
        try await store.updateSettings { settings in
            settings.customVocabulary = ["Biscotti", "WhisperKit"]
            settings.customVocabularyEnabled = true
            settings.calendarVocabularyEnabled = true
        }

        // Create a meeting with participants and a calendar snapshot.
        let meetingID = try await store.createMeeting(title: "Standup")
        let alice = try await store.findOrCreatePerson(name: "Alice Smith", email: "alice@acme.com")
        let bob = try await store.findOrCreatePerson(name: "Bob Jones", email: "bob@acme.com")
        try await store.setParticipants([alice, bob], organizer: alice, for: meetingID)

        let snapshot = CalendarSnapshot(
            compositeKey: "test|key",
            title: "Project Parakeet Standup",
            eventNotes: "Review the team project status for Parakeet"
        )
        try await store.setSnapshot(snapshot, for: meetingID)

        let service = VocabularyService(store: store)
        let vocab = await service.effectiveVocabulary(meetingID: meetingID)

        // Should contain user terms first.
        #expect(vocab.first == "Biscotti")
        #expect(vocab.contains("WhisperKit"))
        // Should contain attendee first names.
        #expect(vocab.contains("Alice"))
        #expect(vocab.contains("Bob"))
        // Should contain company name from domain.
        #expect(vocab.contains("Acme"))
    }

    @Test("Feature off returns empty vocabulary")
    func featureOff() async throws {
        let store = try makeStore()

        try await store.updateSettings { settings in
            settings.customVocabulary = ["Biscotti"]
            settings.customVocabularyEnabled = false
        }

        let meetingID = try await store.createMeeting(title: "Standup")
        let service = VocabularyService(store: store)
        let vocab = await service.effectiveVocabulary(meetingID: meetingID)

        #expect(vocab.isEmpty)
    }

    @Test("Calendar toggle off returns user terms only")
    func calendarToggleOff() async throws {
        let store = try makeStore()

        try await store.updateSettings { settings in
            settings.customVocabulary = ["Biscotti"]
            settings.customVocabularyEnabled = true
            settings.calendarVocabularyEnabled = false
        }

        let meetingID = try await store.createMeeting(title: "Standup")
        let alice = try await store.findOrCreatePerson(name: "Alice Smith", email: "alice@acme.com")
        try await store.setParticipants([alice], organizer: alice, for: meetingID)

        let snapshot = CalendarSnapshot(
            compositeKey: "test|key",
            title: "Parakeet Planning"
        )
        try await store.setSnapshot(snapshot, for: meetingID)

        let service = VocabularyService(store: store)
        let vocab = await service.effectiveVocabulary(meetingID: meetingID)

        #expect(vocab == ["Biscotti"])
    }

    @Test("Meeting without calendar snapshot returns user terms only")
    func noCalendarSnapshot() async throws {
        let store = try makeStore()

        try await store.updateSettings { settings in
            settings.customVocabulary = ["MyTerm"]
            settings.customVocabularyEnabled = true
            settings.calendarVocabularyEnabled = true
        }

        let meetingID = try await store.createMeeting(title: "Ad-hoc")
        let service = VocabularyService(store: store)
        let vocab = await service.effectiveVocabulary(meetingID: meetingID)

        #expect(vocab == ["MyTerm"])
    }

    @Test("Nonexistent meeting returns user terms only")
    func nonexistentMeeting() async throws {
        let store = try makeStore()

        try await store.updateSettings { settings in
            settings.customVocabulary = ["MyTerm"]
            settings.customVocabularyEnabled = true
            settings.calendarVocabularyEnabled = true
        }

        let service = VocabularyService(store: store)
        let vocab = await service.effectiveVocabulary(meetingID: UUID())

        // No calendar context available, so user terms only.
        #expect(vocab == ["MyTerm"])
    }

    @Test("Empty user vocabulary with calendar data returns calendar-derived terms")
    func emptyUserVocabWithCalendar() async throws {
        let store = try makeStore()

        try await store.updateSettings { settings in
            settings.customVocabulary = []
            settings.customVocabularyEnabled = true
            settings.calendarVocabularyEnabled = true
        }

        let meetingID = try await store.createMeeting(title: "Standup")
        let alice = try await store.findOrCreatePerson(name: "Alice Smith", email: "alice@acme.com")
        try await store.setParticipants([alice], organizer: alice, for: meetingID)

        let snapshot = CalendarSnapshot(
            compositeKey: "test|key",
            title: "Standup"
        )
        try await store.setSnapshot(snapshot, for: meetingID)

        let service = VocabularyService(store: store)
        let vocab = await service.effectiveVocabulary(meetingID: meetingID)

        #expect(vocab.contains("Alice"))
        #expect(vocab.contains("Acme"))
    }
}

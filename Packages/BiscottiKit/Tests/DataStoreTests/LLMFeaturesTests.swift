import DataStore
import Foundation
import Testing
import Transcription

// MARK: - Shared helpers

private func makeStore() throws -> DataStore {
    try DataStore(storage: .inMemory)
}

private func makeTranscriptResult() -> TranscriptResult {
    let seg1 = TranscriptSegment(
        speakerID: 0, speakerLabel: "Speaker 0",
        startTime: 0, endTime: 5,
        text: "Hello everyone", confidence: 0.9, noSpeechProbability: 0.1, words: nil
    )
    let seg2 = TranscriptSegment(
        speakerID: 1, speakerLabel: "Speaker 1",
        startTime: 5, endTime: 10,
        text: "Hi there", confidence: 0.85, noSpeechProbability: 0.15, words: nil
    )
    let seg3 = TranscriptSegment(
        speakerID: 0, speakerLabel: "Speaker 0",
        startTime: 10, endTime: 15,
        text: "Let's get started", confidence: 0.95, noSpeechProbability: 0.05, words: nil
    )
    return TranscriptResult(
        transcriptionMethodId: "v1",
        language: "en",
        speakerCount: 2,
        segments: [seg1, seg2, seg3],
        speakerEmbeddings: [:],
        processingDuration: 3.0
    )
}

/// Creates a meeting with a transcript and returns (meetingID, transcriptID).
private func makeMeetingWithTranscript(
    store: DataStore, title: String = "Test Meeting"
) async throws -> (UUID, UUID) {
    let meetingID = try await store.createMeeting(title: title)
    let result = makeTranscriptResult()
    let transcriptID = try await store.addTranscript(
        result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
    )
    try await store.setPreferredTranscript(transcriptID, for: meetingID)
    return (meetingID, transcriptID)
}

// MARK: - Summary tests

@Suite("DataStore -- summary (applyGeneratedSummary / setSummary)")
struct SummaryTests {
    @Test("applyGeneratedSummary sets summary and editedSummary=false")
    func applyGeneratedSummary() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Standup")

        try await store.applyGeneratedSummary("## Notes\n- Item 1", for: meetingID)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "## Notes\n- Item 1")
        #expect(detail?.editedSummary == false)
    }

    @Test("setSummary sets summary and editedSummary=true")
    func setSummary() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Retro")

        try await store.setSummary("My edited notes", for: meetingID)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "My edited notes")
        #expect(detail?.editedSummary == true)
    }

    @Test("applyGeneratedSummary after setSummary resets editedSummary to false")
    func applyAfterEdit() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Planning")

        // First: user edits
        try await store.setSummary("User version", for: meetingID)
        let afterEdit = try await store.meetingDetail(id: meetingID)
        #expect(afterEdit?.editedSummary == true)

        // Then: AI regenerates
        try await store.applyGeneratedSummary("AI version", for: meetingID)
        let afterRegen = try await store.meetingDetail(id: meetingID)
        #expect(afterRegen?.summary == "AI version")
        #expect(afterRegen?.editedSummary == false)
    }

    @Test("applyGeneratedSummary throws notFound for unknown meeting")
    func applyGeneratedSummaryNotFound() async throws {
        let store = try makeStore()
        await #expect(throws: DataStoreError.self) {
            try await store.applyGeneratedSummary("text", for: UUID())
        }
    }

    @Test("setSummary throws notFound for unknown meeting")
    func setSummaryNotFound() async throws {
        let store = try makeStore()
        await #expect(throws: DataStoreError.self) {
            try await store.setSummary("text", for: UUID())
        }
    }

    @Test("meetingDetail carries summary fields with defaults for new meeting")
    func meetingDetailSummaryDefaults() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Fresh")

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "")
        #expect(detail?.editedSummary == false)
    }
}

// MARK: - Speaker assignments tests

@Suite("DataStore -- speaker assignments")
struct SpeakerAssignmentTests {
    @Test("setSpeakerAssignments merges into empty map")
    func setSpeakerAssignments() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: "alice@x.com")
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)

        try await store.setSpeakerAssignments([0: alice, 1: bob], for: transcriptID)

        let transcript = try await store.transcript(id: transcriptID)
        #expect(transcript?.speakerAssignments.count == 2)
        #expect(transcript?.speakerAssignments[0]?.name == "Alice")
        #expect(transcript?.speakerAssignments[0]?.email == "alice@x.com")
        #expect(transcript?.speakerAssignments[1]?.name == "Bob")
        #expect(transcript?.speakerAssignments[1]?.email == nil)
    }

    @Test("setSpeakerAssignment sets a single speaker")
    func setSingleSpeaker() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        try await store.setSpeakerAssignment(speakerID: 0, personID: alice, for: transcriptID)

        let transcript = try await store.transcript(id: transcriptID)
        #expect(transcript?.speakerAssignments.count == 1)
        #expect(transcript?.speakerAssignments[0]?.name == "Alice")
    }

    @Test("setSpeakerAssignment clears a single speaker with nil personID")
    func clearSingleSpeaker() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        try await store.setSpeakerAssignment(speakerID: 0, personID: alice, for: transcriptID)

        // Verify assigned
        var transcript = try await store.transcript(id: transcriptID)
        #expect(transcript?.speakerAssignments[0]?.name == "Alice")

        // Clear
        try await store.setSpeakerAssignment(speakerID: 0, personID: nil, for: transcriptID)

        transcript = try await store.transcript(id: transcriptID)
        #expect(transcript?.speakerAssignments.isEmpty == true)
    }

    @Test("speaker assignments round-trip correctly through JSON Data backing")
    func speakerAssignmentsRoundTrip() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let person1 = try await store.findOrCreatePerson(name: "A", email: nil)
        let person2 = try await store.findOrCreatePerson(name: "B", email: nil)
        let person3 = try await store.findOrCreatePerson(name: "C", email: nil)

        let assignments: [Int: UUID] = [0: person1, 1: person2, 5: person3]
        try await store.setSpeakerAssignments(assignments, for: transcriptID)

        // Read back via the raw model to verify Data encoding
        let rawAssignments: [Int: SpeakerAssignmentEntry] = try await store.read { store in
            let records = try store.fetchAllTranscripts()
            let record = try #require(records.first(where: { $0.id == transcriptID }))
            return record.speakerAssignments
        }

        #expect(rawAssignments.count == 3)
        #expect(rawAssignments[0]?.personID == person1)
        #expect(rawAssignments[0]?.userSet == false)
        #expect(rawAssignments[1]?.personID == person2)
        #expect(rawAssignments[1]?.userSet == false)
        #expect(rawAssignments[5]?.personID == person3)
        #expect(rawAssignments[5]?.userSet == false)
    }

    @Test("dangling Person IDs are dropped in the read model")
    func danglingIDDropped() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        let danglingID = UUID() // No Person exists for this UUID

        try await store.setSpeakerAssignments([0: alice, 1: danglingID], for: transcriptID)

        let transcript = try await store.transcript(id: transcriptID)
        // Only the valid assignment should appear
        #expect(transcript?.speakerAssignments.count == 1)
        #expect(transcript?.speakerAssignments[0]?.name == "Alice")
        #expect(transcript?.speakerAssignments[1] == nil)
    }

    @Test("speaker assignments resolve in meetingDetail preferred transcript")
    func speakerAssignmentsInMeetingDetail() async throws {
        let store = try makeStore()
        let (meetingID, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: "alice@x.com")
        try await store.setSpeakerAssignments([0: alice], for: transcriptID)

        let detail = try await store.meetingDetail(id: meetingID)
        let resolved = detail?.preferredTranscript?.speakerAssignments
        #expect(resolved?.count == 1)
        #expect(resolved?[0]?.name == "Alice")
        #expect(resolved?[0]?.email == "alice@x.com")
    }

    @Test("transcript(id:) resolves speaker assignments to PersonData")
    func transcriptByIDResolvesAssignments() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: "alice@x.com")
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)
        try await store.setSpeakerAssignments([0: alice, 1: bob], for: transcriptID)

        let transcript = try #require(await store.transcript(id: transcriptID))
        #expect(transcript.speakerAssignments.count == 2)
        #expect(transcript.speakerAssignments[0]?.name == "Alice")
        #expect(transcript.speakerAssignments[0]?.email == "alice@x.com")
        #expect(transcript.speakerAssignments[1]?.name == "Bob")
        #expect(transcript.speakerAssignments[1]?.email == nil)
    }

    @Test("setSpeakerAssignments throws notFound for unknown transcript")
    func setSpeakerAssignmentsNotFound() async throws {
        let store = try makeStore()
        await #expect(throws: DataStoreError.self) {
            try await store.setSpeakerAssignments([:], for: UUID())
        }
    }

    @Test("setSpeakerAssignment throws notFound for unknown transcript")
    func setSpeakerAssignmentNotFound() async throws {
        let store = try makeStore()
        await #expect(throws: DataStoreError.self) {
            try await store.setSpeakerAssignment(speakerID: 0, personID: nil, for: UUID())
        }
    }
}

// MARK: - TranscriptData convenience

@Suite("TranscriptData -- speakerName convenience")
struct SpeakerNameConvenienceTests {
    @Test("speakerName returns name for assigned speaker, nil for unassigned")
    func speakerNameConvenience() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        try await store.setSpeakerAssignments([0: alice], for: transcriptID)

        let transcriptData = try #require(await store.transcript(id: transcriptID))
        #expect(transcriptData.speakerName(forID: 0) == "Alice")
        #expect(transcriptData.speakerName(forID: 1) == nil) // Unassigned
        #expect(transcriptData.speakerName(forID: 99) == nil) // Non-existent
    }
}

// MARK: - SegmentData speakerID

@Suite("SegmentData -- speakerID field")
struct SegmentDataSpeakerIDTests {
    @Test("SegmentData carries speakerID from the segment record")
    func segmentDataIncludesSpeakerID() async throws {
        let store = try makeStore()
        let (meetingID, _) = try await makeMeetingWithTranscript(store: store)

        let detail = try await store.meetingDetail(id: meetingID)
        let segments = try #require(detail?.preferredTranscript?.segments)
        #expect(segments.count == 3)
        #expect(segments[0].speakerID == 0)
        #expect(segments[1].speakerID == 1)
        #expect(segments[2].speakerID == 0)
    }

    @Test("SegmentData speakerID is nil when segment has no speaker")
    func segmentDataNilSpeakerID() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No Speaker")

        let seg = TranscriptSegment(
            speakerID: nil, speakerLabel: "Unknown",
            startTime: 0, endTime: 5,
            text: "Some text", confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 0,
            segments: [seg], speakerEmbeddings: [:], processingDuration: 1.0
        )
        let txID = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(txID, for: meetingID)

        let detail = try await store.meetingDetail(id: meetingID)
        let segments = try #require(detail?.preferredTranscript?.segments)
        #expect(segments[0].speakerID == nil)
    }
}

// MARK: - allPersonData

@Suite("DataStore -- allPersonData")
struct AllPersonDataTests {
    @Test("allPersonData returns all persons sorted by name")
    func allPersonData() async throws {
        let store = try makeStore()

        _ = try await store.findOrCreatePerson(name: "Charlie", email: nil)
        _ = try await store.findOrCreatePerson(name: "Alice", email: "alice@x.com")
        _ = try await store.findOrCreatePerson(name: "Bob", email: "bob@x.com")

        let people = try await store.allPersonData()
        #expect(people.count == 3)
        #expect(people[0].name == "Alice")
        #expect(people[0].email == "alice@x.com")
        #expect(people[1].name == "Bob")
        #expect(people[2].name == "Charlie")
        #expect(people[2].email == nil)
    }

    @Test("allPersonData returns empty when no persons exist")
    func allPersonDataEmpty() async throws {
        let store = try makeStore()
        let people = try await store.allPersonData()
        #expect(people.isEmpty)
    }
}

// MARK: - Speaker assignment provenance (Phase 10)

@Suite("DataStore -- speaker assignment provenance (userSet)")
struct SpeakerAssignmentProvenanceTests {
    @Test("auto-run preserves userSet entry and fills only unset speakers")
    func autoRunPreservesUserSetAndFillsUnset() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)
        let charlie = try await store.findOrCreatePerson(name: "Charlie", email: nil)

        // Manually assign speaker 0 (userSet = true)
        try await store.setSpeakerAssignment(
            speakerID: 0, personID: alice, for: transcriptID
        )

        // Verify the manual assignment is userSet
        let rawBefore: [Int: SpeakerAssignmentEntry] = try await store.read { store in
            let records = try store.fetchAllTranscripts()
            let record = try #require(records.first(where: { $0.id == transcriptID }))
            return record.speakerAssignments
        }
        #expect(rawBefore[0]?.personID == alice)
        #expect(rawBefore[0]?.userSet == true)

        // LLM auto-run tries to assign both speakers 0 and 1
        try await store.setSpeakerAssignments(
            [0: bob, 1: charlie], for: transcriptID
        )

        // Speaker 0 should be preserved (still Alice, userSet)
        // Speaker 1 should be filled with Charlie (AI, not userSet)
        let rawAfter: [Int: SpeakerAssignmentEntry] = try await store.read { store in
            let records = try store.fetchAllTranscripts()
            let record = try #require(records.first(where: { $0.id == transcriptID }))
            return record.speakerAssignments
        }
        #expect(rawAfter[0]?.personID == alice)
        #expect(rawAfter[0]?.userSet == true)
        #expect(rawAfter[1]?.personID == charlie)
        #expect(rawAfter[1]?.userSet == false)

        // Read model should resolve both
        let transcript = try await store.transcript(id: transcriptID)
        #expect(transcript?.speakerAssignments[0]?.name == "Alice")
        #expect(transcript?.speakerAssignments[1]?.name == "Charlie")
    }

    @Test("manual set marks userSet true")
    func manualSetMarksUserSetTrue() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        try await store.setSpeakerAssignment(
            speakerID: 0, personID: alice, for: transcriptID
        )

        let raw: [Int: SpeakerAssignmentEntry] = try await store.read { store in
            let records = try store.fetchAllTranscripts()
            let record = try #require(records.first(where: { $0.id == transcriptID }))
            return record.speakerAssignments
        }
        #expect(raw[0]?.personID == alice)
        #expect(raw[0]?.userSet == true)
    }

    @Test("old [Int:UUID] shape decodes as empty")
    func oldShapeDecodeReturnsEmpty() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        // Write raw [Int: UUID] JSON directly to the backing data
        let oldShape: [Int: UUID] = [0: UUID(), 1: UUID()]
        let oldData = try JSONEncoder().encode(oldShape)

        try await store.read { store in
            let records = try store.fetchAllTranscripts()
            let record = try #require(records.first(where: { $0.id == transcriptID }))
            // Directly set the backing data to the old shape
            record.setSpeakerAssignmentsData_testOnly(oldData)
        }

        // The computed property should return empty (lenient decode)
        let raw: [Int: SpeakerAssignmentEntry] = try await store.read { store in
            let records = try store.fetchAllTranscripts()
            let record = try #require(records.first(where: { $0.id == transcriptID }))
            return record.speakerAssignments
        }
        #expect(raw.isEmpty)

        // Read model should also return empty assignments
        let transcript = try await store.transcript(id: transcriptID)
        #expect(transcript?.speakerAssignments.isEmpty == true)
    }

    @Test("unassign clears the entry entirely")
    func unassignClearsEntry() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        try await store.setSpeakerAssignment(
            speakerID: 0, personID: alice, for: transcriptID
        )

        // Verify assigned
        var raw: [Int: SpeakerAssignmentEntry] = try await store.read { store in
            let records = try store.fetchAllTranscripts()
            let record = try #require(records.first(where: { $0.id == transcriptID }))
            return record.speakerAssignments
        }
        #expect(raw[0] != nil)

        // Unassign
        try await store.setSpeakerAssignment(
            speakerID: 0, personID: nil, for: transcriptID
        )

        raw = try await store.read { store in
            let records = try store.fetchAllTranscripts()
            let record = try #require(records.first(where: { $0.id == transcriptID }))
            return record.speakerAssignments
        }
        #expect(raw.isEmpty)
    }

    @Test("bulk write to empty map sets all entries as userSet=false")
    func bulkWriteAllAIEntriesHaveUserSetFalse() async throws {
        let store = try makeStore()
        let (_, transcriptID) = try await makeMeetingWithTranscript(store: store)

        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)

        try await store.setSpeakerAssignments(
            [0: alice, 1: bob], for: transcriptID
        )

        let raw: [Int: SpeakerAssignmentEntry] = try await store.read { store in
            let records = try store.fetchAllTranscripts()
            let record = try #require(records.first(where: { $0.id == transcriptID }))
            return record.speakerAssignments
        }
        #expect(raw.count == 2)
        #expect(raw[0]?.userSet == false)
        #expect(raw[1]?.userSet == false)
    }
}

// MARK: - Settings AI fields

@Suite("DataStore -- settings AI fields")
struct SettingsAIFieldsTests {
    @Test("settings defaults include aiAnalysisEnabled=true")
    func settingsDefaults() async throws {
        let store = try makeStore()
        let result = try await store.settings()
        #expect(result.aiAnalysisEnabled == true)
    }

    @Test("updateSettings round-trips aiAnalysisEnabled")
    func updateSettingsAIFields() async throws {
        let store = try makeStore()

        try await store.updateSettings { settings in
            settings.aiAnalysisEnabled = false
        }

        let result = try await store.settings()
        #expect(result.aiAnalysisEnabled == false)

        // Toggle back
        try await store.updateSettings { settings in
            settings.aiAnalysisEnabled = true
        }

        let restored = try await store.settings()
        #expect(restored.aiAnalysisEnabled == true)
    }
}

// MARK: - applyGeneratedSummary markEdited

@Suite("DataStore -- applyGeneratedSummary markEdited")
struct ApplyGeneratedSummaryMarkEditedTests {
    @Test("markEdited=true sets editedSummary=true")
    func markEditedTrue() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Test")

        try await store.applyGeneratedSummary(
            "Custom prompt summary", for: meetingID, markEdited: true
        )

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "Custom prompt summary")
        #expect(detail?.editedSummary == true)
    }

    @Test("markEdited=false sets editedSummary=false (default)")
    func markEditedFalse() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Test")

        // First set as edited
        try await store.setSummary("User version", for: meetingID)
        let after = try await store.meetingDetail(id: meetingID)
        #expect(after?.editedSummary == true)

        // Then regenerate with markEdited=false (default)
        try await store.applyGeneratedSummary(
            "AI version", for: meetingID
        )

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "AI version")
        #expect(detail?.editedSummary == false)
    }
}

// MARK: - AppSettings summaryPrompt

@Suite("DataStore -- AppSettings summaryPrompt")
struct AppSettingsSummaryPromptTests {
    @Test("summaryPrompt defaults to empty string")
    func defaultsToEmpty() async throws {
        let store = try makeStore()
        let result = try await store.settings()
        #expect(result.summaryPrompt == "")
    }

    @Test("summaryPrompt round-trips custom text")
    func roundTripsCustomText() async throws {
        let store = try makeStore()

        try await store.updateSettings { settings in
            settings.summaryPrompt = "Write a haiku summary."
        }

        let result = try await store.settings()
        #expect(result.summaryPrompt == "Write a haiku summary.")
    }

    @Test("summaryPrompt round-trips empty string (default)")
    func roundTripsEmpty() async throws {
        let store = try makeStore()

        // Set custom then clear
        try await store.updateSettings { settings in
            settings.summaryPrompt = "Custom"
        }
        try await store.updateSettings { settings in
            settings.summaryPrompt = ""
        }

        let result = try await store.settings()
        #expect(result.summaryPrompt == "")
    }

    @Test("AppSettingsData carries summaryPrompt from model")
    func dtoCarriesSummaryPrompt() async throws {
        let store = try makeStore()

        try await store.updateSettings { settings in
            settings.summaryPrompt = "Custom instructions"
        }

        let dto = try await store.settings()
        #expect(dto.summaryPrompt == "Custom instructions")
    }
}

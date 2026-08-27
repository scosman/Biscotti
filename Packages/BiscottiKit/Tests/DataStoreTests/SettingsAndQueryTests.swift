import DataStore
import Foundation
import Testing
import Transcription

// MARK: - Shared helper

private func makeStore() throws -> DataStore {
    try DataStore(storage: .inMemory)
}

private func makeResult(method: String) -> TranscriptResult {
    let seg1 = TranscriptSegment(
        speakerID: 0, speakerLabel: "Speaker 0",
        startTime: 0, endTime: 5,
        text: "Hello", confidence: 0.9, noSpeechProbability: 0.1, words: nil
    )
    let seg2 = TranscriptSegment(
        speakerID: 1, speakerLabel: "Speaker 1",
        startTime: 5, endTime: 10,
        text: "Hi there", confidence: 0.85, noSpeechProbability: 0.15, words: nil
    )
    return TranscriptResult(
        transcriptionMethodId: method,
        language: "en",
        speakerCount: 2,
        segments: [seg1, seg2],
        speakerEmbeddings: [:],
        processingDuration: 3.0
    )
}

// MARK: - Settings tests

@Suite("DataStore -- settings")
struct SettingsTests {
    @Test("settings() creates singleton with defaults on first call")
    func settingsDefaultsOnFirstCall() async throws {
        let store = try makeStore()
        let result = try await store.settings()
        #expect(result.customVocabulary.isEmpty)
        #expect(result.launchAtLogin == false)
        #expect(result.exitOnWindowClose == false)
        #expect(result.globalRecordShortcutEnabled == true)
        #expect(result.menuBarLeadTimeSeconds == 3600)
        #expect(result.onboardingComplete == false)
        #expect(result.enabledCalendarIDs == nil)
    }

    @Test("selectedModelID defaults to empty string")
    func selectedModelIDDefaultsToEmpty() async throws {
        let store = try makeStore()
        let result = try await store.settings()
        #expect(result.selectedModelID == "")
    }

    @Test("selectedModelID round-trips through updateSettings")
    func selectedModelIDRoundTrip() async throws {
        let store = try makeStore()
        try await store.updateSettings { $0.selectedModelID = "gemma-4-e2b" }
        let result = try await store.settings()
        #expect(result.selectedModelID == "gemma-4-e2b")
    }

    @Test("settings() returns the same singleton on subsequent calls")
    func settingsSingleton() async throws {
        let store = try makeStore()
        _ = try await store.settings()
        let second = try await store.settings()
        #expect(second.launchAtLogin == false)
    }

    @Test("updateSettings applies mutation and persists")
    func updateSettingsMutation() async throws {
        let store = try makeStore()
        try await store.updateSettings { settings in
            settings.launchAtLogin = true
            settings.exitOnWindowClose = true
            settings.menuBarLeadTimeSeconds = 300
            settings.onboardingComplete = true
            settings.customVocabulary = ["Biscotti", "WhisperKit"]
            settings.enabledCalendarIDs = Set(["cal1", "cal2"])
        }

        let result = try await store.settings()
        #expect(result.launchAtLogin == true)
        #expect(result.exitOnWindowClose == true)
        #expect(result.menuBarLeadTimeSeconds == 300)
        #expect(result.onboardingComplete == true)
        #expect(result.customVocabulary == ["Biscotti", "WhisperKit"])
        #expect(result.enabledCalendarIDs == Set(["cal1", "cal2"]))
    }

    @Test("customVocabularyEnabled starts unset and resolves to off (beta)")
    func customVocabularyEnabledDefault() async throws {
        let store = try makeStore()
        let result = try await store.settings()
        // Unset, not false: the stored tri-state must stay distinguishable
        // from a deliberate opt-out so the shipped default can be flipped.
        #expect(result.customVocabularyEnabled == nil)
        #expect(result.customVocabularyResolved == false)
    }

    @Test("An unrelated settings write preserves the unset vocabulary toggle")
    func customVocabularyEnabledSurvivesUnrelatedWrite() async throws {
        let store = try makeStore()

        // updateSettings does a full read-modify-write of every field. If the
        // DTO carried a resolved Bool, this would bake today's default into
        // the store and make the eventual default flip a no-op.
        try await store.updateSettings { $0.launchAtLogin = true }

        let result = try await store.settings()
        #expect(result.launchAtLogin == true)
        #expect(result.customVocabularyEnabled == nil)
    }

    @Test("Explicitly choosing off is distinguishable from never choosing")
    func customVocabularyEnabledExplicitOffIsRecorded() async throws {
        let store = try makeStore()
        try await store.updateSettings { $0.customVocabularyEnabled = false }

        let result = try await store.settings()
        #expect(result.customVocabularyEnabled == false)
        #expect(result.customVocabularyResolved == false)
    }

    @Test("calendarVocabularyEnabled defaults to true")
    func calendarVocabularyEnabledDefault() async throws {
        let store = try makeStore()
        let result = try await store.settings()
        #expect(result.calendarVocabularyEnabled == true)
    }

    @Test("vocabulary toggle fields round-trip through updateSettings")
    func vocabularyToggleRoundTrip() async throws {
        let store = try makeStore()
        try await store.updateSettings { settings in
            settings.customVocabularyEnabled = false
            settings.calendarVocabularyEnabled = false
        }
        let result = try await store.settings()
        #expect(result.customVocabularyEnabled == false)
        #expect(result.calendarVocabularyEnabled == false)
    }

    @Test("updateSettings with nil enabledCalendarIDs means all calendars")
    func updateSettingsNilCalendars() async throws {
        let store = try makeStore()
        try await store.updateSettings { settings in
            settings.enabledCalendarIDs = Set(["cal1"])
        }
        #expect(try await store.settings().enabledCalendarIDs == Set(["cal1"]))

        try await store.updateSettings { settings in
            settings.enabledCalendarIDs = nil
        }
        #expect(try await store.settings().enabledCalendarIDs == nil)
    }
}

// MARK: - Notes tests

@Suite("DataStore -- notes")
struct NotesTests {
    @Test("setNotes updates meeting notes and persists")
    func setNotes() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Test")

        try await store.setNotes("Action items: fix bug", for: meetingID)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail?.notes == "Action items: fix bug")
    }

    @Test("setNotes throws notFound for unknown meeting")
    func setNotesNotFound() async throws {
        let store = try makeStore()
        await #expect(throws: DataStoreError.self) {
            try await store.setNotes("text", for: UUID())
        }
    }
}

// MARK: - Calendar context tests

@Suite("DataStore -- calendar context")
struct CalendarContextTests {
    @Test("calendarContext returns nil when no snapshot")
    func calendarContextNil() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No Cal")
        let ctx = try await store.calendarContext(meetingID: meetingID)
        #expect(ctx == nil)
    }

    @Test("calendarContext maps snapshot fields")
    func calendarContextMapsFields() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "With Cal")

        let snapshot = CalendarSnapshot(
            eventIdentifier: "evt1",
            compositeKey: "key1",
            title: "Sprint Review",
            location: "Room 42",
            calendarTitle: "Work",
            calendarColorHex: "#FF0000",
            conferenceURL: URL(string: "https://zoom.us/j/123"),
            conferencePlatform: "Zoom"
        )
        try await store.setSnapshot(snapshot, for: meetingID)

        let ctx = try await store.calendarContext(meetingID: meetingID)
        #expect(ctx != nil)
        #expect(ctx?.title == "Sprint Review")
        #expect(ctx?.location == "Room 42")
        #expect(ctx?.calendarTitle == "Work")
        #expect(ctx?.calendarColorHex == "#FF0000")
        #expect(ctx?.conferencePlatform == "Zoom")
        #expect(ctx?.conferenceURL?.absoluteString == "https://zoom.us/j/123")
    }

    @Test("calendarContext includes organizer and attendees")
    func calendarContextPeople() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Team Call")

        let alice = try await store.findOrCreatePerson(name: "Alice", email: "alice@x.com")
        let bob = try await store.findOrCreatePerson(name: "Bob", email: nil)
        try await store.setParticipants([alice, bob], organizer: alice, for: meetingID)

        let snapshot = CalendarSnapshot(
            eventIdentifier: "e1",
            compositeKey: "k1",
            title: "Team Call"
        )
        try await store.setSnapshot(snapshot, for: meetingID)

        let ctx = try await store.calendarContext(meetingID: meetingID)
        #expect(ctx?.organizer?.name == "Alice")
        #expect(ctx?.organizer?.email == "alice@x.com")
        #expect(ctx?.attendees.count == 2)
    }
}

// MARK: - Transcript versions & lookup tests

@Suite("DataStore -- transcript versions and lookup")
struct TranscriptVersionTests {
    @Test("transcriptVersions returns empty for meeting with no transcripts")
    func transcriptVersionsEmpty() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No Tx")
        let versions = try await store.transcriptVersions(meetingID: meetingID)
        #expect(versions.isEmpty)
    }

    @Test("transcriptVersions returns versions sorted newest-first with preferred marked")
    func transcriptVersionsSorted() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Multi Tx")

        let txID1 = try await store.addTranscript(
            makeResult(method: "v1"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        let txID2 = try await store.addTranscript(
            makeResult(method: "v2"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await store.setPreferredTranscript(txID2, for: meetingID)

        let versions = try await store.transcriptVersions(meetingID: meetingID)
        #expect(versions.count == 2)
        #expect(versions[0].id == txID2)
        #expect(versions[0].isPreferred == true)
        #expect(versions[0].methodId == "v2")
        #expect(versions[1].id == txID1)
        #expect(versions[1].isPreferred == false)
    }

    @Test("transcript by ID returns full data")
    func transcriptByID() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Tx Lookup")
        let txID = try await store.addTranscript(
            makeResult(method: "v1"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        let transcript = try await store.transcript(id: txID)
        #expect(transcript != nil)
        #expect(transcript?.speakerCount == 2)
        #expect(transcript?.segments.count == 2)
    }

    @Test("transcript by unknown ID returns nil")
    func transcriptByUnknownID() async throws {
        let store = try makeStore()
        let transcript = try await store.transcript(id: UUID())
        #expect(transcript == nil)
    }

    @Test("transcriptVersions populates vocabularyUsed from record")
    func transcriptVersionVocabularyUsed() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Vocab Test")
        let vocab = ["Acme", "Kubernetes", "Parakeet"]
        _ = try await store.addTranscript(
            makeResult(method: "v1"),
            vocabularyUsed: vocab,
            mappedEventIdentifier: nil,
            to: meetingID
        )

        let versions = try await store.transcriptVersions(meetingID: meetingID)
        #expect(versions.count == 1)
        #expect(versions[0].vocabularyUsed == vocab)
    }

    @Test("transcriptVersions defaults vocabularyUsed to empty")
    func transcriptVersionVocabularyUsedDefault() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No Vocab")
        _ = try await store.addTranscript(
            makeResult(method: "v1"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )

        let versions = try await store.transcriptVersions(meetingID: meetingID)
        #expect(versions.count == 1)
        #expect(versions[0].vocabularyUsed.isEmpty)
    }
}

// MARK: - Audio, sort, detail tests

@Suite("DataStore -- audioFileRefs, effective-date sort, detail enrichment")
struct AudioAndSortTests {
    @Test("audioFileRefs returns URLs when present")
    func audioFileRefsPresent() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Audio Test")
        let micRef = AudioFileRef(role: .mic, path: "/a/mic.aac", byteSize: 100, isPresent: true)
        let sysRef = AudioFileRef(role: .system, path: "/a/sys.aac", byteSize: 200, isPresent: true)
        try await store.attachAudio([micRef, sysRef], to: meetingID)

        let refs = try await store.audioFileRefs(meetingID: meetingID)
        #expect(refs.mic?.path == "/a/mic.aac")
        #expect(refs.system?.path == "/a/sys.aac")
        #expect(refs.present == true)
    }

    @Test("audioFileRefs returns nil URLs when not present")
    func audioFileRefsNotPresent() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "No Audio")
        let refs = try await store.audioFileRefs(meetingID: meetingID)
        #expect(refs.mic == nil)
        #expect(refs.system == nil)
        #expect(refs.present == false)
    }

    @Test("meetingSummaries sorts by effective date (startDate ?? createdAt)")
    func effectiveDateSort() async throws {
        let store = try makeStore()

        _ = try await store.createMeeting(
            title: "B",
            start: Date(timeIntervalSince1970: 1_000_000)
        )
        _ = try await store.createMeeting(
            title: "A",
            start: Date(timeIntervalSince1970: 2_000_000)
        )

        let summaries = try await store.meetingSummaries(limit: 10)
        #expect(summaries.count == 2)
        #expect(summaries[0].title == "A")
        #expect(summaries[1].title == "B")
    }

    @Test("meetingDetail includes calendar, notes, and versions")
    func meetingDetailFullData() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Full Detail")

        try await store.setNotes("Important notes", for: meetingID)

        let snapshot = CalendarSnapshot(
            eventIdentifier: "e1",
            compositeKey: "k1",
            title: "Full Detail",
            calendarTitle: "Work"
        )
        try await store.setSnapshot(snapshot, for: meetingID)

        let txID = try await store.addTranscript(
            makeResult(method: "v1"),
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await store.setPreferredTranscript(txID, for: meetingID)

        let detail = try await store.meetingDetail(id: meetingID)
        #expect(detail != nil)
        #expect(detail?.notes == "Important notes")
        #expect(detail?.calendar?.calendarTitle == "Work")
        #expect(detail?.versions.count == 1)
        #expect(detail?.versions.first?.isPreferred == true)
    }
}

// MARK: - searchHits tests

@Suite("DataStore -- searchHits (bm25-ranked full-text search)")
struct SearchHitsTests {
    @Test("searchHits matches title")
    func searchHitsTitle() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Sprint Planning")

        let hits = try await store.searchHits("Sprint", limit: 10)
        #expect(hits.count == 1)
        #expect(hits[0].id == meetingID)
        #expect(hits[0].title == "Sprint Planning")
    }

    @Test("searchHits matches participant")
    func searchHitsParticipant() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Generic Meeting")
        let alice = try await store.findOrCreatePerson(name: "Alice", email: nil)
        try await store.setParticipants([alice], organizer: nil, for: meetingID)

        let hits = try await store.searchHits("Alice", limit: 10)
        #expect(hits.count == 1)
        #expect(hits[0].id == meetingID)
    }

    @Test("searchHits matches transcript text and returns a snippet")
    func searchHitsTranscript() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Meeting")

        let seg = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0",
            startTime: 0, endTime: 5,
            text: "We need to refactor the database layer",
            confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [seg], speakerEmbeddings: [:], processingDuration: 1.0
        )
        let txID = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(txID, for: meetingID)

        let hits = try await store.searchHits("refactor", limit: 10)
        #expect(hits.count == 1)
        #expect(hits[0].id == meetingID)
        // The snippet comes from the transcript column, not the title.
        #expect(hits[0].snippet.contains("refactor"))
        #expect(hits[0].snippet.contains("database layer"))
    }

    /// The per-column bm25 weights are what make a title match outrank a
    /// transcript match. Asserted as an *ordering*, not an absolute score --
    /// bm25 values depend on corpus statistics and are not stable constants.
    @Test("searchHits ranks a title match above a transcript-only match")
    func searchHitsTitleOutranksTranscript() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Budget Review")
        let titleMatch = try await store.createMeeting(title: "Sprint Planning")

        let bodyMatch = try await store.createMeeting(title: "Weekly Sync")
        let seg = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0",
            startTime: 0, endTime: 5,
            text: "we should talk about the sprint at some point",
            confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [seg], speakerEmbeddings: [:], processingDuration: 1.0
        )
        let txID = try await store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: bodyMatch
        )
        try await store.setPreferredTranscript(txID, for: bodyMatch)

        let hits = try await store.searchHits("Sprint", limit: 10)
        #expect(hits.count == 2)
        #expect(hits[0].id == titleMatch)
        #expect(hits[1].id == bodyMatch)
        #expect(hits[0].score > hits[1].score)
    }

    @Test("searchHits returns empty for no match")
    func searchHitsNoMatch() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Standup")
        let hits = try await store.searchHits("Nonexistent", limit: 10)
        #expect(hits.isEmpty)
    }

    @Test("searchHits returns empty for empty query")
    func searchHitsEmptyQuery() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Standup")
        let hits = try await store.searchHits("", limit: 10)
        #expect(hits.isEmpty)
    }

    @Test("searchHits sorts by score descending")
    func searchHitsSortOrder() async throws {
        let store = try makeStore()

        _ = try await store.createMeeting(
            title: "Sprint Review",
            start: Date(timeIntervalSince1970: 1_000_000)
        )

        let meetingID = try await store.createMeeting(
            title: "Standup",
            start: Date(timeIntervalSince1970: 2_000_000)
        )
        let reviewer = try await store.findOrCreatePerson(name: "Review Lead", email: nil)
        try await store.setParticipants([reviewer], organizer: nil, for: meetingID)

        let hits = try await store.searchHits("review", limit: 10)
        #expect(hits.count == 2)
        #expect(hits[0].title == "Sprint Review") // score 3
        #expect(hits[1].title == "Standup") // score 2
    }

    @Test("searchHits respects limit")
    func searchHitsLimit() async throws {
        let store = try makeStore()
        for idx in 0 ..< 5 {
            _ = try await store.createMeeting(title: "Sprint \(idx)")
        }

        let hits = try await store.searchHits("Sprint", limit: 2)
        #expect(hits.count == 2)
    }
}

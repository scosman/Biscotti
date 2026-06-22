import AppKit
import BiscottiTestSupport
import DataStore
import Foundation
import Intelligence
import Testing
import Transcription
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - Helpers

/// Builds a 3-segment TranscriptResult where speaker 1 appears first,
/// then speaker 0, then speaker 1 again -- useful for testing first-seen
/// ordering in the sheet.
private func threeSegmentResult() -> TranscriptResult {
    let segments = [
        TranscriptSegment(
            speakerID: 1, speakerLabel: "Speaker 1",
            startTime: 0, endTime: 5, text: "Hello",
            confidence: 0.9, noSpeechProbability: 0.01, words: nil
        ),
        TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0",
            startTime: 5, endTime: 10, text: "Hi",
            confidence: 0.9, noSpeechProbability: 0.01, words: nil
        ),
        TranscriptSegment(
            speakerID: 1, speakerLabel: "Speaker 1",
            startTime: 10, endTime: 15, text: "Again",
            confidence: 0.9, noSpeechProbability: 0.01, words: nil
        )
    ]
    return TranscriptResult(
        transcriptionMethodId: "test-v1", language: "en",
        speakerCount: 2, segments: segments,
        speakerEmbeddings: [:], processingDuration: 1.0
    )
}

// MARK: - Sheet data assembly

@Suite("Speaker mapping sheet -- data assembly")
struct SpeakerSheetAssemblyTests {
    @Test("builds rows from distinct speaker IDs in segment order")
    @MainActor
    func rowsFromSegments() async throws {
        let fix = try makeCoreFixture(testName: "SpeakerSheet")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = threeSegmentResult()
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        guard let transcript = viewModel.displayedTranscript else {
            Issue.record("Expected a displayed transcript")
            return
        }

        let sheetData = await viewModel.buildSpeakerSheetData(
            transcript: transcript
        )

        // Rows should be in first-seen order: 1, 0
        #expect(sheetData.rows.count == 2)
        #expect(sheetData.rows[0].speakerID == 1)
        #expect(sheetData.rows[1].speakerID == 0)
        #expect(sheetData.rows[0].label == "Speaker 1")
        #expect(sheetData.rows[1].label == "Speaker 0")
        // Initially unassigned
        #expect(sheetData.rows[0].assigned == nil)
        #expect(sheetData.rows[1].assigned == nil)
    }

    @Test("no calendar context yields empty invitees")
    @MainActor
    func noCalendarEmptyInvitees() async throws {
        let fix = try makeCoreFixture(testName: "SpeakerSheet")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        guard let transcript = viewModel.displayedTranscript else {
            Issue.record("Expected a displayed transcript")
            return
        }

        let sheetData = await viewModel.buildSpeakerSheetData(
            transcript: transcript
        )

        // No calendar context => empty invitees
        #expect(sheetData.invitees.isEmpty)
    }

    @Test("dedupes people against invitees")
    @MainActor
    func dedupesPeopleAgainstInvitees() async throws {
        let fix = try makeCoreFixture(testName: "SpeakerSheet")
        defer { fix.cleanup() }

        // Create a person
        let personID = try await fix.store.findOrCreatePerson(
            name: "New Person", email: nil
        )

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        guard let transcript = viewModel.displayedTranscript else {
            Issue.record("Expected a displayed transcript")
            return
        }

        let sheetData = await viewModel.buildSpeakerSheetData(
            transcript: transcript
        )

        // No invitees (no calendar context)
        #expect(sheetData.invitees.isEmpty)
        // Person should appear in people list
        let personIDs = sheetData.people.map(\.id)
        #expect(personIDs.contains(personID))
    }
}

// MARK: - Focused speaker ID

@Suite("Speaker mapping sheet -- focused speaker")
struct SpeakerSheetFocusTests {
    @Test("openSpeakerSheet sets focusedSpeakerID to clicked speaker")
    @MainActor
    func focusedSpeakerIDSet() async throws {
        let fix = try makeCoreFixture(testName: "SpeakerSheet")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = threeSegmentResult()
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Open sheet focused on speaker 1
        await viewModel.openSpeakerSheet(speakerID: 1)
        #expect(viewModel.speakerSheetData?.focusedSpeakerID == 1)

        // Close and reopen focused on speaker 0
        viewModel.speakerSheetTranscriptID = nil
        await viewModel.openSpeakerSheet(speakerID: 0)
        #expect(viewModel.speakerSheetData?.focusedSpeakerID == 0)
    }

    @Test("reloadAfterSpeakerChange preserves focusedSpeakerID")
    @MainActor
    func focusPreservedAcrossReload() async throws {
        let fix = try makeCoreFixture(testName: "SpeakerSheet")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = threeSegmentResult()
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let personID = try await fix.store.findOrCreatePerson(
            name: "Alex", email: nil
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Open sheet focused on speaker 1
        await viewModel.openSpeakerSheet(speakerID: 1)
        #expect(viewModel.speakerSheetData?.focusedSpeakerID == 1)

        // Assign speaker 0 (triggers reloadAfterSpeakerChange)
        await viewModel.assignSpeaker(
            speakerID: 0, personID: personID
        )

        // focusedSpeakerID should still be 1 after reload
        #expect(viewModel.speakerSheetData?.focusedSpeakerID == 1)
    }
}

// MARK: - Speaker assignment actions

@Suite("Speaker mapping sheet -- assign/clear actions")
struct SpeakerAssignmentTests {
    @Test("assignSpeaker persists and reloads names")
    @MainActor
    func assignPersists() async throws {
        let fix = try makeCoreFixture(testName: "SpeakerSheet")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let personID = try await fix.store.findOrCreatePerson(
            name: "Daniel Lee", email: "daniel@test.com"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Open the sheet
        await viewModel.openSpeakerSheet(speakerID: 0)
        #expect(viewModel.speakerSheetTranscriptID == transcriptID)

        // Assign speaker 0 to Daniel
        await viewModel.assignSpeaker(
            speakerID: 0, personID: personID
        )

        // Verify the name is now in displayed speaker names
        #expect(viewModel.displayedSpeakerNames[0] == "Daniel Lee")

        // Verify persisted in store
        let transcript = try await fix.store.transcript(
            id: transcriptID
        )
        #expect(transcript?.speakerAssignments[0]?.name == "Daniel Lee")
    }

    @Test("unassignSpeaker clears the assignment")
    @MainActor
    func unassignClears() async throws {
        let fix = try makeCoreFixture(testName: "SpeakerSheet")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let personID = try await fix.store.findOrCreatePerson(
            name: "Daniel", email: nil
        )

        // First assign
        try await fix.store.setSpeakerAssignment(
            speakerID: 0, personID: personID, for: transcriptID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.displayedSpeakerNames[0] == "Daniel")

        // Open sheet and unassign
        await viewModel.openSpeakerSheet(speakerID: 0)
        await viewModel.unassignSpeaker(speakerID: 0)

        // Name should be cleared
        #expect(viewModel.displayedSpeakerNames[0] == nil)
    }

    @Test("assignNewPerson creates a person and assigns")
    @MainActor
    func assignNewPerson() async throws {
        let fix = try makeCoreFixture(testName: "SpeakerSheet")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Open sheet and add new person
        await viewModel.openSpeakerSheet(speakerID: 1)
        await viewModel.assignNewPerson(
            speakerID: 1, name: "  Priya  "
        )

        // Name should be assigned (trimmed)
        #expect(viewModel.displayedSpeakerNames[1] == "Priya")

        // Person should exist in the store
        let allPeople = try await fix.store.allPersonData()
        let priya = allPeople.first { $0.name == "Priya" }
        #expect(priya != nil)
    }

    @Test("assignNewPerson with empty name is a no-op")
    @MainActor
    func assignNewPersonEmptyName() async throws {
        let fix = try makeCoreFixture(testName: "SpeakerSheet")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        await viewModel.openSpeakerSheet(speakerID: 0)
        await viewModel.assignNewPerson(speakerID: 0, name: "   ")

        #expect(viewModel.displayedSpeakerNames[0] == nil)
    }
}

// MARK: - Displayed names update on assignment

@Suite("Displayed transcript reflects speaker name assignments")
struct TranscriptCacheNameTests {
    @Test("displayed name updates when a speaker is assigned")
    @MainActor
    func nameUpdatesOnAssignment() async throws {
        let fix = try makeCoreFixture(testName: "SpeakerSheet")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Before assignment: speaker 0 is unmapped and the rendered
        // transcript (the path used for display and copy) shows "Speaker 0".
        #expect(viewModel.displayedSpeakerNames[0] == nil)
        let segments1 = try #require(viewModel.displayedTranscript?.segments)
        let text1 = TranscriptContent.plainText(
            segments1, names: viewModel.displayedSpeakerNames
        )
        #expect(text1.contains("Speaker 0"))

        // Now assign a name
        let personID = try await fix.store.findOrCreatePerson(
            name: "Daniel", email: nil
        )

        await viewModel.openSpeakerSheet(speakerID: 0)
        await viewModel.assignSpeaker(
            speakerID: 0, personID: personID
        )

        // After assignment: the name map updates and the rendered transcript
        // shows "Daniel" in place of "Speaker 0".
        #expect(viewModel.displayedSpeakerNames[0] == "Daniel")
        let segments2 = try #require(viewModel.displayedTranscript?.segments)
        let text2 = TranscriptContent.plainText(
            segments2, names: viewModel.displayedSpeakerNames
        )
        #expect(text2.contains("Daniel"))
        #expect(!text2.contains("Speaker 0"))
    }
}

// MARK: - Color keys update on assignment (Phase 11)

@Suite("Displayed speaker color keys reflect assignments")
struct TranscriptCacheColorKeyTests {
    @Test("color keys update when speakers are assigned to a person")
    @MainActor
    func colorKeysUpdateOnAssignment() async throws {
        let fix = try makeCoreFixture(testName: "SpeakerSheet")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Initially no color keys
        #expect(viewModel.displayedSpeakerColorKeys.isEmpty)

        // Assign two speakers to the same person
        let personID = try await fix.store.findOrCreatePerson(
            name: "Shared Person", email: nil
        )

        await viewModel.openSpeakerSheet(speakerID: 0)
        await viewModel.assignSpeaker(
            speakerID: 0, personID: personID
        )

        // Color keys should now include speaker 0
        let keys1 = viewModel.displayedSpeakerColorKeys
        #expect(keys1[0] == "person-\(personID.uuidString)")

        // Assign speaker 1 to the same person
        await viewModel.assignSpeaker(
            speakerID: 1, personID: personID
        )

        // Both speakers should have the same color key, so the transcript
        // rows render them with a shared color.
        let keys2 = viewModel.displayedSpeakerColorKeys
        #expect(keys2[0] == keys2[1])
        #expect(keys2[0] == "person-\(personID.uuidString)")
    }
}

// MARK: - Sheet works without model

@Suite("Speaker mapping sheet -- works without model")
struct SpeakerSheetModelFreeTests {
    @Test("sheet opens and assignments work with no model downloaded")
    @MainActor
    func worksWithoutModel() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: false,
            testName: "SpeakerSheet"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Model is not available
        #expect(viewModel.modelAvailable == false)

        // Open sheet and assign -- should work
        await viewModel.openSpeakerSheet(speakerID: 0)
        #expect(viewModel.speakerSheetTranscriptID != nil)

        await viewModel.assignNewPerson(
            speakerID: 0, name: "Manual Person"
        )
        #expect(
            viewModel.displayedSpeakerNames[0] == "Manual Person"
        )
    }
}

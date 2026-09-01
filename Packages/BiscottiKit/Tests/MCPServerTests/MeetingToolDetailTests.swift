import DataStore
import Foundation
import MCP
import Testing
import Transcription
@testable import MCPServer

/// `biscotti_get_meeting` and `biscotti_get_transcript` against an in-memory
/// `DataStore`, no sockets (architecture §10 "Tool logic").
@Suite("biscotti_get_meeting / biscotti_get_transcript")
struct MeetingToolDetailTests {
    // MARK: - Fixtures

    private func seedRichMeeting(_ store: DataStore) async throws -> UUID {
        let meetingID = try await store.createMeeting(
            title: "Weekly sync",
            start: ToolDateFormatting.parse("2026-08-27T17:00:00Z"),
            end: ToolDateFormatting.parse("2026-08-27T17:30:00Z")
        )
        let organizerID = try await store.findOrCreatePerson(name: "Ada L.", email: "ada@example.com")
        var participantIDs: [UUID] = []
        for idx in 1 ... 6 {
            try await participantIDs.append(
                store.findOrCreatePerson(name: "Person \(idx)", email: nil)
            )
        }
        try await store.setParticipants(participantIDs, organizer: organizerID, for: meetingID)

        _ = try await store.createTagAndApply(name: "eng", to: meetingID)
        _ = try await store.createTagAndApply(name: "roadmap", to: meetingID)

        try await store.applyGeneratedSummary("## Decisions\nShip it.", for: meetingID)
        try await store.setNotes("my own notes", for: meetingID)
        // .7 fraction: rounded (1805), not truncated (1804).
        try await store.setRecordingDuration(1804.7, for: meetingID)

        try await store.attachAudio(
            [AudioFileRef(role: .mic, path: "/tmp/mic.aac", byteSize: 100, isPresent: true),
             AudioFileRef(role: .system, path: "/tmp/system.aac", byteSize: 200, isPresent: true)],
            to: meetingID
        )

        let snapshot = CalendarSnapshot(
            compositeKey: "weekly-sync-2026-08-27",
            title: "Weekly sync",
            startDate: ToolDateFormatting.parse("2026-08-27T17:00:00Z"),
            endDate: ToolDateFormatting.parse("2026-08-27T17:30:00Z"),
            location: "Room 5",
            eventNotes: "Recurring weekly",
            calendarTitle: "Work",
            conferenceURL: URL(string: "https://zoom.example/join"),
            conferencePlatform: "Zoom"
        )
        try await store.setSnapshot(snapshot, for: meetingID)

        let transcriptID = try await ToolTestSupport.addTranscript(
            to: store,
            meetingID: meetingID,
            segments: [
                ToolTestSupport.makeSegment("Hello world", speaker: 0, label: "Speaker 0", start: 0),
                ToolTestSupport.makeSegment(
                    "Second segment here", speaker: 1, label: "Speaker 1", start: 10
                ),
                ToolTestSupport.makeSegment("Boom", speaker: 0, label: "Speaker 0", start: 20)
            ]
        )
        try await store.setSpeakerAssignment(
            speakerID: 0, personID: organizerID, for: transcriptID
        )
        return meetingID
    }

    // MARK: - get_meeting

    @Test("full payload for a rich meeting")
    func getMeetingRichPayload() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let meetingID = try await seedRichMeeting(store)

        let result = try await provider.call(
            name: "biscotti_get_meeting",
            arguments: ["id": .string(meetingID.uuidString)]
        )
        #expect(result.isError != true)
        let object = try ToolTestSupport.jsonObject(from: result)

        #expect(object["id"] as? String == meetingID.uuidString)
        #expect(object["title"] as? String == "Weekly sync")
        #expect(object["date"] as? String == "2026-08-27T17:00:00Z")
        // The app link: canonical form, default Summary target (no query).
        #expect(
            object["app_url"] as? String
                == "biscotti://meeting/\(meetingID.uuidString)"
        )
        #expect(object["end_date"] as? String == "2026-08-27T17:30:00Z")
        #expect(object["recording_duration_seconds"] as? Int == 1805)
        #expect(object["summary"] as? String == "## Decisions\nShip it.")
        #expect(object["notes"] as? String == "my own notes")
        #expect(object["tags"] as? [String] == ["eng", "roadmap"])
        #expect(object["transcript_version_count"] as? Int == 1)

        // Participants uncapped; organizer separate.
        let participants = try #require(object["participants"] as? [[String: Any]])
        #expect(participants.count == 6)
        let organizer = try #require(object["organizer"] as? [String: Any])
        #expect(organizer["name"] as? String == "Ada L.")
        #expect(organizer["email"] as? String == "ada@example.com")

        // Audio.
        let audio = try #require(object["audio_files"] as? [String: Any])
        #expect(audio["microphone"] as? String == "/tmp/mic.aac")
        #expect(audio["system"] as? String == "/tmp/system.aac")
        #expect(audio["present"] as? Bool == true)

        // Calendar.
        let calendar = try #require(object["calendar"] as? [String: Any])
        #expect(calendar["title"] as? String == "Weekly sync")
        #expect(calendar["conference_platform"] as? String == "Zoom")
        #expect(calendar["conference_url"] as? String == "https://zoom.example/join")
        #expect(calendar["calendar_name"] as? String == "Work")
        #expect(calendar["notes"] as? String == "Recurring weekly")

        // Transcript stats: 3 segments; "Hello world" (2 words / 11 chars),
        // "Second segment here" (3 / 19), "Boom" (1 / 4).
        let transcript = try #require(object["transcript"] as? [String: Any])
        #expect(transcript["available"] as? Bool == true)
        #expect(transcript["segment_count"] as? Int == 3)
        #expect(transcript["word_count"] as? Int == 6)
        #expect(transcript["character_count"] as? Int == 34)
        #expect(transcript["speaker_count"] as? Int == 2)
        let speakers = try #require(transcript["speakers"] as? [[String: Any]])
        #expect(speakers.count == 2) // distinct in segment order despite 0,1,0
        #expect(speakers[0]["id"] as? Int == 0)
        #expect(speakers[0]["name"] as? String == "Ada L.") // mapped
        #expect(speakers[1]["id"] as? Int == 1)
        #expect(speakers[1].keys.contains("name") == false) // unmapped: omitted
    }

    @Test("summary and notes are always present; other inapplicable fields omitted")
    func getMeetingSparsePayload() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let meetingID = try await store.createMeeting(title: "Bare meeting")

        let result = try await provider.call(
            name: "biscotti_get_meeting",
            arguments: ["id": .string(meetingID.uuidString)]
        )
        #expect(result.isError != true)
        let object = try ToolTestSupport.jsonObject(from: result)

        // The two keys that must never go missing: present, null.
        #expect(object["summary"] is NSNull)
        #expect(object["notes"] is NSNull)

        // The app link is always present for a meeting that resolved.
        #expect(
            object["app_url"] as? String
                == "biscotti://meeting/\(meetingID.uuidString)"
        )

        for absentKey in [
            "end_date", "recording_duration_seconds", "tags",
            "participants", "organizer", "calendar"
        ] {
            #expect(object.keys.contains(absentKey) == false, "\(absentKey) should be omitted")
        }

        let transcript = try #require(object["transcript"] as? [String: Any])
        #expect(transcript["available"] as? Bool == false)
        #expect(Set(transcript.keys) == ["available"])

        // The no-refs audio shape (paths omitted) lives in MeetingToolAudioTests.
        #expect(object["transcript_version_count"] as? Int == 0)
    }

    @Test("unknown id is a tool error")
    func getMeetingUnknownID() async throws {
        let (provider, _) = try ToolTestSupport.makeProvider()
        let result = try await provider.call(
            name: "biscotti_get_meeting",
            arguments: ["id": .string(UUID().uuidString)]
        )
        #expect(try ToolTestSupport.errorText(result) == "No meeting with that id.")
    }

    @Test("malformed id is invalid params")
    func getMeetingMalformedID() async throws {
        let (provider, _) = try ToolTestSupport.makeProvider()
        try await ToolTestSupport.expectInvalidParams(
            provider, name: "biscotti_get_meeting", arguments: ["id": .string("not-a-uuid")]
        )
        try await ToolTestSupport.expectInvalidParams(
            provider, name: "biscotti_get_meeting", arguments: nil
        )
    }

    // MARK: - get_transcript

    @Test("collapses turns, maps names, and counts on segments")
    func getTranscriptFormatting() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let meetingID = try await store.createMeeting(title: "Sync")
        let organizerID = try await store.findOrCreatePerson(name: "Ada L.", email: nil)
        let transcriptID = try await ToolTestSupport.addTranscript(
            to: store,
            meetingID: meetingID,
            segments: [
                ToolTestSupport.makeSegment("  Hello  ", speaker: 0, label: "Speaker 0", start: 4.2),
                ToolTestSupport.makeSegment(
                    "more words", speaker: 0, label: "Speaker 0", start: 8
                ),
                ToolTestSupport.makeSegment("Hi", speaker: 1, label: "Speaker 1", start: 31)
            ]
        )
        try await store.setSpeakerAssignment(
            speakerID: 0, personID: organizerID, for: transcriptID
        )

        let result = try await provider.call(
            name: "biscotti_get_transcript",
            arguments: ["id": .string(meetingID.uuidString)]
        )
        #expect(result.isError != true)
        let object = try ToolTestSupport.jsonObject(from: result)

        #expect(object["id"] as? String == meetingID.uuidString)
        #expect(object["transcript_id"] as? String == transcriptID.uuidString)
        #expect(
            object["text"] as? String == "[00:04] Ada L.\nHello more words\n\n[00:31] Speaker 1\nHi"
        )
        #expect(object["word_count"] as? Int == 4)
        #expect(object["character_count"] as? Int == 21)
    }

    @Test("empty transcript is not an error")
    func getTranscriptEmpty() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let meetingID = try await store.createMeeting(title: "Empty")
        try await ToolTestSupport.addTranscript(
            to: store, meetingID: meetingID, segments: [], speakerCount: 0
        )

        let result = try await provider.call(
            name: "biscotti_get_transcript",
            arguments: ["id": .string(meetingID.uuidString)]
        )
        #expect(result.isError != true)
        let object = try ToolTestSupport.jsonObject(from: result)
        #expect(object["text"] as? String == "")
        #expect(object["word_count"] as? Int == 0)
        #expect(object["character_count"] as? Int == 0)
    }

    @Test("tool errors: unknown id, no transcript")
    func getTranscriptErrors() async throws {
        let (provider, store) = try ToolTestSupport.makeProvider()
        let unknownResult = try await provider.call(
            name: "biscotti_get_transcript",
            arguments: ["id": .string(UUID().uuidString)]
        )
        #expect(try ToolTestSupport.errorText(unknownResult) == "No meeting with that id.")

        let meetingID = try await store.createMeeting(title: "No transcript yet")
        let noTranscriptResult = try await provider.call(
            name: "biscotti_get_transcript",
            arguments: ["id": .string(meetingID.uuidString)]
        )
        #expect(
            try ToolTestSupport.errorText(noTranscriptResult) == "That meeting has no transcript yet."
        )
    }

    // MARK: - Dispatch

    @Test("unknown tool name is method not found")
    func unknownToolName() async throws {
        let (provider, _) = try ToolTestSupport.makeProvider()
        do {
            let result = try await provider.call(name: "biscotti_nonsense", arguments: [:])
            Issue.record("Expected methodNotFound, got a result: \(result)")
        } catch let error as MCPError {
            #expect(error.code == -32601)
        }
    }
}

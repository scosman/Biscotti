import Foundation
import Testing
@testable import MCPServer

/// Golden-JSON assertions on the wire contract (architecture §10): snake_case
/// keys, optional fields omitted rather than emitted as `null` — except
/// `MeetingDetailPayload.summary`/`notes`, which always serialize. Decoded via
/// `JSONSerialization` so drift fails loudly.
@Suite("Tool payload encoding")
struct MeetingToolPayloadTests {
    private func encodeToJSONObject(_ payload: some Codable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("QueryMeetingsPayload keys")
    func queryPayloadKeys() throws {
        let withSnippet = MeetingResultItem(
            id: "A", title: "T", date: "2026-08-27T17:00:00Z", querySnippet: "…hit…"
        )
        let withoutSnippet = MeetingResultItem(
            id: "B", title: "T", date: "2026-08-26T17:00:00Z", querySnippet: nil
        )
        let payload = QueryMeetingsPayload(results: [withSnippet, withoutSnippet], resultsTruncated: false)

        let object = try encodeToJSONObject(payload)
        #expect(Set(object.keys) == Set(["results", "results_truncated"]))
        let results = try #require(object["results"] as? [[String: Any]])
        #expect(Set(results[0].keys) == Set(["date", "id", "query_snippet", "title"]))
        #expect(Set(results[1].keys) == Set(["date", "id", "title"]))
    }

    @Test("MeetingDetailPayload emits summary/notes as null, omits other nil optionals")
    func detailPayloadKeys() throws {
        let payload = MeetingDetailPayload(
            id: "A",
            title: "T",
            date: "2026-08-27T17:00:00Z",
            appURL: "biscotti://meeting/A",
            endDate: nil,
            recordingDurationSeconds: nil,
            summary: nil,
            notes: nil,
            tags: nil,
            participants: nil,
            organizer: nil,
            audioFiles: AudioFilesPayload(
                microphone: nil, system: nil, present: false
            ),
            calendar: nil,
            transcript: TranscriptStatsPayload(
                available: false,
                id: nil,
                createdAt: nil,
                segmentCount: nil,
                wordCount: nil,
                characterCount: nil,
                speakerCount: nil,
                speakers: nil
            ),
            transcriptVersionCount: 0
        )

        let object = try encodeToJSONObject(payload)
        #expect(
            Set(object.keys) == Set([
                "app_url", "audio_files", "date", "id", "notes", "summary",
                "title", "transcript", "transcript_version_count"
            ])
        )
        // The link is always present for a meeting that resolved.
        #expect(object["app_url"] as? String == "biscotti://meeting/A")
        // The two keys a caller read as missing-when-empty: present, null.
        #expect(object["summary"] is NSNull)
        #expect(object["notes"] is NSNull)
        let audio = try #require(object["audio_files"] as? [String: Any])
        #expect(Set(audio.keys) == ["present"])
        let transcript = try #require(object["transcript"] as? [String: Any])
        #expect(Set(transcript.keys) == ["available"])
    }

    @Test("MeetingDetailPayload decodes explicit nulls and missing keys the same")
    func detailPayloadDecodesNulls() throws {
        let json = Data(
            #"{"id":"A","title":"T","date":"2026-08-27T17:00:00Z","app_url":"biscotti://meeting/A","summary":null,"notes":null,"audio_files":{"present":false},"transcript":{"available":false},"transcript_version_count":0}"#
                .utf8
        )
        let payload = try JSONDecoder().decode(MeetingDetailPayload.self, from: json)
        #expect(payload.summary == nil)
        #expect(payload.notes == nil)
        #expect(payload.recordingDurationSeconds == nil)
        #expect(payload.appURL == "biscotti://meeting/A")
    }

    private func makeFullDetailPayload() -> MeetingDetailPayload {
        let person = PersonPayload(name: "Ada L.", email: "ada@example.com")
        let barePerson = PersonPayload(name: "No Email", email: nil)
        return MeetingDetailPayload(
            id: "A",
            title: "T",
            date: "2026-08-27T17:00:00Z",
            appURL: "biscotti://meeting/A",
            endDate: "2026-08-27T17:30:00Z",
            recordingDurationSeconds: 1804,
            summary: "## Decisions",
            notes: "note",
            tags: ["eng"],
            participants: [barePerson],
            organizer: person,
            audioFiles: AudioFilesPayload(
                microphone: "/m.aac", system: "/s.aac", present: true
            ),
            calendar: CalendarPayload(
                title: "Weekly sync",
                start: "2026-08-27T17:00:00Z",
                end: "2026-08-27T17:30:00Z",
                location: "Room 5",
                conferencePlatform: "Zoom",
                conferenceURL: "https://zoom.example/join",
                calendarName: "Work",
                organizer: person,
                attendees: [person],
                notes: "desc"
            ),
            transcript: TranscriptStatsPayload(
                available: true,
                id: "T1",
                createdAt: "2026-08-27T18:00:00Z",
                segmentCount: 412,
                wordCount: 6180,
                characterCount: 34117,
                speakerCount: 3,
                speakers: [
                    SpeakerPayload(id: 0, label: "Speaker 1", name: "Ada L."),
                    SpeakerPayload(id: 1, label: "Speaker 2", name: nil)
                ]
            ),
            transcriptVersionCount: 2
        )
    }

    @Test("MeetingDetailPayload full key surface")
    func detailPayloadFullKeys() throws {
        let object = try encodeToJSONObject(makeFullDetailPayload())
        #expect(
            Set(object.keys) == Set([
                "app_url", "audio_files", "calendar", "date", "end_date",
                "id", "notes", "organizer", "participants",
                "recording_duration_seconds", "summary", "tags", "title",
                "transcript", "transcript_version_count"
            ])
        )
        #expect(object["recording_duration_seconds"] as? Int == 1804)

        let calendar = try #require(object["calendar"] as? [String: Any])
        #expect(
            Set(calendar.keys) == Set([
                "attendees", "calendar_name", "conference_platform", "conference_url",
                "end", "location", "notes", "organizer", "start", "title"
            ])
        )

        let transcript = try #require(object["transcript"] as? [String: Any])
        #expect(
            Set(transcript.keys) == Set([
                "available", "character_count", "created_at", "id", "segment_count",
                "speaker_count", "speakers", "word_count"
            ])
        )
        let speakers = try #require(transcript["speakers"] as? [[String: Any]])
        #expect(Set(speakers[0].keys) == Set(["id", "label", "name"]))
        #expect(Set(speakers[1].keys) == Set(["id", "label"]))

        let participants = try #require(object["participants"] as? [[String: Any]])
        #expect(Set(participants[0].keys) == ["name"])
    }

    @Test("TranscriptPayload keys")
    func transcriptPayloadKeys() throws {
        let payload = TranscriptPayload(
            id: "A", transcriptID: "T", wordCount: 10, characterCount: 50, text: "…"
        )
        let object = try encodeToJSONObject(payload)
        #expect(
            Set(object.keys) == Set(["character_count", "id", "text", "transcript_id", "word_count"])
        )
    }
}

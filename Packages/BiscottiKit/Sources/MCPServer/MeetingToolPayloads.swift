import Foundation

// Wire DTOs for the three meeting tools (functional spec §5). Dates are
// pre-formatted ISO-8601 strings, so encoding needs no date strategy. Snake_case
// keys come from explicit `CodingKeys` — never a global encoder strategy — so a
// Swift property rename cannot silently change the wire contract. Optional
// fields are omitted when nil (`encodeIfPresent`), never emitted as `null`.
//
// The payload structs are flat (not nested in each other): each carries its own
// `CodingKeys`, and the repo's strict `nesting` rule caps type nesting at one
// level.

// MARK: - biscotti_query_meetings

struct QueryMeetingsPayload: Codable, Equatable {
    let results: [MeetingResultItem]
    /// True when the returned count equals the effective limit — more matches
    /// may exist.
    let resultsTruncated: Bool

    enum CodingKeys: String, CodingKey {
        case results
        case resultsTruncated = "results_truncated"
    }
}

struct MeetingResultItem: Codable, Equatable {
    let id: String
    let title: String
    let date: String
    /// Present only when the query carried a full-text `query`.
    let querySnippet: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case date
        case querySnippet = "query_snippet"
    }
}

// MARK: - biscotti_get_meeting

struct PersonPayload: Codable, Equatable {
    let name: String
    let email: String?

    enum CodingKeys: String, CodingKey {
        case name
        case email
    }
}

struct AudioFilesPayload: Codable, Equatable {
    let microphone: String?
    let system: String?
    let present: Bool

    enum CodingKeys: String, CodingKey {
        case microphone
        case system
        case present
    }
}

struct CalendarPayload: Codable, Equatable {
    let title: String?
    let start: String?
    let end: String?
    let location: String?
    let conferencePlatform: String?
    let conferenceURL: String?
    let calendarName: String?
    let organizer: PersonPayload?
    let attendees: [PersonPayload]?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case title
        case start
        case end
        case location
        case conferencePlatform = "conference_platform"
        case conferenceURL = "conference_url"
        case calendarName = "calendar_name"
        case organizer
        case attendees
        case notes
    }
}

struct SpeakerPayload: Codable, Equatable {
    let id: Int
    let label: String
    /// Only where the user mapped this speaker to a person.
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case name
    }
}

/// Statistics of the preferred transcript; `available: false` and nothing
/// else when no transcript exists.
struct TranscriptStatsPayload: Codable, Equatable {
    let available: Bool
    let id: String?
    let createdAt: String?
    let segmentCount: Int?
    let wordCount: Int?
    let characterCount: Int?
    let speakerCount: Int?
    let speakers: [SpeakerPayload]?

    enum CodingKeys: String, CodingKey {
        case available
        case id
        case createdAt = "created_at"
        case segmentCount = "segment_count"
        case wordCount = "word_count"
        case characterCount = "character_count"
        case speakerCount = "speaker_count"
        case speakers
    }
}

struct MeetingDetailPayload: Codable, Equatable {
    let id: String
    let title: String
    let date: String
    let endDate: String?
    let recordingDurationSeconds: Double?
    let summary: String?
    let notes: String?
    let tags: [String]?
    let participants: [PersonPayload]?
    let organizer: PersonPayload?
    let audioFiles: AudioFilesPayload
    let calendar: CalendarPayload?
    let transcript: TranscriptStatsPayload
    let transcriptVersionCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case date
        case endDate = "end_date"
        case recordingDurationSeconds = "recording_duration_seconds"
        case summary
        case notes
        case tags
        case participants
        case organizer
        case audioFiles = "audio_files"
        case calendar
        case transcript
        case transcriptVersionCount = "transcript_version_count"
    }
}

// MARK: - biscotti_get_transcript

struct TranscriptPayload: Codable, Equatable {
    let id: String
    let transcriptID: String
    let wordCount: Int
    let characterCount: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case id
        case transcriptID = "transcript_id"
        case wordCount = "word_count"
        case characterCount = "character_count"
        case text
    }
}

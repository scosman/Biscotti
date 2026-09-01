import Foundation
import MCP

/// The three read-only tools (functional spec §5). Descriptions live here and
/// nowhere else, verbatim from the spec, written for the calling agent.
/// Input schemas mirror the spec's parameter tables exactly, including the
/// `limit` bounds.
enum MeetingToolCatalog {
    static let queryMeetingsName = "biscotti_query_meetings"
    static let getMeetingName = "biscotti_get_meeting"
    static let getTranscriptName = "biscotti_get_transcript"

    static let all: [Tool] = [queryMeetings, getMeeting, getTranscript]

    /// All three tools are read-only over local data: no writes, no external
    /// effects, repeatable.
    private static let readOnlyAnnotations = Tool.Annotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    private static let queryMeetings = Tool(
        name: queryMeetingsName,
        description: "Search the user's recorded meetings in Biscotti. Results sorted by query relevance if query provided, and newest first when no query. Use `biscotti_get_meeting` for details and `biscotti_get_transcript` for what was said. Useful whenever the user asks about a meeting, call, sync, standup, or something someone said.",
        inputSchema: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Full-text search over title, summary, notes, transcript, people and tags. Prefix-matched per term, AND across terms."
                ],
                "after": [
                    "type": "string",
                    "description": "Only meetings whose date is on or after this ISO-8601 date-time with a time zone, e.g. `2026-08-30T14:03:00Z` or `2026-08-30T14:03:00+02:00` (a bare date like 2026-08-30 means local midnight)."
                ],
                "before": [
                    "type": "string",
                    "description": "Only meetings whose date is on or before this ISO-8601 date-time with a time zone, e.g. `2026-08-30T14:03:00Z` or `2026-08-30T14:03:00+02:00` (a bare date like 2026-08-30 means local midnight)."
                ],
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 250,
                    "description": "Maximum number of results to return (1-250, default 20)."
                ]
            ]
        ],
        annotations: readOnlyAnnotations,
        outputSchema: [
            "type": "object",
            "required": ["results", "results_truncated"],
            "properties": [
                "results": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "required": ["id", "title", "date"],
                        "properties": [
                            "id": ["type": "string"],
                            "title": ["type": "string"],
                            "date": ["type": "string"],
                            "query_snippet": ["type": "string"]
                        ]
                    ]
                ],
                "results_truncated": ["type": "boolean"]
            ]
        ]
    )

    private static let getMeeting = Tool(
        name: getMeetingName,
        description: "Full details for one Biscotti meeting: calendar context, AI summary, the user's notes, tags, participants, and transcript statistics. Does not include the transcript text — call `biscotti_get_transcript` for that.",
        inputSchema: [
            "type": "object",
            "required": ["id"],
            "properties": [
                "id": [
                    "type": "string",
                    "description": "The meeting's UUID, as returned by biscotti_query_meetings."
                ]
            ]
        ],
        annotations: readOnlyAnnotations,
        outputSchema: [
            "type": "object",
            "required": [
                "id", "title", "date", "app_url", "summary", "notes",
                "audio_files", "transcript", "transcript_version_count"
            ],
            "properties": [
                "id": ["type": "string"],
                "title": ["type": "string"],
                "date": ["type": "string"],
                "app_url": [
                    "type": "string",
                    "description": "A biscotti:// URL that opens this meeting in the Biscotti app on this Mac (its default Summary view). You may surface it to the user as a link. See App/deeplinks.md in the Biscotti repo for the full URL vocabulary."
                ],
                "end_date": ["type": "string"],
                "recording_duration_seconds": ["type": "integer"],
                "summary": [
                    "type": ["string", "null"],
                    "description": "The AI-generated summary; always present, null when the meeting has none."
                ],
                "notes": [
                    "type": ["string", "null"],
                    "description": "The user's own notes; always present, null when the meeting has none."
                ],
                "tags": ["type": "array", "items": ["type": "string"]],
                "participants": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "required": ["name"],
                        "properties": [
                            "name": ["type": "string"],
                            "email": ["type": "string"]
                        ]
                    ]
                ],
                "organizer": [
                    "type": "object",
                    "required": ["name"],
                    "properties": [
                        "name": ["type": "string"],
                        "email": ["type": "string"]
                    ]
                ],
                "audio_files": [
                    "type": "object",
                    "required": ["present"],
                    "properties": [
                        "microphone": ["type": "string"],
                        "system": ["type": "string"],
                        "present": ["type": "boolean"]
                    ]
                ],
                "calendar": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "start": ["type": "string"],
                        "end": ["type": "string"],
                        "location": ["type": "string"],
                        "conference_platform": ["type": "string"],
                        "conference_url": ["type": "string"],
                        "calendar_name": ["type": "string"],
                        "organizer": [
                            "type": "object",
                            "required": ["name"],
                            "properties": [
                                "name": ["type": "string"],
                                "email": ["type": "string"]
                            ]
                        ],
                        "attendees": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "required": ["name"],
                                "properties": [
                                    "name": ["type": "string"],
                                    "email": ["type": "string"]
                                ]
                            ]
                        ],
                        "notes": ["type": "string"]
                    ]
                ],
                "transcript": [
                    "type": "object",
                    "required": ["available"],
                    "properties": [
                        "available": ["type": "boolean"],
                        "id": ["type": "string"],
                        "created_at": ["type": "string"],
                        "segment_count": ["type": "integer"],
                        "word_count": ["type": "integer"],
                        "character_count": ["type": "integer"],
                        "speaker_count": ["type": "integer"],
                        "speakers": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "required": ["id", "label"],
                                "properties": [
                                    "id": ["type": "integer"],
                                    "label": ["type": "string"],
                                    "name": ["type": "string"]
                                ]
                            ]
                        ]
                    ]
                ],
                "transcript_version_count": ["type": "integer"]
            ]
        ]
    )

    private static let getTranscript = Tool(
        name: getTranscriptName,
        description: "The full diarized transcript of one Biscotti meeting, as plain text with speaker names and timestamps. This can be very long — a one-hour meeting runs to tens of thousands of words. Check `transcript.word_count` from `biscotti_get_meeting` first, and prefer the AI summary when you only need the gist.",
        inputSchema: [
            "type": "object",
            "required": ["id"],
            "properties": [
                "id": [
                    "type": "string",
                    "description": "The meeting's UUID, as returned by biscotti_query_meetings."
                ],
                "start_seconds": [
                    "type": "number",
                    "description": "Seconds from the start of the recording (0 = the beginning) where the returned window begins; inclusive. Only segments overlapping the `[start_seconds, end_seconds)` window are returned; either bound may be omitted. Timestamps in the returned text keep their original values."
                ],
                "end_seconds": [
                    "type": "number",
                    "description": "Seconds from the start of the recording where the returned window ends; exclusive. Only segments overlapping the `[start_seconds, end_seconds)` window are returned; either bound may be omitted. Timestamps in the returned text keep their original values."
                ]
            ]
        ],
        annotations: readOnlyAnnotations,
        outputSchema: [
            "type": "object",
            "required": ["id", "transcript_id", "word_count", "character_count", "text"],
            "properties": [
                "id": ["type": "string"],
                "transcript_id": ["type": "string"],
                "word_count": ["type": "integer"],
                "character_count": ["type": "integer"],
                "text": ["type": "string"]
            ]
        ]
    )
}

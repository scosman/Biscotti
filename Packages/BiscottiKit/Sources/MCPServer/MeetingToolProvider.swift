import AppLinks
import DataStore
import Formatting
import Foundation
import MCP

/// Implements the three read-only tools over `DataStore` (architecture §6).
/// Invalid arguments throw `MCPError.invalidParams` (a protocol error);
/// valid-but-unsatisfiable requests (unknown id, no transcript) return a tool
/// error result so the calling agent can recover (functional spec §5).
actor MeetingToolProvider {
    private let store: DataStore

    init(store: DataStore) {
        self.store = store
    }

    func call(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        let arguments = arguments ?? [:]
        do {
            switch name {
            case MeetingToolCatalog.queryMeetingsName:
                return try await queryMeetings(arguments: arguments)
            case MeetingToolCatalog.getMeetingName:
                return try await getMeeting(arguments: arguments)
            case MeetingToolCatalog.getTranscriptName:
                return try await getTranscript(arguments: arguments)
            default:
                throw MCPError.methodNotFound(name)
            }
        } catch let error as MCPError {
            // Protocol errors (invalid params, unknown tool) pass through.
            throw error
        } catch is CancellationError {
            // Task cancellation (client gone, server stopping) is not a tool
            // failure; let it propagate instead of a phantom tool error.
            throw CancellationError()
        } catch {
            // DataStore failures become a generic tool error. The underlying
            // error is logged but never returned — paths and queries could
            // leak (architecture §9).
            mcpServerLog.error(
                "Tool '\(name, privacy: .public)' failed: \(String(describing: error), privacy: .private)"
            )
            return toolError("Reading the meeting data failed. Try again.")
        }
    }

    // MARK: - biscotti_query_meetings

    private func queryMeetings(arguments: [String: Value]) async throws -> CallTool.Result {
        let query = try optionalNonEmptyString("query", in: arguments)
        let after = try optionalDate("after", in: arguments)
        let before = try optionalDate("before", in: arguments)
        let limit = try optionalInt(
            "limit", in: arguments, range: 1 ... MCPServerConfiguration.maxResultLimit
        ) ?? MCPServerConfiguration.defaultResultLimit

        // No filter is legal: the date-descending list of the most recent
        // meetings comes back (`limit` alone means "newest N").
        if let after, let before, after > before {
            throw MCPError.invalidParams("'after' must not be later than 'before'.")
        }

        let outcome = try await resultItems(
            query: query, after: after, before: before, limit: limit
        )

        mcpServerLog.debug(
            "tool query_meetings: query=\(query != nil), after=\(after != nil), before=\(before != nil), limit=\(limit), results=\(outcome.items.count), poolFull=\(outcome.poolExhausted)"
        )
        // "More results may exist" — past the limit, or (with a query)
        // outside the saturated candidate pool even when the post-filter
        // count is under the limit (architecture §6.1).
        let payload = QueryMeetingsPayload(
            results: outcome.items,
            resultsTruncated: outcome.items.count == limit || outcome.poolExhausted
        )
        return try success(payload)
    }

    // MARK: - biscotti_get_meeting

    private func getMeeting(arguments: [String: Value]) async throws -> CallTool.Result {
        let id = try requiredUUID("id", in: arguments)

        guard let detail = try await store.meetingDetail(id: id) else {
            return toolError("No meeting with that id.")
        }
        // Stored paths, not just present ones: a deleted file keeps its path
        // with `present: false` (functional spec §5.2).
        let audio = try await store.storedAudioFileRefs(meetingID: id)
        let people = try await store.meetingPeople(id: id)
            ?? MeetingPeople(organizer: nil, participants: [])

        mcpServerLog.debug(
            "tool get_meeting: transcript=\(detail.preferredTranscript != nil), versions=\(detail.versions.count)"
        )
        let payload = MeetingDetailPayload(
            id: detail.id.uuidString,
            title: detail.title,
            date: ToolDateFormatting.format(detail.date),
            appURL: AppLink.meeting(id: id, target: .tab(.summary))
                .url.absoluteString,
            endDate: detail.endDate.map(ToolDateFormatting.format),
            recordingDurationSeconds: detail.recordingDuration.map { Int($0.rounded()) },
            summary: detail.summary.isEmpty ? nil : detail.summary,
            notes: detail.notes.isEmpty ? nil : detail.notes,
            tags: detail.tags.isEmpty ? nil : detail.tags.map(\.name),
            participants: people.participants.isEmpty
                ? nil : people.participants.map(Self.personPayload),
            organizer: people.organizer.map(Self.personPayload),
            audioFiles: AudioFilesPayload(
                microphone: audio.mic?.path,
                system: audio.system?.path,
                present: audio.present
            ),
            calendar: detail.calendar.map(Self.calendarPayload),
            transcript: Self.transcriptStats(of: detail.preferredTranscript),
            transcriptVersionCount: detail.versions.count
        )
        return try success(payload)
    }

    // MARK: - biscotti_get_transcript

    private func getTranscript(arguments: [String: Value]) async throws -> CallTool.Result {
        let id = try requiredUUID("id", in: arguments)
        let startSeconds = try optionalNumber("start_seconds", in: arguments)
        let endSeconds = try optionalNumber("end_seconds", in: arguments)

        guard let detail = try await store.meetingDetail(id: id) else {
            return toolError("No meeting with that id.")
        }
        guard let preferred = detail.preferredTranscript else {
            return toolError("That meeting has no transcript yet.")
        }

        // Window params filter before formatting; the timestamp text of each
        // line keeps its original from-the-start values (functional spec §5.3).
        let segments = Self.windowed(
            preferred.segments, startSeconds: startSeconds, endSeconds: endSeconds
        )
        let text = TranscriptTextFormatting.render(
            segments,
            names: preferred.speakerAssignments.mapValues(\.name)
        )
        mcpServerLog.debug(
            "tool get_transcript: segments=\(segments.count)/\(preferred.segments.count), windowed=\(startSeconds != nil || endSeconds != nil)"
        )
        let payload = TranscriptPayload(
            id: detail.id.uuidString,
            transcriptID: preferred.id.uuidString,
            wordCount: Self.wordCount(of: segments),
            characterCount: Self.characterCount(of: segments),
            text: text
        )
        return try success(payload)
    }

    // MARK: - Result helpers

    /// Overlap filter for the window params (functional spec §5.3): a
    /// segment is kept when it overlaps the half-open `[start, end)` window
    /// — start inclusive, end exclusive. A missing bound leaves that side
    /// unbounded. A window with both bounds and `start ≥ end` is empty
    /// (interval math alone would keep a segment straddling the window).
    private static func windowed(
        _ segments: [SegmentData], startSeconds: Double?, endSeconds: Double?
    ) -> [SegmentData] {
        if let startSeconds, let endSeconds, startSeconds >= endSeconds {
            return []
        }
        guard startSeconds != nil || endSeconds != nil else { return segments }
        return segments.filter { segment in
            let overlapsStart = startSeconds.map { segment.endTime > $0 } ?? true
            let overlapsEnd = endSeconds.map { segment.startTime < $0 } ?? true
            return overlapsStart && overlapsEnd
        }
    }

    /// Success carries the payload twice: as `structuredContent` and as the
    /// same DTO serialized to sorted-key JSON text — one source of truth, two
    /// encodings (architecture §5.2).
    private func success(_ payload: some Codable) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPError.internalError("Tool payload was not valid UTF-8")
        }
        return try CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: payload
        )
    }

    private func toolError(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    // MARK: - Payload mapping

    private static func personPayload(_ person: PersonData) -> PersonPayload {
        PersonPayload(name: person.name, email: person.email)
    }

    private static func calendarPayload(
        _ calendar: CalendarContextData
    ) -> CalendarPayload {
        CalendarPayload(
            title: calendar.title,
            start: calendar.startDate.map(ToolDateFormatting.format),
            end: calendar.endDate.map(ToolDateFormatting.format),
            location: calendar.location,
            conferencePlatform: calendar.conferencePlatform,
            conferenceURL: calendar.conferenceURL?.absoluteString,
            calendarName: calendar.calendarTitle,
            organizer: calendar.organizer.map(personPayload),
            attendees: calendar.attendees.isEmpty
                ? nil : calendar.attendees.map(personPayload),
            notes: calendar.eventNotes
        )
    }

    /// Distinct speaker id/label pairs in segment order. Segments without a
    /// diarization id contribute nothing: they have no stable id to report
    /// and their label is not a speaker.
    private static func speakers(
        of transcript: TranscriptData
    ) -> [SpeakerPayload] {
        var result: [SpeakerPayload] = []
        var seenIDs: Set<Int> = []
        for segment in transcript.segments {
            guard let speakerID = segment.speakerID, seenIDs.insert(speakerID).inserted else {
                continue
            }
            result.append(
                SpeakerPayload(
                    id: speakerID,
                    label: segment.speakerLabel,
                    name: transcript.speakerAssignments[speakerID]?.name
                )
            )
        }
        return result
    }

    /// Statistics of the preferred transcript, or `available: false` when
    /// none exists.
    private static func transcriptStats(
        of transcript: TranscriptData?
    ) -> TranscriptStatsPayload {
        guard let transcript else {
            return TranscriptStatsPayload(
                available: false,
                id: nil,
                createdAt: nil,
                segmentCount: nil,
                wordCount: nil,
                characterCount: nil,
                speakerCount: nil,
                speakers: nil
            )
        }
        return TranscriptStatsPayload(
            available: true,
            id: transcript.id.uuidString,
            createdAt: ToolDateFormatting.format(transcript.createdAt),
            segmentCount: transcript.segments.count,
            wordCount: wordCount(of: transcript.segments),
            characterCount: characterCount(of: transcript.segments),
            speakerCount: transcript.speakerCount,
            speakers: speakers(of: transcript)
        )
    }

    /// Computed on the segments (not the formatted text) so `get_meeting`
    /// and `get_transcript` counts agree exactly (architecture §6.3).
    private static func wordCount(of segments: [SegmentData]) -> Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    private static func characterCount(of segments: [SegmentData]) -> Int {
        segments.reduce(0) { $0 + $1.text.count }
    }
}

// MARK: - Query assembly

private extension MeetingToolProvider {
    /// The query path's outcome carries the pool signal next to the items:
    /// a saturated candidate pool means further matches may exist outside
    /// it, which the date filter and prefix cannot see.
    typealias QueryOutcome = (
        items: [MeetingResultItem], poolExhausted: Bool
    )

    /// Assembles `biscotti_query_meetings` results from either the ranked
    /// FTS pool (with a query) or the date-descending summaries (without).
    func resultItems(
        query: String?, after: Date?, before: Date?, limit: Int
    ) async throws -> QueryOutcome {
        func inRange(_ date: Date) -> Bool {
            (after.map { date >= $0 } ?? true) && (before.map { date <= $0 } ?? true)
        }

        if let query {
            // Ranked candidates come from the FTS index in a bounded pool
            // before the date filter is applied (architecture §6.1); order is
            // the FTS total order (bm25, then date desc, then UUID).
            let hits = try await store.searchHits(
                query, limit: MCPServerConfiguration.searchCandidatePool
            )
            // A full pool means the index had at least this many matches:
            // more may exist beyond it, so the truncation flag must fire
            // even when the filtered result count is under the limit.
            let poolExhausted = hits.count >= MCPServerConfiguration.searchCandidatePool
            let items = hits.filter { inRange($0.date) }
                .prefix(limit)
                .map { hit in
                    MeetingResultItem(
                        id: hit.id.uuidString,
                        title: hit.title,
                        date: ToolDateFormatting.format(hit.date),
                        querySnippet: hit.snippet
                    )
                }
            return (items, poolExhausted)
        }

        // meetingSummaries is already date-descending, and every meeting in
        // the store was considered — no bounded pool, no hidden matches.
        let summaries = try await store.meetingSummaries(limit: nil)
        let items = summaries.filter { inRange($0.date) }
            .prefix(limit)
            .map { summary in
                MeetingResultItem(
                    id: summary.id.uuidString,
                    title: summary.title,
                    date: ToolDateFormatting.format(summary.date),
                    querySnippet: nil
                )
            }
        return (items, false)
    }
}

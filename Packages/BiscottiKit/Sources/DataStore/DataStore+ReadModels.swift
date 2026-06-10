import Foundation

// MARK: - Read-Model DTOs

/// A lightweight summary of a meeting for list views.
/// Mapped from `Meeting` on the `DataStore` actor -- safe to hold on `@MainActor`.
public struct MeetingSummary: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    /// The meeting's effective date: `startDate` if available, otherwise `createdAt`.
    public let date: Date
    public let hasTranscript: Bool

    public init(id: UUID, title: String, date: Date, hasTranscript: Bool) {
        self.id = id
        self.title = title
        self.date = date
        self.hasTranscript = hasTranscript
    }
}

/// Detailed meeting data for the Meeting Detail screen.
/// Includes the preferred transcript if one exists.
public struct MeetingDetailData: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let date: Date
    /// Duration derived from audio refs if known, nil otherwise.
    public let duration: TimeInterval?
    public let hasAudio: Bool
    public let preferredTranscript: TranscriptData?

    public init(
        id: UUID,
        title: String,
        date: Date,
        duration: TimeInterval?,
        hasAudio: Bool,
        preferredTranscript: TranscriptData?
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.hasAudio = hasAudio
        self.preferredTranscript = preferredTranscript
    }
}

/// A transcript version mapped from `TranscriptRecord`.
public struct TranscriptData: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let speakerCount: Int
    public let segments: [SegmentData]

    public init(id: UUID, createdAt: Date, speakerCount: Int, segments: [SegmentData]) {
        self.id = id
        self.createdAt = createdAt
        self.speakerCount = speakerCount
        self.segments = segments
    }
}

/// A single transcript segment mapped from `TranscriptSegmentRecord`.
public struct SegmentData: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let speakerLabel: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(id: UUID, speakerLabel: String, startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = id
        self.speakerLabel = speakerLabel
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

// MARK: - DataStore Query Methods

public extension DataStore {
    /// Returns summaries of recent meetings, newest first.
    ///
    /// Note: `recentMeetings` sorts by `createdAt`, but the DTO `date` uses
    /// `startDate ?? createdAt`. Once the Calendar project lands, sort by the
    /// effective date so ordering matches the displayed value (see Project 5).
    func meetingSummaries(limit: Int) throws -> [MeetingSummary] {
        let meetings = try recentMeetings(limit: limit)
        return meetings.map { meeting in
            MeetingSummary(
                id: meeting.id,
                title: meeting.title,
                date: meeting.startDate ?? meeting.createdAt,
                hasTranscript: meeting.preferredTranscriptID != nil
            )
        }
    }

    /// Returns detailed data for a single meeting, or nil if not found.
    func meetingDetail(id: UUID) throws -> MeetingDetailData? {
        guard let meeting = try meeting(id: id) else { return nil }

        let transcript: TranscriptData? = if let preferredID = meeting.preferredTranscriptID,
                                             let record = meeting.transcripts.first(where: { $0.id == preferredID })
        {
            mapTranscript(record)
        } else {
            nil
        }

        // Derive duration from the longest audio file's end time info if available.
        // In the MVP, duration is derived from start/end dates or nil.
        let duration: TimeInterval? = if let start = meeting.startDate, let end = meeting.endDate {
            end.timeIntervalSince(start)
        } else {
            nil
        }

        let hasAudio = !meeting.audioFiles.isEmpty && meeting.audioFiles.contains(where: \.isPresent)

        return MeetingDetailData(
            id: meeting.id,
            title: meeting.title,
            date: meeting.startDate ?? meeting.createdAt,
            duration: duration,
            hasAudio: hasAudio,
            preferredTranscript: transcript
        )
    }

    /// Returns the mic and system audio file paths for a meeting, or nil if not available.
    func audioPaths(meetingID: UUID) throws -> (mic: URL, system: URL)? {
        guard let meeting = try meeting(id: meetingID) else { return nil }

        let micRef = meeting.audioFiles.first(where: { $0.role == .mic && $0.isPresent })
        let systemRef = meeting.audioFiles.first(where: { $0.role == .system && $0.isPresent })

        guard let micRef, let systemRef else { return nil }

        return (mic: URL(fileURLWithPath: micRef.path), system: URL(fileURLWithPath: systemRef.path))
    }

    // MARK: - Private Mappers

    private func mapTranscript(_ record: TranscriptRecord) -> TranscriptData {
        let sortedSegments = record.segments.sorted(by: { $0.index < $1.index })
        let segments = sortedSegments.map { seg in
            SegmentData(
                id: seg.id,
                speakerLabel: seg.speakerLabel,
                startTime: seg.startTime,
                endTime: seg.endTime,
                text: seg.text
            )
        }
        return TranscriptData(
            id: record.id,
            createdAt: record.createdAt,
            speakerCount: record.speakerCount,
            segments: segments
        )
    }
}

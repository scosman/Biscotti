import Foundation
import SwiftData

// MARK: - Read-Model DTOs

/// A lightweight summary of a meeting for list views.
/// Mapped from `Meeting` on the `DataStore` actor -- safe to hold on `@MainActor`.
public struct MeetingSummary: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    /// The meeting's effective date: `startDate` if available, otherwise `createdAt`.
    public let date: Date
    public let hasTranscript: Bool
    /// The recording's wall-clock duration in seconds, or `nil` if unknown.
    public let recordingDuration: TimeInterval?
    /// Organizer-first, deduped participants (capped at 5 for display).
    public let participants: [PersonData]
    /// Total distinct participant count (drives the "+N" badge).
    public let participantCount: Int

    public init(
        id: UUID,
        title: String,
        date: Date,
        hasTranscript: Bool,
        recordingDuration: TimeInterval? = nil,
        participants: [PersonData] = [],
        participantCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.hasTranscript = hasTranscript
        self.recordingDuration = recordingDuration
        self.participants = participants
        self.participantCount = participantCount
    }
}

/// Detailed meeting data for the Meeting Detail screen.
/// Includes the preferred transcript if one exists.
public struct MeetingDetailData: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let date: Date
    /// The meeting's end date, nil if not known.
    public let endDate: Date?
    /// Duration derived from audio refs if known, nil otherwise.
    public let duration: TimeInterval?
    /// The recording's wall-clock duration in seconds, captured at record-stop.
    /// `nil` for meetings that were never recorded or pre-date the field.
    public let recordingDuration: TimeInterval?
    public let hasAudio: Bool
    public let preferredTranscript: TranscriptData?
    /// Calendar context from the associated snapshot, if any.
    public let calendar: CalendarContextData?
    /// The meeting's user-editable notes.
    public let notes: String
    /// All transcript versions for this meeting.
    public let versions: [TranscriptVersionData]
    /// AI-generated or user-edited markdown meeting summary.
    public let summary: String
    /// Whether the user has manually edited the summary.
    public let editedSummary: Bool
    /// Whether the user has manually edited the title.
    public let editedTitle: Bool

    public init(
        id: UUID,
        title: String,
        date: Date,
        endDate: Date? = nil,
        duration: TimeInterval?,
        recordingDuration: TimeInterval? = nil,
        hasAudio: Bool,
        preferredTranscript: TranscriptData?,
        calendar: CalendarContextData? = nil,
        notes: String = "",
        versions: [TranscriptVersionData] = [],
        summary: String = "",
        editedSummary: Bool = false,
        editedTitle: Bool = false
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.endDate = endDate
        self.duration = duration
        self.recordingDuration = recordingDuration
        self.hasAudio = hasAudio
        self.preferredTranscript = preferredTranscript
        self.calendar = calendar
        self.notes = notes
        self.versions = versions
        self.summary = summary
        self.editedSummary = editedSummary
        self.editedTitle = editedTitle
    }
}

/// A transcript version mapped from `TranscriptRecord`.
public struct TranscriptData: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let speakerCount: Int
    public let segments: [SegmentData]
    /// Speaker ID -> resolved person data. Dangling IDs (referencing
    /// deleted Person records) are dropped during read-model resolution.
    public let speakerAssignments: [Int: PersonData]

    public init(
        id: UUID,
        createdAt: Date,
        speakerCount: Int,
        segments: [SegmentData],
        speakerAssignments: [Int: PersonData] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.speakerCount = speakerCount
        self.segments = segments
        self.speakerAssignments = speakerAssignments
    }

    /// Returns the display name for a diarization speaker ID, or nil if unassigned.
    public func speakerName(forID speakerID: Int) -> String? {
        speakerAssignments[speakerID]?.name
    }
}

/// A single transcript segment mapped from `TranscriptSegmentRecord`.
public struct SegmentData: Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Diarization cluster id (nil = no match).
    public let speakerID: Int?
    public let speakerLabel: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(
        id: UUID,
        speakerID: Int? = nil,
        speakerLabel: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.id = id
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

/// Sendable DTO for the application settings singleton.
public struct AppSettingsData: Sendable, Equatable {
    public var customVocabulary: [String]
    public var launchAtLogin: Bool
    /// When true, closing the last window or pressing Cmd+Q terminates the app.
    /// When false (the default), those actions just hide the window and the app
    /// stays alive in the menu bar.
    public var exitOnWindowClose: Bool
    /// Whether the global record shortcut (Cmd+Shift+R) is active.
    public var globalRecordShortcutEnabled: Bool
    /// Lead time (in seconds) before a meeting start at which the menu bar
    /// shows the detailed "next meeting" text. `0` means never show.
    /// Default: 3600 (1 hour before).
    public var menuBarLeadTimeSeconds: Int
    /// Whether meeting-detected notifications are presented.
    public var monitorForMeetings: Bool
    /// Whether recording auto-stops when all mic users leave.
    public var stopRecordingAutomatically: Bool
    /// Which calendar events trigger pre-meeting notifications.
    public var calendarNotificationMode: CalendarNotificationMode
    public var onboardingComplete: Bool
    /// `nil` = all calendars enabled (the default).
    public var enabledCalendarIDs: Set<String>?
    /// Whether AI analysis (summary + speaker inference) runs automatically
    /// after transcription completes. Default: on.
    public var aiAnalysisEnabled: Bool

    public init(
        customVocabulary: [String] = [],
        launchAtLogin: Bool = false,
        exitOnWindowClose: Bool = false,
        globalRecordShortcutEnabled: Bool = true,
        menuBarLeadTimeSeconds: Int = 3600,
        monitorForMeetings: Bool = true,
        stopRecordingAutomatically: Bool = true,
        calendarNotificationMode: CalendarNotificationMode = .allMeetings,
        onboardingComplete: Bool = false,
        enabledCalendarIDs: Set<String>? = nil,
        aiAnalysisEnabled: Bool = true
    ) {
        self.customVocabulary = customVocabulary
        self.launchAtLogin = launchAtLogin
        self.exitOnWindowClose = exitOnWindowClose
        self.globalRecordShortcutEnabled = globalRecordShortcutEnabled
        self.menuBarLeadTimeSeconds = menuBarLeadTimeSeconds
        self.monitorForMeetings = monitorForMeetings
        self.stopRecordingAutomatically = stopRecordingAutomatically
        self.calendarNotificationMode = calendarNotificationMode
        self.onboardingComplete = onboardingComplete
        self.enabledCalendarIDs = enabledCalendarIDs
        self.aiAnalysisEnabled = aiAnalysisEnabled
    }
}

/// Calendar context derived from a `CalendarSnapshot` for display in Meeting Detail.
public struct CalendarContextData: Sendable, Equatable {
    public let title: String?
    public let startDate: Date?
    public let endDate: Date?
    public let conferencePlatform: String?
    public let conferenceURL: URL?
    public let calendarTitle: String?
    public let calendarColorHex: String?
    public let location: String?
    public let organizer: PersonData?
    public let attendees: [PersonData]
    /// The EventKit event identifier, used for "Open in Calendar" deep links.
    public let eventIdentifier: String?
    /// The event's description/notes from EventKit.
    public let eventNotes: String?

    public init(
        title: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        conferencePlatform: String? = nil,
        conferenceURL: URL? = nil,
        calendarTitle: String? = nil,
        calendarColorHex: String? = nil,
        location: String? = nil,
        organizer: PersonData? = nil,
        attendees: [PersonData] = [],
        eventIdentifier: String? = nil,
        eventNotes: String? = nil
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.conferencePlatform = conferencePlatform
        self.conferenceURL = conferenceURL
        self.calendarTitle = calendarTitle
        self.calendarColorHex = calendarColorHex
        self.location = location
        self.organizer = organizer
        self.attendees = attendees
        self.eventIdentifier = eventIdentifier
        self.eventNotes = eventNotes
    }
}

/// A person DTO safe to hold on `@MainActor`.
public struct PersonData: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let email: String?
    /// Whether this person is the current user. Not yet populated -- always
    /// `false` until the Calendar module wires account-matching in a later phase.
    public let isCurrentUser: Bool

    public init(id: UUID, name: String, email: String? = nil, isCurrentUser: Bool = false) {
        self.id = id
        self.name = name
        self.email = email
        self.isCurrentUser = isCurrentUser
    }
}

/// Metadata for a single transcript version (for the version picker).
public struct TranscriptVersionData: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let methodId: String
    public let isPreferred: Bool

    public init(id: UUID, createdAt: Date, methodId: String, isPreferred: Bool) {
        self.id = id
        self.createdAt = createdAt
        self.methodId = methodId
        self.isPreferred = isPreferred
    }
}

/// Which field a search term matched in.
public enum SearchField: Sendable, Equatable {
    case title
    case people
    case transcript
    case notes
}

/// Audio file reference result for a meeting.
public struct AudioFileRefsResult: Sendable, Equatable {
    public let mic: URL?
    public let system: URL?
    public let present: Bool

    public init(mic: URL?, system: URL?, present: Bool) {
        self.mic = mic
        self.system = system
        self.present = present
    }
}

/// A weighted search result pointing to a meeting.
public struct SearchHit: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let date: Date
    public let score: Int
    public let matchedFields: [SearchField]

    public init(id: UUID, title: String, date: Date, score: Int, matchedFields: [SearchField]) {
        self.id = id
        self.title = title
        self.date = date
        self.score = score
        self.matchedFields = matchedFields
    }
}

// MARK: - DataStore Query Methods

public extension DataStore {
    /// Returns summaries of meetings, sorted by effective date
    /// (`startDate ?? createdAt`) descending.
    ///
    /// - Parameter limit: Maximum number of summaries to return.
    ///   Pass `nil` (the default) to return all meetings.
    func meetingSummaries(limit: Int? = nil) throws -> [MeetingSummary] {
        // Fetch all meetings and sort by effective date in-memory.
        // SwiftData predicates cannot express coalesce(startDate, createdAt).
        // TODO: consider a denormalized effectiveDate column for DB-level sort
        // once the meeting count grows beyond ~1000.
        let descriptor = FetchDescriptor<Meeting>()
        let all = try context.fetch(descriptor)
        let sorted = all.sorted { lhs, rhs in
            let dateL = lhs.startDate ?? lhs.createdAt
            let dateR = rhs.startDate ?? rhs.createdAt
            return dateL > dateR
        }
        let capped = limit.map { Array(sorted.prefix($0)) } ?? sorted
        return capped.map { meeting in
            // Build organizer-first, deduped participant list (capped at 5)
            let allPeople: [Person] = ([meeting.organizer].compactMap(\.self) + meeting.participants)
            var deduped: [Person] = []
            var seenIDs: Set<UUID> = []
            for person in allPeople where seenIDs.insert(person.id).inserted {
                deduped.append(person)
            }
            let mappedParticipants = deduped.prefix(5).map {
                PersonData(id: $0.id, name: $0.name, email: $0.email)
            }

            return MeetingSummary(
                id: meeting.id,
                title: meeting.title,
                date: meeting.startDate ?? meeting.createdAt,
                hasTranscript: meeting.preferredTranscriptID != nil,
                recordingDuration: meeting.recordingDuration,
                participants: mappedParticipants,
                participantCount: deduped.count
            )
        }
    }

    /// Returns detailed data for a single meeting, or nil if not found.
    func meetingDetail(id: UUID) throws -> MeetingDetailData? {
        guard let meeting = try meeting(id: id) else { return nil }

        let transcript: TranscriptData? = if let preferredID = meeting.preferredTranscriptID,
                                             let record = meeting.transcripts.first(where: { $0.id == preferredID })
        {
            try mapTranscript(record)
        } else {
            nil
        }

        let duration: TimeInterval? = if let start = meeting.startDate, let end = meeting.endDate {
            end.timeIntervalSince(start)
        } else {
            nil
        }

        let hasAudio = !meeting.audioFiles.isEmpty && meeting.audioFiles.contains(where: \.isPresent)

        return try MeetingDetailData(
            id: meeting.id,
            title: meeting.title,
            date: meeting.startDate ?? meeting.createdAt,
            endDate: meeting.endDate,
            duration: duration,
            recordingDuration: meeting.recordingDuration,
            hasAudio: hasAudio,
            preferredTranscript: transcript,
            calendar: calendarContext(meetingID: id),
            notes: meeting.notes,
            versions: transcriptVersions(meetingID: id),
            summary: meeting.summary,
            editedSummary: meeting.editedSummary,
            editedTitle: meeting.editedTitle
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

    /// Returns audio file ref info for a meeting: individual URLs and an overall presence flag.
    func audioFileRefs(meetingID: UUID) throws -> AudioFileRefsResult {
        guard let meeting = try meeting(id: meetingID) else {
            return AudioFileRefsResult(mic: nil, system: nil, present: false)
        }
        let micRef = meeting.audioFiles.first(where: { $0.role == .mic && $0.isPresent })
        let systemRef = meeting.audioFiles.first(where: { $0.role == .system && $0.isPresent })
        let micURL = micRef.map { URL(fileURLWithPath: $0.path) }
        let systemURL = systemRef.map { URL(fileURLWithPath: $0.path) }
        let present = micURL != nil || systemURL != nil
        return AudioFileRefsResult(mic: micURL, system: systemURL, present: present)
    }

    /// Returns the stored file paths for all audio refs belonging to a meeting.
    /// Used by `AppCore.deleteMeeting` to remove on-disk files before deleting
    /// the row. Returns an empty array if the meeting is not found.
    func audioFilePaths(meetingID: UUID) throws -> [String] {
        guard let meeting = try meeting(id: meetingID) else { return [] }
        return meeting.audioFiles.map(\.path)
    }

    // MARK: - Settings

    /// Reads the application settings singleton. Creates it with defaults on first call.
    func settings() throws -> AppSettingsData {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try context.fetch(descriptor).first {
            return AppSettingsData(
                customVocabulary: existing.customVocabulary,
                launchAtLogin: existing.launchAtLogin,
                exitOnWindowClose: existing.exitOnWindowClose,
                globalRecordShortcutEnabled: existing.globalRecordShortcutEnabled,
                menuBarLeadTimeSeconds: existing.menuBarLeadTimeSeconds,
                monitorForMeetings: existing.monitorForMeetings,
                stopRecordingAutomatically: existing.stopRecordingAutomatically,
                calendarNotificationMode: CalendarNotificationMode(raw: existing.calendarNotificationModeRaw),
                onboardingComplete: existing.onboardingComplete,
                enabledCalendarIDs: existing.enabledCalendarIDs,
                aiAnalysisEnabled: existing.aiAnalysisEnabled
            )
        }
        // Create the singleton with defaults
        let fresh = AppSettings()
        context.insert(fresh)
        try save()
        return AppSettingsData()
    }

    /// Reads the settings, applies a mutation, and persists the result.
    func updateSettings(_ mutate: @Sendable (inout AppSettingsData) -> Void) throws {
        let descriptor = FetchDescriptor<AppSettings>()
        let model: AppSettings
        if let existing = try context.fetch(descriptor).first {
            model = existing
        } else {
            let fresh = AppSettings()
            context.insert(fresh)
            model = fresh
        }

        var dto = AppSettingsData(
            customVocabulary: model.customVocabulary,
            launchAtLogin: model.launchAtLogin,
            exitOnWindowClose: model.exitOnWindowClose,
            globalRecordShortcutEnabled: model.globalRecordShortcutEnabled,
            menuBarLeadTimeSeconds: model.menuBarLeadTimeSeconds,
            monitorForMeetings: model.monitorForMeetings,
            stopRecordingAutomatically: model.stopRecordingAutomatically,
            calendarNotificationMode: CalendarNotificationMode(raw: model.calendarNotificationModeRaw),
            onboardingComplete: model.onboardingComplete,
            enabledCalendarIDs: model.enabledCalendarIDs,
            aiAnalysisEnabled: model.aiAnalysisEnabled
        )
        mutate(&dto)

        model.customVocabulary = dto.customVocabulary
        model.launchAtLogin = dto.launchAtLogin
        model.exitOnWindowClose = dto.exitOnWindowClose
        model.globalRecordShortcutEnabled = dto.globalRecordShortcutEnabled
        model.menuBarLeadTimeSeconds = dto.menuBarLeadTimeSeconds
        model.monitorForMeetings = dto.monitorForMeetings
        model.stopRecordingAutomatically = dto.stopRecordingAutomatically
        model.calendarNotificationModeRaw = dto.calendarNotificationMode.rawValue
        model.onboardingComplete = dto.onboardingComplete
        model.enabledCalendarIDs = dto.enabledCalendarIDs
        model.aiAnalysisEnabled = dto.aiAnalysisEnabled
        try save()
    }

    // MARK: - Calendar context

    /// Returns calendar context for a meeting from its snapshot, or nil if no snapshot exists.
    func calendarContext(meetingID: UUID) throws -> CalendarContextData? {
        guard let meeting = try meeting(id: meetingID),
              let snapshot = meeting.calendarSnapshot
        else { return nil }

        let organizerData: PersonData? = meeting.organizer.map {
            PersonData(id: $0.id, name: $0.name, email: $0.email)
        }

        let attendeeData = meeting.participants.map {
            PersonData(id: $0.id, name: $0.name, email: $0.email)
        }

        let notes = snapshot.eventNotes.isEmpty ? nil : snapshot.eventNotes

        return CalendarContextData(
            title: snapshot.title.isEmpty ? nil : snapshot.title,
            startDate: snapshot.startDate,
            endDate: snapshot.endDate,
            conferencePlatform: snapshot.conferencePlatform,
            conferenceURL: snapshot.conferenceURL,
            calendarTitle: snapshot.calendarTitle,
            calendarColorHex: snapshot.calendarColorHex,
            location: snapshot.location,
            organizer: organizerData,
            attendees: attendeeData,
            eventIdentifier: snapshot.eventIdentifier,
            eventNotes: notes
        )
    }

    // MARK: - Transcript versions

    /// Returns metadata for all transcript versions of a meeting, sorted by createdAt descending.
    func transcriptVersions(meetingID: UUID) throws -> [TranscriptVersionData] {
        guard let meeting = try meeting(id: meetingID) else { return [] }
        let preferredID = meeting.preferredTranscriptID
        return meeting.transcripts
            .sorted { $0.createdAt > $1.createdAt }
            .map { record in
                TranscriptVersionData(
                    id: record.id,
                    createdAt: record.createdAt,
                    methodId: record.transcriptionMethodId,
                    isPreferred: record.id == preferredID
                )
            }
    }

    /// Returns the full transcript data for a specific transcript version.
    func transcript(id transcriptID: UUID) throws -> TranscriptData? {
        guard let record = try transcriptRecord(id: transcriptID) else { return nil }
        return try mapTranscript(record)
    }

    // MARK: - Notes

    /// Updates the user-editable notes for a meeting.
    func setNotes(_ text: String, for meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        meeting.notes = text
        try save()
    }

    // MARK: - Title

    /// Updates the user-editable title for a meeting and marks it as
    /// user-edited so calendar association will not overwrite it.
    func setTitle(_ title: String, for meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        meeting.title = title
        meeting.editedTitle = true
        try save()
    }

    /// Applies an event title from calendar association. Only updates the
    /// title when `editedTitle` is `false` -- i.e. the user has NOT manually
    /// renamed the meeting.
    func applyEventTitle(
        _ eventTitle: String, for meetingID: UUID
    ) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        guard !meeting.editedTitle else { return }
        meeting.title = eventTitle
        try save()
    }

    // MARK: - Search (with transcript text)

    /// Weighted search across meeting titles, participant names, and transcript text.
    /// Title matches score 3 per term, people matches score 2, transcript matches score 1.
    /// Results sorted by score descending (ties broken by effective date descending).
    func searchHits(_ query: String, limit: Int) throws -> [SearchHit] {
        let terms = query.lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return [] }

        let descriptor = FetchDescriptor<Meeting>()
        let all = try context.fetch(descriptor)

        var hits: [SearchHit] = all.compactMap { scoreMeeting($0, terms: terms) }

        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.date > rhs.date
        }

        return Array(hits.prefix(limit))
    }

    /// Scores a single meeting against the search terms. Returns nil if no match.
    private func scoreMeeting(_ meeting: Meeting, terms: [String]) -> SearchHit? {
        var score = 0
        var fields: Set<SearchField> = []
        let titleLower = meeting.title.lowercased()
        let notesLower = meeting.notes.lowercased()

        for term in terms {
            if titleLower.localizedStandardContains(term) {
                score += 3
                fields.insert(.title)
            }
            let participantMatch = meeting.participants.contains {
                $0.name.lowercased().localizedStandardContains(term)
            }
            let organizerMatch = meeting.organizer.map {
                $0.name.lowercased().localizedStandardContains(term)
            } ?? false
            // Score people once per term (organizer is often also a participant).
            if participantMatch || organizerMatch {
                score += 2
                fields.insert(.people)
            }
            if let prefID = meeting.preferredTranscriptID,
               let txRecord = meeting.transcripts.first(where: { $0.id == prefID }),
               txRecord.segments.contains(where: { $0.text.lowercased().localizedStandardContains(term) })
            {
                score += 1
                fields.insert(.transcript)
            }
            // Notes scored at the same weight as transcript (1).
            if !notesLower.isEmpty, notesLower.localizedStandardContains(term) {
                score += 1
                fields.insert(.notes)
            }
        }

        guard score > 0 else { return nil }
        return SearchHit(
            id: meeting.id,
            title: meeting.title,
            date: meeting.startDate ?? meeting.createdAt,
            score: score,
            matchedFields: Array(fields).sorted { fieldSortOrder($0) < fieldSortOrder($1) }
        )
    }

    // MARK: - Private Mappers

    private func mapTranscript(_ record: TranscriptRecord) throws -> TranscriptData {
        let sortedSegments = record.segments.sorted(by: { $0.index < $1.index })
        let segments = sortedSegments.map { seg in
            SegmentData(
                id: seg.id,
                speakerID: seg.speakerID,
                speakerLabel: seg.speakerLabel,
                startTime: seg.startTime,
                endTime: seg.endTime,
                text: seg.text
            )
        }

        // Resolve speaker assignments: fetch each referenced Person by ID, drop dangling IDs.
        // Typically only 2-5 speakers, so individual fetches are more efficient than a
        // full Person table scan.
        let rawAssignments = record.speakerAssignments
        var resolvedAssignments: [Int: PersonData] = [:]
        for (speakerID, entry) in rawAssignments {
            if let person = try fetchPerson(id: entry.personID) {
                resolvedAssignments[speakerID] = PersonData(
                    id: person.id, name: person.name, email: person.email
                )
            }
            // Dangling IDs (Person deleted) are silently dropped
        }

        return TranscriptData(
            id: record.id,
            createdAt: record.createdAt,
            speakerCount: record.speakerCount,
            segments: segments,
            speakerAssignments: resolvedAssignments
        )
    }

    private func fieldSortOrder(_ field: SearchField) -> Int {
        switch field {
        case .title: 0
        case .people: 1
        case .transcript: 2
        case .notes: 3
        }
    }
}

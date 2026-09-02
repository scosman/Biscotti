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
    /// Tags applied to this meeting, sorted alphabetically.
    public let tags: [TagData]

    public init(
        id: UUID,
        title: String,
        date: Date,
        hasTranscript: Bool,
        recordingDuration: TimeInterval? = nil,
        participants: [PersonData] = [],
        participantCount: Int = 0,
        tags: [TagData] = []
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.hasTranscript = hasTranscript
        self.recordingDuration = recordingDuration
        self.participants = participants
        self.participantCount = participantCount
        self.tags = tags
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
    /// Tags applied to this meeting, sorted alphabetically.
    public let tags: [TagData]

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
        editedTitle: Bool = false,
        tags: [TagData] = []
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
        self.tags = tags
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
    /// The stable ID of the user's chosen LLM model (e.g. "gemma-4-12b").
    /// Empty string means no explicit choice yet (drives migration/fallback).
    public var selectedModelID: String
    /// User's custom meeting-summary instruction prompt. Empty means "use the
    /// built-in default" (so the shipped default can evolve for non-customizers).
    public var summaryPrompt: String
    /// Master switch for custom vocabulary, as stored. `nil` means the user has
    /// never touched the toggle. Carried through unresolved so a full
    /// read-modify-write of settings (see `updateSettings`) cannot silently
    /// bake in today's default. Read `customVocabularyResolved` instead.
    public var customVocabularyEnabled: Bool?
    /// Whether per-meeting terms are derived from the associated calendar event.
    public var calendarVocabularyEnabled: Bool
    /// Whether the local MCP server runs. Off by default.
    public var mcpServerEnabled: Bool

    /// The shipped default for `customVocabularyEnabled` when the user has made
    /// no choice. Custom vocabulary is in beta, so it starts off. Flipping this
    /// to `true` turns the feature on for everyone who never touched the
    /// toggle, without a data migration and without overriding anyone who
    /// deliberately turned it off.
    public static let customVocabularyDefault = false

    /// Whether custom vocabulary is on, resolving "never chosen" to the
    /// shipped default. This is the only value callers should branch on.
    public var customVocabularyResolved: Bool {
        customVocabularyEnabled ?? Self.customVocabularyDefault
    }

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
        aiAnalysisEnabled: Bool = true,
        selectedModelID: String = "",
        summaryPrompt: String = "",
        customVocabularyEnabled: Bool? = nil,
        calendarVocabularyEnabled: Bool = true,
        mcpServerEnabled: Bool = false
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
        self.selectedModelID = selectedModelID
        self.summaryPrompt = summaryPrompt
        self.customVocabularyEnabled = customVocabularyEnabled
        self.calendarVocabularyEnabled = calendarVocabularyEnabled
        self.mcpServerEnabled = mcpServerEnabled
    }
}

/// Uncapped people data for one meeting, for consumers that need every
/// participant (the MCP tools). `MeetingSummary.participants` is capped at 5
/// for display and cannot serve them.
public struct MeetingPeople: Sendable, Equatable {
    public let organizer: PersonData?
    /// Every participant, uncapped, deduped by id, organizer excluded.
    public let participants: [PersonData]

    public init(organizer: PersonData?, participants: [PersonData]) {
        self.organizer = organizer
        self.participants = participants
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
    /// The vocabulary terms that were active when this transcript was produced.
    public let vocabularyUsed: [String]

    public init(
        id: UUID,
        createdAt: Date,
        methodId: String,
        isPreferred: Bool,
        vocabularyUsed: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.methodId = methodId
        self.isPreferred = isPreferred
        self.vocabularyUsed = vocabularyUsed
    }
}

/// A tag DTO safe to hold on `@MainActor`.
public struct TagData: Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let name: String
    public let colorSlot: Int

    public init(id: UUID, name: String, colorSlot: Int) {
        self.id = id
        self.name = name
        self.colorSlot = colorSlot
    }
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

/// Audio file refs as stored, for consumers that must report a deleted
/// file's path alongside `present: false` (the MCP tools, functional spec
/// §5.2). Unlike ``AudioFileRefsResult``, paths survive file deletion.
public struct StoredAudioFileRefs: Sendable, Equatable {
    public let mic: URL?
    public let system: URL?
    /// Whether any referenced file is currently on disk.
    public let present: Bool

    public init(mic: URL?, system: URL?, present: Bool) {
        self.mic = mic
        self.system = system
        self.present = present
    }
}

/// A ranked search result pointing to a meeting.
public struct SearchHit: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let date: Date
    /// Relevance, higher is better. Used for ordering only; never displayed.
    public let score: Double
    /// A context excerpt around the best-matching field. Equals `title` when
    /// the match is title-only.
    public let snippet: String
    /// The opening of the meeting's own content, used as a second line when
    /// `snippet` only echoes the title. See
    /// `MeetingListViewModel.searchSecondLine(for:)`.
    public let preview: String

    public init(
        id: UUID, title: String, date: Date,
        score: Double, snippet: String, preview: String
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.score = score
        self.snippet = snippet
        self.preview = preview
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

            let mappedTags = mapTags(meeting.tags)

            return MeetingSummary(
                id: meeting.id,
                title: meeting.title,
                date: meeting.startDate ?? meeting.createdAt,
                hasTranscript: meeting.preferredTranscriptID != nil,
                recordingDuration: meeting.recordingDuration,
                participants: mappedParticipants,
                participantCount: deduped.count,
                tags: mappedTags
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

        let mappedTags = mapTags(meeting.tags)

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
            editedTitle: meeting.editedTitle,
            tags: mappedTags
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

    /// Returns the uncapped people data for a meeting, or nil if the meeting
    /// is gone. Participants are deduped by id and exclude the organizer,
    /// who is reported separately.
    func meetingPeople(id: UUID) throws -> MeetingPeople? {
        guard let meeting = try meeting(id: id) else { return nil }

        let organizerData = meeting.organizer.map {
            PersonData(id: $0.id, name: $0.name, email: $0.email)
        }

        let organizerID = meeting.organizer?.id
        var participants: [PersonData] = []
        var seenIDs: Set<UUID> = []
        for person in meeting.participants where person.id != organizerID {
            if seenIDs.insert(person.id).inserted {
                participants.append(
                    PersonData(id: person.id, name: person.name, email: person.email)
                )
            }
        }

        return MeetingPeople(organizer: organizerData, participants: participants)
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

    /// Returns the stored audio refs for a meeting with paths reported
    /// **regardless of on-disk presence**: files deleted from disk keep their
    /// paths, paired with `present: false` — "refs deleted" stays
    /// distinguishable from "never recorded" (functional spec §5.2). UI
    /// callers that need playable files keep ``audioFileRefs(meetingID:)``,
    /// which drops missing files.
    func storedAudioFileRefs(meetingID: UUID) throws -> StoredAudioFileRefs {
        guard let meeting = try meeting(id: meetingID) else {
            return StoredAudioFileRefs(mic: nil, system: nil, present: false)
        }
        let micRef = meeting.audioFiles.first(where: { $0.role == .mic })
        let systemRef = meeting.audioFiles.first(where: { $0.role == .system })
        let present = (micRef?.isPresent ?? false) || (systemRef?.isPresent ?? false)
        return StoredAudioFileRefs(
            mic: micRef.map { URL(fileURLWithPath: $0.path) },
            system: systemRef.map { URL(fileURLWithPath: $0.path) },
            present: present
        )
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
                aiAnalysisEnabled: existing.aiAnalysisEnabled,
                selectedModelID: existing.selectedModelID,
                summaryPrompt: existing.summaryPrompt,
                customVocabularyEnabled: existing.customVocabularyEnabled,
                calendarVocabularyEnabled: existing.calendarVocabularyEnabled,
                mcpServerEnabled: existing.mcpServerEnabled
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
            aiAnalysisEnabled: model.aiAnalysisEnabled,
            selectedModelID: model.selectedModelID,
            summaryPrompt: model.summaryPrompt,
            customVocabularyEnabled: model.customVocabularyEnabled,
            calendarVocabularyEnabled: model.calendarVocabularyEnabled,
            mcpServerEnabled: model.mcpServerEnabled
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
        model.selectedModelID = dto.selectedModelID
        model.summaryPrompt = dto.summaryPrompt
        model.customVocabularyEnabled = dto.customVocabularyEnabled
        model.calendarVocabularyEnabled = dto.calendarVocabularyEnabled
        model.mcpServerEnabled = dto.mcpServerEnabled
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
                    isPreferred: record.id == preferredID,
                    vocabularyUsed: record.vocabularyUsed
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

    // MARK: - FTS5 Search

    /// Ranked search across meeting fields via the FTS5 search index.
    ///
    /// Semantics: prefix per term, AND across terms. `"proj plan"` matches
    /// only meetings containing words starting with "proj" AND words starting
    /// with "plan" (in any combination of fields).
    ///
    /// Ranking is FTS5 `bm25()` with per-column weights (title 3, tags 3,
    /// summary 2, people 2, notes 1, transcript 1). Ordering and truncation
    /// both happen in SQLite, using the total ordering
    /// `(rank, effective date desc, UUID)`, so results are deterministic at
    /// tie boundaries.
    ///
    /// **No SwiftData access.** Title, date and snippet all come from the
    /// side index. That is the point -- it removes the per-hit fault that
    /// dominated the old warm path. The trade-off: an index entry for a
    /// meeting that no longer exists is no longer filtered out here, so it
    /// would surface as a result with a stale title. `syncSearchIndex` runs
    /// first and is responsible for preventing that (eager removal on
    /// delete, the Meeting-delete purge, and the count-based staleness
    /// check).
    func searchHits(_ query: String, limit: Int) throws -> [SearchHit] {
        try syncSearchIndex()

        return try searchIndex.search(query: query, limit: limit).map { raw in
            SearchHit(
                id: raw.meetingUUID,
                title: raw.title,
                date: raw.effectiveDate,
                score: raw.score,
                snippet: raw.snippet,
                preview: raw.preview
            )
        }
    }

    // MARK: - Index Sync

    /// Synchronizes the FTS5 search index with the current SwiftData
    /// state.
    ///
    /// Uses the SwiftData History API for incremental updates when a
    /// history token is available. Falls back to a full reconcile on
    /// first run, schema version change, or when the history token is
    /// expired (including in-memory test stores, which do not support
    /// history tracking).
    func syncSearchIndex() throws {
        // Use in-memory token if present (fast path after first sync).
        var token = lastSyncToken

        // On first search after launch, try the persisted token from
        // the side DB so an app restart avoids a full reconcile.
        if token == nil,
           let data = try? searchIndex.historyToken(),
           let restored = try? JSONDecoder().decode(
               DefaultHistoryToken.self, from: data
           )
        {
            token = restored
        }

        if let token {
            do {
                try incrementalSync(since: token)

                // Detect meetings present in the store but absent from
                // the index (e.g. store restored from a different backup,
                // or any gap not covered by history). Two cheap counts.
                // Note: this does NOT catch partially-indexed meetings --
                // a half-written meeting_map row still counts. Transaction
                // wrapping in indexMeeting addresses that case separately.
                let indexedCount = searchIndex.indexedMeetingCount
                let storeCount = try context.fetchCount(
                    FetchDescriptor<Meeting>()
                )
                if indexedCount != storeCount {
                    try fullReconcile()
                }

                return
            } catch {
                // Token expired, history unavailable, or other failure.
                lastSyncToken = nil
            }
        }

        // No usable token — full reconcile.
        try fullReconcile()
    }

    /// Processes SwiftData history transactions since `token`, updating
    /// only the affected index entries. Throws on failure so the caller
    /// can fall back to `fullReconcile`.
    private func incrementalSync(
        since token: DefaultHistoryToken
    ) throws {
        let descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            predicate: #Predicate { transaction in
                transaction.token > token
            }
        )
        let transactions = try context.fetchHistory(descriptor)

        // No changes since last sync — index is up to date.
        guard !transactions.isEmpty else { return }

        let (meetingsToReindex, hadMeetingDeletes) = changedMeetings(
            in: transactions
        )

        // Reindex affected meetings.
        for uuid in meetingsToReindex {
            if let mtg = try meeting(id: uuid) {
                try indexSingleMeeting(mtg)
            }
        }

        // Purge stale entries when a Meeting was deleted. Only Meeting
        // deletes trigger this scan; non-Meeting deletes (Tag, Person,
        // Segment) are handled via the relationship-level update that
        // SwiftData records on the affected Meeting.
        if hadMeetingDeletes {
            let indexedUUIDs = try searchIndex.allIndexedUUIDs()
            let staleUUIDs = try indexedUUIDs.filter { try !meetingExists(id: $0) }
            for uuid in staleUUIDs {
                try searchIndex.removeMeeting(uuid: uuid)
            }
        }

        saveHistoryToken(transactions.last?.token)
    }

    /// The entity name SwiftData assigns to the `Meeting` model.
    /// Used to narrow delete handling to Meeting deletes only.
    private static let meetingEntityName = String(describing: Meeting.self)

    /// Walks a list of history transactions and returns the set of
    /// meeting UUIDs that need reindexing plus a flag indicating
    /// whether any Meeting deletions occurred.
    ///
    /// Non-Meeting deletes are not flagged here. Tag and Person
    /// deletes are covered: SwiftData records a relationship-level
    /// update on the affected Meeting, so those meetings are picked
    /// up by the insert/update path (verified by tests).
    ///
    /// **Known gap (pre-existing, not introduced by narrowing the
    /// flag):** TranscriptRecord/TranscriptSegmentRecord deletes do
    /// NOT trigger a Meeting update in SwiftData history. The
    /// previous code set `hadDeletes` for any model type, but that
    /// flag only triggered a stale-entry *purge* (remove index rows
    /// for deleted meetings) -- it never re-indexed anything. So
    /// transcript deletes failed to refresh the index before and
    /// after this narrowing. Not a shipping concern -- no production
    /// path deletes a TranscriptRecord individually (re-transcription
    /// is additive via `addTranscript` + `setPreferredTranscript`;
    /// the only transcript deletion is the cascade from Meeting
    /// deletion, which `hadMeetingDeletes` already covers).
    /// Pinned by `transcriptDeletionLeavesStaleText` test.
    private func changedMeetings(
        in transactions: [DefaultHistoryTransaction]
    ) -> (reindex: Set<UUID>, hadMeetingDeletes: Bool) {
        var meetingsToReindex: Set<UUID> = []
        var hadMeetingDeletes = false

        for transaction in transactions {
            for change in transaction.changes {
                switch change {
                case .insert, .update:
                    collectAffectedMeetings(
                        pid: change.changedPersistentIdentifier,
                        into: &meetingsToReindex
                    )
                case .delete:
                    let pid = change.changedPersistentIdentifier
                    if pid.entityName == Self.meetingEntityName {
                        hadMeetingDeletes = true
                    }
                @unknown default:
                    break
                }
            }
        }

        return (meetingsToReindex, hadMeetingDeletes)
    }

    /// Persists a history token both in memory (for fast access) and
    /// to the side DB (for across-restart recovery). Best-effort: a
    /// serialization failure is silently ignored.
    private func saveHistoryToken(_ token: DefaultHistoryToken?) {
        guard let token else { return }
        lastSyncToken = token
        if let data = try? JSONEncoder().encode(token) {
            try? searchIndex.setHistoryToken(data)
        }
    }

    /// Determines which meetings need reindexing for a changed object.
    ///
    /// Tries to resolve the `PersistentIdentifier` as a `Meeting`
    /// first (the common case), then as a `Tag` or `Person` (whose
    /// property changes — e.g. rename — affect the search text of
    /// their associated meetings). Other model types are covered by
    /// the relationship-level update SwiftData records on Meeting.
    private func collectAffectedMeetings(
        pid: PersistentIdentifier,
        into set: inout Set<UUID>
    ) {
        // Meeting insert or update.
        if let mtg = try? context.fetch(
            FetchDescriptor<Meeting>(
                predicate: #Predicate { $0.persistentModelID == pid }
            )
        ).first {
            set.insert(mtg.id)
            return
        }

        // Tag rename — reindex every meeting that carries this tag.
        if let tag = try? context.fetch(
            FetchDescriptor<Tag>(
                predicate: #Predicate { $0.persistentModelID == pid }
            )
        ).first {
            for mtg in tag.meetings {
                set.insert(mtg.id)
            }
            return
        }

        // Person rename — reindex meetings where this person appears.
        if let person = try? context.fetch(
            FetchDescriptor<Person>(
                predicate: #Predicate { $0.persistentModelID == pid }
            )
        ).first {
            for mtg in person.meetings {
                set.insert(mtg.id)
            }
            for mtg in person.organizedMeetings {
                set.insert(mtg.id)
            }
        }
    }

    // Per-meeting atomicity is handled inside indexMeeting and
    // removeMeeting (each uses BEGIN IMMEDIATE / COMMIT). A batch
    // transaction around the full loop would reduce fsync count but
    // hold a write lock for the entire reconcile, blocking any
    // concurrent reader. Not worth it until profiling shows
    // full-reconcile latency is a real bottleneck.

    /// Re-indexes every meeting and purges stale entries. Runs on first
    /// launch, schema version change, or when incremental sync fails.
    private func fullReconcile() throws {
        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        let liveUUIDs = Set(meetings.map(\.id))

        for meeting in meetings {
            try indexSingleMeeting(meeting)
        }

        try searchIndex.removeStaleEntries(liveUUIDs: liveUUIDs)

        // Capture the current history position so future syncs are
        // incremental. Best-effort — silently fails for in-memory
        // stores that do not support history tracking.
        saveHistoryToken(currentHistoryToken())
    }

    // TODO: SwiftData's HistoryDescriptor does not currently support
    // reverse-order or limit-1 queries, so we fetch all transactions
    // to get the latest token. Replace with a bounded query if the
    // API adds sort/limit support, or if profiling shows this is
    // slow on stores with many transactions.

    /// Returns the latest history token, or `nil` when history is
    /// unavailable (in-memory stores, empty history).
    private func currentHistoryToken() -> DefaultHistoryToken? {
        let descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        guard let transactions = try? context.fetchHistory(descriptor)
        else { return nil }
        return transactions.last?.token
    }

    /// Extracts searchable text from a meeting and feeds it to the
    /// search index. Internal so callers can reindex a single meeting
    /// after targeted mutations.
    func indexSingleMeeting(_ meeting: Meeting) throws {
        // Transcript: flatten preferred transcript segments.
        var transcriptText = ""
        if let prefID = meeting.preferredTranscriptID,
           let txRecord = meeting.transcripts.first(where: { $0.id == prefID })
        {
            transcriptText = txRecord.segments
                .sorted { $0.index < $1.index }
                .map(\.text)
                .joined(separator: "\n")
        }

        // People: organizer + participants, deduplicated.
        var seenPersonIDs: Set<UUID> = []
        var peopleNames: [String] = []
        if let org = meeting.organizer, seenPersonIDs.insert(org.id).inserted {
            peopleNames.append(org.name)
        }
        for person in meeting.participants where seenPersonIDs.insert(person.id).inserted {
            peopleNames.append(person.name)
        }

        // Tags: all tag names.
        let tagNames = meeting.tags.map(\.name)

        try searchIndex.indexMeeting(SearchIndex.MeetingContent(
            uuid: meeting.id,
            effectiveDate: meeting.startDate ?? meeting.createdAt,
            title: meeting.title,
            summary: meeting.summary,
            notes: meeting.notes,
            transcript: transcriptText,
            people: peopleNames.joined(separator: " "),
            tags: tagNames.joined(separator: " ")
        ))
    }

    // MARK: - Private Mappers

    /// Maps a collection of `Tag` models to sorted `TagData` DTOs (alphabetical, case-insensitive).
    private func mapTags(_ tags: [Tag]) -> [TagData] {
        tags
            .map { TagData(id: $0.id, name: $0.name, colorSlot: $0.colorSlot) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Maps a transcript record to its read model: segments in index
    /// order, speaker assignments resolved to people (dangling person IDs
    /// dropped). Internal: shared by the detail read models and the CSV
    /// export read path so the two never drift.
    internal func mapTranscript(_ record: TranscriptRecord) throws -> TranscriptData {
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
}

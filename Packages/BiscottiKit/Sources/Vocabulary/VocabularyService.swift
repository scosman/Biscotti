import DataStore
import Foundation
import os

/// Assembles the effective custom vocabulary for a transcription job.
///
/// Not `@MainActor`: assembly reads a bundled word list from disk and scans it,
/// which must not run on the main actor. Callers `await` from wherever they are.
public final class VocabularyService: Sendable {
    private let store: DataStore
    private let logger = Logger(subsystem: "net.scosman.biscotti", category: "Vocabulary")

    public init(store: DataStore) {
        self.store = store
    }

    /// The effective vocabulary for one transcription job, already ordered,
    /// de-duplicated, and capped. Empty when the feature is off.
    ///
    /// Never throws: a missing word list, an unreadable store, or a missing
    /// snapshot degrades the result, it does not fail the caller.
    public func effectiveVocabulary(meetingID: UUID) async -> [String] {
        guard let settings = try? await store.settings() else {
            logger.error("Failed to read settings for vocabulary assembly")
            return []
        }

        guard settings.customVocabularyResolved else { return [] }

        let calendarContext: CalendarContextData? = if settings.calendarVocabularyEnabled {
            try? await store.calendarContext(meetingID: meetingID)
        } else {
            nil
        }

        let inputs = buildInputs(settings: settings, calendar: calendarContext)
        let filter = CommonWordList.uncommonFilter(logger: logger)
        return VocabularyAssembler.assemble(inputs, uncommon: filter)
    }

    /// Builds `VocabularyInputs` from the settings DTO and optional calendar context.
    private func buildInputs(
        settings: AppSettingsData,
        calendar: CalendarContextData?
    ) -> VocabularyInputs {
        var inputs = VocabularyInputs(
            userTerms: settings.customVocabulary,
            calendarEnabled: settings.calendarVocabularyEnabled && calendar != nil
        )

        guard let calendar else { return inputs }

        inputs.eventTitle = calendar.title
        inputs.eventNotes = calendar.eventNotes

        // Build attendee names: organizer first, then participants.
        var names: [String] = []
        if let organizer = calendar.organizer {
            names.append(organizer.name)
        }
        names.append(contentsOf: calendar.attendees.map(\.name))
        inputs.attendeeNames = names

        // Build attendee emails.
        var emails: [String] = []
        if let organizerEmail = calendar.organizer?.email {
            emails.append(organizerEmail)
        }
        emails.append(contentsOf: calendar.attendees.compactMap(\.email))
        inputs.attendeeEmails = emails

        // Raw invitee count: organizer (if present) + participants, before dedup.
        inputs.rawInviteeCount = (calendar.organizer != nil ? 1 : 0) + calendar.attendees.count

        return inputs
    }
}

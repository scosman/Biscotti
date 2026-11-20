import Foundation
import SwiftData

// MARK: - Summary

public extension DataStore {
    /// Stores an AI-generated summary. When `markEdited` is `false` (the
    /// default), the summary is treated as standard AI output; when `true`,
    /// it is treated as user-owned (a per-meeting custom-prompt regeneration)
    /// so auto-runs won't overwrite it.
    func applyGeneratedSummary(
        _ markdown: String, for meetingID: UUID, markEdited: Bool = false
    ) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        meeting.summary = markdown
        meeting.editedSummary = markEdited
        try save()
    }

    /// Stores a user-edited summary, marking it as human-edited
    /// (`editedSummary = true`). The auto-run will not overwrite it.
    func setSummary(_ markdown: String, for meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        meeting.summary = markdown
        meeting.editedSummary = true
        try save()
    }
}

// MARK: - AI-Generated Title

public extension DataStore {
    /// Stores an AI-generated title when the current title is replaceable
    /// (the default title, or a placeholder like "Imported from X.m4a").
    /// Leaves `editedTitle == false` so a later calendar association can
    /// still apply a real event title. Clears `titleIsPlaceholder`.
    /// No-op when the title is user-edited or already an AI/event title.
    func applyGeneratedTitle(_ title: String, for meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        guard Meeting.isAIReplaceableTitle(
            title: meeting.title,
            editedTitle: meeting.editedTitle,
            titleIsPlaceholder: meeting.titleIsPlaceholder
        ) else { return }
        meeting.title = title
        meeting.titleIsPlaceholder = false
        try save()
    }
}

// MARK: - Speaker Assignments

public extension DataStore {
    /// Merges AI-inferred speaker assignments into the transcript's map,
    /// **preserving any entry whose `userSet` flag is `true`** (a human
    /// manually assigned that speaker). New AI entries are written with
    /// `userSet = false`.
    func setSpeakerAssignments(
        _ assignments: [Int: UUID],
        provenance: [Int: SpeakerNameProvenance] = [:],
        for transcriptID: UUID
    ) throws {
        guard let record = try transcriptRecord(id: transcriptID) else {
            throw DataStoreError.notFound(transcriptID)
        }
        var current = record.speakerAssignments
        // AI picks only fill speakers that have no name or
        // only an AI guess. A name from a person, the mic, the screen or a
        // voice match stays, and its person can't be guessed onto another
        // speaker.
        let backed = current.filter { $0.value.effectiveProvenance.source != .guess }
        let backedPeople = Set(backed.values.map(\.personID))
        for (speakerID, personID) in assignments {
            if backed[speakerID] != nil { continue }
            if backedPeople.contains(personID) { continue }
            let source = provenance[speakerID] ?? SpeakerNameProvenance(
                source: .guess, confidence: .low, detail: "Picked by AI from the transcript and invite"
            )
            current[speakerID] = SpeakerAssignmentEntry(
                personID: personID, userSet: false, provenance: source
            )
            // A name backed by evidence (a voice match) replaces any earlier
            // AI guess that put the same person on another speaker.
            if source.source != .guess {
                for (other, entry) in current where other != speakerID && entry.personID == personID
                    && entry.effectiveProvenance.source == .guess && !entry.userSet
                {
                    current.removeValue(forKey: other)
                }
            }
        }
        record.speakerAssignments = current
        try save()
    }

    /// Sets or clears a single speaker assignment. Pass `nil` for `personID`
    /// to clear the assignment back to "Speaker N". Manual assignments are
    /// written with `userSet = true`.
    /// Sets a hand-set name carried over from an earlier version, unless
    /// the speaker already has a hand-set name or the person is already
    /// placed by hand on another speaker. Checked and written in one step.
    @discardableResult
    func carrySpeakerAssignment(speakerID: Int, personID: UUID, for transcriptID: UUID) throws -> Bool {
        guard let record = try transcriptRecord(id: transcriptID) else {
            throw DataStoreError.notFound(transcriptID)
        }
        let current = record.speakerAssignments
        if current[speakerID]?.userSet == true { return false }
        if current.contains(where: { $0.key != speakerID && $0.value.userSet && $0.value.personID == personID }) {
            return false
        }
        try setSpeakerAssignment(speakerID: speakerID, personID: personID, for: transcriptID)
        return true
    }

    func setSpeakerAssignment(
        speakerID: Int, personID: UUID?, for transcriptID: UUID
    ) throws {
        guard let record = try transcriptRecord(id: transcriptID) else {
            throw DataStoreError.notFound(transcriptID)
        }
        var assignments = record.speakerAssignments
        if let personID {
            // Correcting an automatic name teaches an alias, so the display
            // name it came from finds this person next time ("Lopez, Maria
            // (AGENCY)" -> Maria Reyes). Only when the two names share a first
            // or last name: otherwise the screen simply picked the wrong
            // person, and that must not become a permanent rule. And only
            // when the old name is a one-off screen label (no email, seen in
            // at most this meeting): two real people who share a first name
            // must never be merged.
            if let previous = assignments[speakerID], previous.personID != personID,
               previous.effectiveProvenance.source == .screen,
               let old = try fetchPerson(id: previous.personID),
               let new = try fetchPerson(id: personID),
               PersonAlias.sharesAName(old.name, new.name),
               old.email == nil, old.meetings.count <= 1, old.organizedMeetings.isEmpty
            {
                addAlias(old.name, for: personID)
            }
            assignments[speakerID] = SpeakerAssignmentEntry(
                personID: personID, userSet: true, provenance: .confirmed
            )
        } else {
            assignments.removeValue(forKey: speakerID)
        }
        record.speakerAssignments = assignments
        try save()
    }

    /// Saves a name found automatically, with its evidence.
    /// Only trusted names (mic, strong screen match) are protected the way
    /// a hand-set name is.
    func setSpeakerAssignment(
        speakerID: Int, personID: UUID, provenance: SpeakerNameProvenance, for transcriptID: UUID
    ) throws {
        guard let record = try transcriptRecord(id: transcriptID) else {
            throw DataStoreError.notFound(transcriptID)
        }
        var assignments = record.speakerAssignments
        assignments[speakerID] = SpeakerAssignmentEntry(
            personID: personID, userSet: provenance.isTrusted, provenance: provenance
        )
        record.speakerAssignments = assignments
        try save()
    }
}

// MARK: - Human-Set Speaker Mappings

public extension DataStore {
    /// Returns only the human-set (`userSet == true`) speaker assignments,
    /// resolved to `PersonData`. Dangling person IDs (referencing deleted
    /// Person records) are dropped, matching the `mapTranscript` policy.
    func humanSetSpeakerMappings(
        for transcriptID: UUID
    ) throws -> [Int: PersonData] {
        guard let record = try transcriptRecord(id: transcriptID) else {
            throw DataStoreError.notFound(transcriptID)
        }
        let raw = record.speakerAssignments
        var result: [Int: PersonData] = [:]
        for (speakerID, entry) in raw where entry.userSet {
            if let person = try fetchPerson(id: entry.personID) {
                result[speakerID] = PersonData(
                    id: person.id, name: person.name, email: person.email
                )
            }
        }
        return result
    }
}

// MARK: - Names a person set

public extension DataStore {
    /// Like `humanSetSpeakerMappings` but only names a person picked (or
    /// that carried over from their pick). Automatic names are left out so
    /// re-transcribing doesn't promote them to confirmed.
    func confirmedSpeakerMappings(for transcriptID: UUID) throws -> [Int: PersonData] {
        guard let record = try transcriptRecord(id: transcriptID) else {
            throw DataStoreError.notFound(transcriptID)
        }
        var result: [Int: PersonData] = [:]
        for (speakerID, entry) in record.speakerAssignments
            where entry.effectiveProvenance.source == .confirmed
        {
            if let person = try fetchPerson(id: entry.personID) {
                result[speakerID] = PersonData(id: person.id, name: person.name, email: person.email)
            }
        }
        return result
    }
}

// MARK: - People

public extension DataStore {
    /// Returns all known people as DTOs, sorted by name.
    func allPersonData() throws -> [PersonData] {
        let descriptor = FetchDescriptor<Person>(
            sortBy: [SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).map {
            PersonData(id: $0.id, name: $0.name, email: $0.email)
        }
    }
}

// MARK: - Confirmed people

public extension DataStore {
    /// People a human (or speaker naming) has placed on a speaker in any
    /// transcript. AI guesses don't count.
    func confirmedPersonIDs() throws -> Set<UUID> {
        let records = try context.fetch(FetchDescriptor<TranscriptRecord>())
        var result: Set<UUID> = []
        for record in records {
            for entry in record.speakerAssignments.values where entry.userSet {
                result.insert(entry.personID)
            }
        }
        return result
    }

    /// Names of `confirmedPersonIDs()`.
    func confirmedPersonNames() throws -> Set<String> {
        let ids = try confirmedPersonIDs()
        return try Set(ids.compactMap { try fetchPerson(id: $0)?.name })
    }
}

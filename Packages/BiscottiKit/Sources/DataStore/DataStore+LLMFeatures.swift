import Foundation
import SwiftData

// MARK: - Summary

public extension DataStore {
    /// Stores an AI-generated summary, marking it as auto-generated
    /// (`editedSummary = false`). Used after LLM summarization completes.
    func applyGeneratedSummary(_ markdown: String, for meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        meeting.summary = markdown
        meeting.editedSummary = false
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

// MARK: - Speaker Assignments

public extension DataStore {
    /// Merges AI-inferred speaker assignments into the transcript's map,
    /// **preserving any entry whose `userSet` flag is `true`** (a human
    /// manually assigned that speaker). New AI entries are written with
    /// `userSet = false`.
    func setSpeakerAssignments(
        _ assignments: [Int: UUID], for transcriptID: UUID
    ) throws {
        guard let record = try transcriptRecord(id: transcriptID) else {
            throw DataStoreError.notFound(transcriptID)
        }
        var current = record.speakerAssignments
        for (speakerID, personID) in assignments {
            // Skip speakers the user has manually assigned
            if current[speakerID]?.userSet == true { continue }
            current[speakerID] = SpeakerAssignmentEntry(
                personID: personID, userSet: false
            )
        }
        record.speakerAssignments = current
        try save()
    }

    /// Sets or clears a single speaker assignment. Pass `nil` for `personID`
    /// to clear the assignment back to "Speaker N". Manual assignments are
    /// written with `userSet = true`.
    func setSpeakerAssignment(
        speakerID: Int, personID: UUID?, for transcriptID: UUID
    ) throws {
        guard let record = try transcriptRecord(id: transcriptID) else {
            throw DataStoreError.notFound(transcriptID)
        }
        var assignments = record.speakerAssignments
        if let personID {
            assignments[speakerID] = SpeakerAssignmentEntry(
                personID: personID, userSet: true
            )
        } else {
            assignments.removeValue(forKey: speakerID)
        }
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

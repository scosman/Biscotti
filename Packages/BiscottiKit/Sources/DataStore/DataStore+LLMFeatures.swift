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
    /// Replaces the entire speaker-to-person mapping for a transcript.
    func setSpeakerAssignments(
        _ assignments: [Int: UUID], for transcriptID: UUID
    ) throws {
        guard let record = try transcriptRecord(id: transcriptID) else {
            throw DataStoreError.notFound(transcriptID)
        }
        record.speakerAssignments = assignments
        try save()
    }

    /// Sets or clears a single speaker assignment. Pass `nil` for `personID`
    /// to clear the assignment back to "Speaker N".
    func setSpeakerAssignment(
        speakerID: Int, personID: UUID?, for transcriptID: UUID
    ) throws {
        guard let record = try transcriptRecord(id: transcriptID) else {
            throw DataStoreError.notFound(transcriptID)
        }
        var assignments = record.speakerAssignments
        if let personID {
            assignments[speakerID] = personID
        } else {
            assignments.removeValue(forKey: speakerID)
        }
        record.speakerAssignments = assignments
        try save()
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

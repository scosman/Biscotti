import Foundation
import SwiftData

// MARK: - Tag API

public extension DataStore {
    /// Returns all tags in the catalogue, sorted alphabetically (case-insensitive).
    func allTags() throws -> [TagData] {
        let descriptor = FetchDescriptor<Tag>()
        let tags = try context.fetch(descriptor)
        return tags
            .map { TagData(id: $0.id, name: $0.name, colorSlot: $0.colorSlot) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Creates a new tag with the given name. Returns `nil` if the trimmed name is empty.
    /// If a tag with the same name (case-insensitive) already exists, returns it instead
    /// of creating a duplicate. The colour slot is assigned round-robin by catalogue size.
    func createTag(name: String) throws -> TagData? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Case-insensitive dedup: full-table scan, acceptable at V1 scale
        let descriptor = FetchDescriptor<Tag>()
        let existing = try context.fetch(descriptor)
        if let match = existing.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return TagData(id: match.id, name: match.name, colorSlot: match.colorSlot)
        }

        let slot = existing.count % 8
        let tag = Tag(name: trimmed, colorSlot: slot)
        context.insert(tag)
        try save()
        return TagData(id: tag.id, name: tag.name, colorSlot: tag.colorSlot)
    }

    /// Applies a tag to a meeting. No-op if already applied or if either ID is not found.
    func applyTag(tagID: UUID, to meetingID: UUID) throws {
        guard let tag = try fetchTag(id: tagID),
              let meeting = try meeting(id: meetingID)
        else { return }
        // Idempotent: only append if not already linked
        if !meeting.tags.contains(where: { $0.id == tag.id }) {
            meeting.tags.append(tag)
            try save()
        }
    }

    /// Removes a tag's application from a meeting. The tag remains in the catalogue.
    /// No-op if the tag is not applied or if either ID is not found.
    func removeTag(tagID: UUID, from meetingID: UUID) throws {
        guard let meeting = try meeting(id: meetingID) else { return }
        meeting.tags.removeAll(where: { $0.id == tagID })
        try save()
    }

    /// Atomically finds-or-creates a tag and applies it to a meeting.
    /// Returns the tag DTO, or `nil` if the name is empty after trimming.
    func createTagAndApply(name: String, to meetingID: UUID) throws -> TagData? {
        guard let tagData = try createTag(name: name) else { return nil }
        try applyTag(tagID: tagData.id, to: meetingID)
        return tagData
    }

    // MARK: - Internal fetch helper

    /// Fetches a `Tag` by ID, or nil if not found.
    func fetchTag(id tagID: UUID) throws -> Tag? {
        let descriptor = FetchDescriptor<Tag>(
            predicate: #Predicate { $0.id == tagID }
        )
        return try context.fetch(descriptor).first
    }
}

// MARK: - Test Helpers

public extension DataStore {
    /// Fetches all `Tag` rows in the store (for verification in tests).
    func fetchAllTags() throws -> [Tag] {
        try context.fetch(FetchDescriptor<Tag>())
    }
}

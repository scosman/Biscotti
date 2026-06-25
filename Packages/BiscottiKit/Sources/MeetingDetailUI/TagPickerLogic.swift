import DataStore
import Foundation

/// A single row in the tag picker, combining tag data with application state.
public struct TagPickerRow: Sendable, Equatable, Identifiable {
    public let tag: TagData
    public let isApplied: Bool

    public var id: UUID {
        tag.id
    }

    public init(tag: TagData, isApplied: Bool) {
        self.tag = tag
        self.isApplied = isApplied
    }
}

/// The result of the tag picker filtering computation.
public struct TagPickerResult: Sendable, Equatable {
    /// Filtered catalogue rows, alphabetical, each flagged `isApplied`.
    public let rows: [TagPickerRow]

    /// When non-nil, the trimmed query string to offer as a "Create" action.
    /// Present when the trimmed query is non-empty and no catalogue tag
    /// equals it case-insensitively.
    public let createOption: String?
}

/// Pure filtering + create-visibility computation for the tag picker.
///
/// Given the full tag catalogue, the set of applied tag IDs, and a
/// search query, returns the filtered rows and optional create-option
/// string. Unit-testable with no UI dependency.
///
/// - Parameters:
///   - catalogue: All tags in the catalogue (any order).
///   - applied: IDs of tags currently applied to this meeting.
///   - query: The user's current search text (may be empty).
/// - Returns: A ``TagPickerResult`` with filtered rows and create metadata.
public func computeTagPickerResult(
    catalogue: [TagData],
    applied: Set<UUID>,
    query: String
) -> TagPickerResult {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    // Filter catalogue by case-insensitive contains
    let filtered: [TagData]
    if trimmed.isEmpty {
        filtered = catalogue
    } else {
        let lowered = trimmed.lowercased()
        filtered = catalogue.filter {
            $0.name.lowercased().contains(lowered)
        }
    }

    // Sort alphabetically (case-insensitive)
    let sorted = filtered.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }

    // Build rows with isApplied flags
    let rows = sorted.map { tag in
        TagPickerRow(tag: tag, isApplied: applied.contains(tag.id))
    }

    // Create option: shown when trimmed query is non-empty and no
    // catalogue tag (unfiltered) equals it case-insensitively
    let createOption: String?
    if !trimmed.isEmpty {
        let exactMatch = catalogue.contains {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        createOption = exactMatch ? nil : trimmed
    } else {
        createOption = nil
    }

    return TagPickerResult(rows: rows, createOption: createOption)
}

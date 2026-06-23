import DataStore
import Foundation

/// The result of the person-picker windowing computation.
///
/// Separates the display-ready slices of invitees and all-people,
/// the count of hidden rows (those that matched but were capped),
/// and the optional "Add" action label text.
public struct PersonPickerResult: Sendable, Equatable {
    /// Capped slice of matching invitees to display.
    public let invitees: [PersonData]
    /// Capped slice of matching non-invitee people to display.
    public let allPeople: [PersonData]
    /// How many additional matching people exist beyond the displayed rows.
    public let hiddenCount: Int
    /// When non-nil, the trimmed query string to offer as an "Add" action.
    /// Present when the query is non-empty and no displayed/matching person
    /// has a name that equals the query case-insensitively.
    public let addOption: String?
}

/// Pure windowing + filtering computation for the person picker.
///
/// Given the full invitee and all-people lists, a search query, and a
/// display limit, returns the capped sections, hidden count, and optional
/// add-option string. Unit-testable with no UI dependency.
///
/// - Parameters:
///   - invitees: Meeting invitees (organizer + attendees).
///   - allPeople: All other known people, already deduped against invitees.
///   - query: The user's current search text (may be empty).
///   - limit: Maximum number of person rows to display (default 15).
/// - Returns: A ``PersonPickerResult`` with the capped sections and metadata.
public func computePersonPickerResult(
    invitees: [PersonData],
    allPeople: [PersonData],
    query: String,
    limit: Int = 15
) -> PersonPickerResult {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    // Filter both lists by case-insensitive substring on name or email
    let matchingInvitees: [PersonData]
    let matchingAllPeople: [PersonData]
    if trimmed.isEmpty {
        matchingInvitees = invitees
        matchingAllPeople = allPeople
    } else {
        let lowered = trimmed.lowercased()
        matchingInvitees = invitees.filter { matches($0, lowered) }
        matchingAllPeople = allPeople.filter { matches($0, lowered) }
    }

    let totalMatching = matchingInvitees.count + matchingAllPeople.count

    // Fill to limit: invitees first, then all people with remaining capacity
    let cappedInvitees = Array(matchingInvitees.prefix(limit))
    let remaining = max(0, limit - cappedInvitees.count)
    let cappedAllPeople = Array(matchingAllPeople.prefix(remaining))

    let shown = cappedInvitees.count + cappedAllPeople.count
    let hiddenCount = totalMatching - shown

    // Add option: shown when trimmed query is non-empty and no matching
    // person has a name that equals the query case-insensitively
    let addOption: String?
    if !trimmed.isEmpty {
        let allMatching = matchingInvitees + matchingAllPeople
        let exactMatch = allMatching.contains {
            $0.name.lowercased() == trimmed.lowercased()
        }
        addOption = exactMatch ? nil : trimmed
    } else {
        addOption = nil
    }

    return PersonPickerResult(
        invitees: cappedInvitees,
        allPeople: cappedAllPeople,
        hiddenCount: hiddenCount,
        addOption: addOption
    )
}

// MARK: - Private helpers

private func matches(_ person: PersonData, _ lowered: String) -> Bool {
    if person.name.lowercased().contains(lowered) {
        return true
    }
    if let email = person.email,
       email.lowercased().contains(lowered)
    {
        return true
    }
    return false
}

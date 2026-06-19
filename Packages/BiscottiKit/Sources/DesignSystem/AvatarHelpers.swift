import Foundation

/// A person for avatar display: name + optional email.
/// DesignSystem-level so the avatar algorithm is testable without app data.
public struct AvatarPerson: Hashable, Sendable {
    public let displayName: String
    public let email: String?

    public init(displayName: String, email: String?) {
        self.displayName = displayName
        self.email = email
    }
}

/// Extracts two-letter initials for an avatar.
///
/// - "Sam Altman" -> "SA" (first letter of first + last token)
/// - "Cher" -> "CH" (first two letters of single token)
/// - "" -> "" (caller renders a fallback glyph)
public func avatarInitials(for name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
    if tokens.count >= 2,
       let firstToken = tokens.first,
       let lastToken = tokens.last
    {
        let first = firstToken.prefix(1)
        let last = lastToken.prefix(1)
        return "\(first)\(last)".uppercased()
    }
    // Single token: first two characters
    return String(trimmed.prefix(2)).uppercased()
}

/// Computes how many name avatars to show inside an `AvatarCluster`.
///
/// The cluster may contain a recording badge, name avatars, and a "+N"
/// overflow chip. `maxCount` caps the total visible circles.
///
/// - Parameters:
///   - peopleCount: Number of people with display data (array length).
///   - totalCount: Reported total participants (may exceed `peopleCount`
///     when the calendar knows the count but not every name).
///   - maxCount: Maximum visible circles in the cluster.
///   - hasRecordingBadge: Whether the recording mic badge is present.
/// - Returns: The number of name avatars to display.
public func avatarNameLimit(
    peopleCount: Int,
    totalCount: Int,
    maxCount: Int,
    hasRecordingBadge: Bool
) -> Int {
    let reserved = hasRecordingBadge ? 1 : 0
    let available = maxCount - reserved
    let effective = max(peopleCount, totalCount)
    if effective > available {
        // Need an overflow chip — it takes one slot
        return min(peopleCount, max(0, available - 1))
    }
    return min(peopleCount, available)
}

/// Returns a deterministic palette index for a given key string.
///
/// Uses FNV-1a 32-bit hash (stable across launches, unlike Swift's
/// randomized `Hasher`). The key is lowercased and trimmed before hashing.
///
/// - Parameters:
///   - key: The string to hash (typically email or display name).
///   - paletteCount: Number of colors in the palette (default 16).
/// - Returns: An index in `0 ..< paletteCount`.
public func avatarColorIndex(forKey key: String, paletteCount: Int = 16) -> Int {
    let normalized = key
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard paletteCount > 0 else { return 0 }
    var hash: UInt32 = 2_166_136_261
    for byte in normalized.utf8 {
        hash ^= UInt32(byte)
        hash &*= 16_777_619
    }
    return Int(hash % UInt32(paletteCount))
}

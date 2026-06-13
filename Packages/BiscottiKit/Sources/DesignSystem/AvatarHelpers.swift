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

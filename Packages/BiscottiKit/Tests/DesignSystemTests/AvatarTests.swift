import DesignSystem
import Foundation
import Testing

// MARK: - Initials

@Suite("avatarInitials")
struct AvatarInitialsTests {
    @Test("Two-word name extracts first letters of first and last")
    func twoWordName() {
        #expect(avatarInitials(for: "Sam Altman") == "SA")
    }

    @Test("Three-word name uses first and last tokens")
    func threeWordName() {
        #expect(avatarInitials(for: "Mary Jane Watson") == "MW")
    }

    @Test("Single-word name uses first two characters")
    func singleWordName() {
        #expect(avatarInitials(for: "Cher") == "CH")
    }

    @Test("Single character name returns one character uppercased")
    func singleChar() {
        #expect(avatarInitials(for: "A") == "A")
    }

    @Test("Empty string returns empty")
    func empty() {
        #expect(avatarInitials(for: "") == "")
    }

    @Test("Whitespace-only returns empty")
    func whitespace() {
        #expect(avatarInitials(for: "   ") == "")
    }

    @Test("Email-as-name uses first two characters")
    func emailAsName() {
        // "sam@x.com" is a single token -> first two letters
        #expect(avatarInitials(for: "sam@x.com") == "SA")
    }

    @Test("Non-ASCII first letters preserved (pre-composed)")
    func nonAsciiPrecomposed() {
        #expect(avatarInitials(for: "\u{00E9}milie Dupont") == "\u{00C9}D")
    }

    @Test("Non-ASCII first letters preserved (decomposed)")
    func nonAsciiDecomposed() {
        // e + combining acute accent
        #expect(avatarInitials(for: "e\u{0301}milie Dupont") == "\u{00C9}D")
    }

    @Test("Non-breaking space treated as whitespace separator")
    func nonBreakingSpace() {
        // U+00A0 non-breaking space between first and last name
        #expect(avatarInitials(for: "Alice\u{00A0}Bob") == "AB")
    }

    @Test("Result is always uppercased")
    func uppercased() {
        #expect(avatarInitials(for: "alice bob") == "AB")
    }
}

// MARK: - Color Index

@Suite("avatarColorIndex")
struct AvatarColorIndexTests {
    @Test("Deterministic: same key always returns the same index")
    func deterministic() {
        let idx1 = avatarColorIndex(forKey: "alice@example.com")
        let idx2 = avatarColorIndex(forKey: "alice@example.com")
        #expect(idx1 == idx2)
    }

    @Test("Result is in range 0..<paletteCount")
    func range() {
        for key in ["a", "b", "c", "test@example.com", "", "Zzzzz"] {
            let idx = avatarColorIndex(forKey: key, paletteCount: 16)
            #expect(idx >= 0 && idx < 16, "Index \(idx) out of range for key '\(key)'")
        }
    }

    @Test("Case-insensitive: upper and lower yield the same index")
    func caseInsensitive() {
        #expect(
            avatarColorIndex(forKey: "Alice@Example.com") ==
                avatarColorIndex(forKey: "alice@example.com")
        )
    }

    @Test("Whitespace-insensitive: trimmed result matches")
    func whitespaceInsensitive() {
        #expect(
            avatarColorIndex(forKey: "  alice@example.com  ") ==
                avatarColorIndex(forKey: "alice@example.com")
        )
    }

    @Test("Distinct common emails produce different indices (spot check)")
    func distinctEmails() {
        let emails = [
            "alice@example.com",
            "bob@example.com",
            "charlie@example.com",
            "diana@example.com",
            "eve@example.com"
        ]
        let indices = Set(emails.map { avatarColorIndex(forKey: $0) })
        // At minimum, not all the same (with 5 distinct strings and 16 buckets,
        // a collision or two is possible, but all-same is astronomically unlikely).
        #expect(indices.count >= 2, "Expected at least 2 distinct indices among 5 emails")
    }

    @Test("Custom palette count works")
    func customPaletteCount() {
        let idx = avatarColorIndex(forKey: "test", paletteCount: 4)
        #expect(idx >= 0 && idx < 4)
    }

    @Test("Zero palette count returns 0")
    func zeroPalette() {
        #expect(avatarColorIndex(forKey: "test", paletteCount: 0) == 0)
    }
}

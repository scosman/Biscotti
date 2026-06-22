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

// MARK: - Name Limit (count-cap logic)

@Suite("avatarNameLimit")
struct AvatarNameLimitTests {
    // No recording badge

    @Test("No recording, people fit within maxCount — all shown, no overflow")
    func allFitNoRecording() {
        // 3 people (total 3), maxCount 4 → show 3 names
        #expect(avatarNameLimit(
            peopleCount: 3, totalCount: 3, maxCount: 4, hasRecordingBadge: false
        ) == 3)
    }

    @Test("No recording, people exactly at maxCount — all shown, no overflow")
    func exactFitNoRecording() {
        // 4 people (total 4), maxCount 4 → show 4 names
        #expect(avatarNameLimit(
            peopleCount: 4, totalCount: 4, maxCount: 4, hasRecordingBadge: false
        ) == 4)
    }

    @Test("No recording, people exceed maxCount — leaves room for overflow chip")
    func overflowNoRecording() {
        // 5 people (total 5), maxCount 4 → 3 names + overflow chip = 4 circles
        #expect(avatarNameLimit(
            peopleCount: 5, totalCount: 5, maxCount: 4, hasRecordingBadge: false
        ) == 3)
    }

    // With recording badge

    @Test("Recording badge, people fit — all shown, no overflow")
    func allFitWithRecording() {
        // 2 people (total 2), maxCount 4 → recording + 2 names = 3 circles
        #expect(avatarNameLimit(
            peopleCount: 2, totalCount: 2, maxCount: 4, hasRecordingBadge: true
        ) == 2)
    }

    @Test("Recording badge, people exactly fill remaining slots — all shown")
    func exactFitWithRecording() {
        // 3 people (total 3), maxCount 4 → recording + 3 names = 4 circles
        #expect(avatarNameLimit(
            peopleCount: 3, totalCount: 3, maxCount: 4, hasRecordingBadge: true
        ) == 3)
    }

    @Test("Recording badge, people exceed remaining — leaves room for overflow")
    func overflowWithRecording() {
        // 5 people (total 5), maxCount 4 → recording + 2 names + overflow = 4 circles
        #expect(avatarNameLimit(
            peopleCount: 5, totalCount: 5, maxCount: 4, hasRecordingBadge: true
        ) == 2)
    }

    @Test("Recording badge + overflow: the key scenario (7 people with names)")
    func keyScenarioAllNamed() {
        // 7 people (total 7), maxCount 4, recording → recording + 2 names + "+5" = 4
        #expect(avatarNameLimit(
            peopleCount: 7, totalCount: 7, maxCount: 4, hasRecordingBadge: true
        ) == 2)
    }

    // totalCount > peopleCount (calendar knows count but not all names)

    @Test("totalCount exceeds peopleCount — overflow chip accounts for true total")
    func totalExceedsPeople() {
        // 3 named people but totalCount=7, maxCount 4, recording
        // → recording + 2 names + "+5" = 4 circles (not 5!)
        #expect(avatarNameLimit(
            peopleCount: 3, totalCount: 7, maxCount: 4, hasRecordingBadge: true
        ) == 2)
    }

    @Test("totalCount exceeds peopleCount without recording")
    func totalExceedsPeopleNoRecording() {
        // 3 named people but totalCount=7, maxCount 4, no recording
        // → 3 names + "+4" = 4 circles
        #expect(avatarNameLimit(
            peopleCount: 3, totalCount: 7, maxCount: 4, hasRecordingBadge: false
        ) == 3)
    }

    @Test("totalCount exceeds peopleCount but all names fit in cap")
    func totalExceedsPeopleSmall() {
        // 2 named people but totalCount=5, maxCount 4, no recording
        // → 2 names would leave room, but totalCount triggers overflow
        // → 2 names + "+3" = 3 circles (under cap, names capped at peopleCount)
        #expect(avatarNameLimit(
            peopleCount: 2, totalCount: 5, maxCount: 4, hasRecordingBadge: false
        ) == 2)
    }

    // Edge cases

    @Test("Zero people returns zero")
    func zeroPeople() {
        #expect(avatarNameLimit(
            peopleCount: 0, totalCount: 0, maxCount: 4, hasRecordingBadge: false
        ) == 0)
    }

    @Test("Single person with recording fits without overflow")
    func singleWithRecording() {
        // 1 person (total 1), maxCount 4 → recording + 1 name = 2 circles
        #expect(avatarNameLimit(
            peopleCount: 1, totalCount: 1, maxCount: 4, hasRecordingBadge: true
        ) == 1)
    }

    @Test("Higher maxCount (expanded view) allows more names")
    func expandedMaxCount() {
        // 10 people (total 10), maxCount 8, no recording → 7 names + overflow = 8
        #expect(avatarNameLimit(
            peopleCount: 10, totalCount: 10, maxCount: 8, hasRecordingBadge: false
        ) == 7)
    }

    @Test("Higher maxCount with recording")
    func expandedWithRecording() {
        // 10 people (total 10), maxCount 8, recording → recording + 6 names + overflow = 8
        #expect(avatarNameLimit(
            peopleCount: 10, totalCount: 10, maxCount: 8, hasRecordingBadge: true
        ) == 6)
    }
}

// MARK: - Adjusted Total Count (dedup correction)

@Suite("adjustedAvatarTotalCount")
struct AdjustedAvatarTotalCountTests {
    @Test("No duplicates — totalCount unchanged")
    func noDuplicates() {
        // 5 people, 5 unique, totalCount 5 → 5
        #expect(adjustedAvatarTotalCount(
            peopleCount: 5, uniqueCount: 5, totalCount: 5
        ) == 5)
    }

    @Test("Duplicates within people — totalCount reduced by duplicates removed")
    func duplicatesReduceTotal() {
        // 5 people, 4 unique (1 dup), totalCount 5 → 5 - 1 = 4
        #expect(adjustedAvatarTotalCount(
            peopleCount: 5, uniqueCount: 4, totalCount: 5
        ) == 4)
    }

    @Test("All duplicates — collapses to 1")
    func allDuplicates() {
        // 4 people, 1 unique (3 dups), totalCount 4 → max(1, 4 - 3) = 1
        #expect(adjustedAvatarTotalCount(
            peopleCount: 4, uniqueCount: 1, totalCount: 4
        ) == 1)
    }

    @Test("Zero people — returns zero")
    func zeroPeople() {
        #expect(adjustedAvatarTotalCount(
            peopleCount: 0, uniqueCount: 0, totalCount: 0
        ) == 0)
    }

    @Test("totalCount exceeds peopleCount — overflow preserved minus duplicates")
    func totalExceedsPeopleWithDuplicates() {
        // 5 people, 4 unique (1 dup), totalCount 8
        // → max(4, 8 - 1) = 7 — 3 unseen people remain
        #expect(adjustedAvatarTotalCount(
            peopleCount: 5, uniqueCount: 4, totalCount: 8
        ) == 7)
    }

    @Test("totalCount exceeds peopleCount, no duplicates — unchanged")
    func totalExceedsPeopleNoDuplicates() {
        // 3 people, 3 unique, totalCount 7 → 7
        #expect(adjustedAvatarTotalCount(
            peopleCount: 3, uniqueCount: 3, totalCount: 7
        ) == 7)
    }

    @Test("totalCount equals peopleCount, no duplicates — unchanged")
    func totalEqualsPeopleNoDuplicates() {
        #expect(adjustedAvatarTotalCount(
            peopleCount: 4, uniqueCount: 4, totalCount: 4
        ) == 4)
    }

    @Test("Floor at uniqueCount — subtraction cannot go below unique count")
    func floorAtUniqueCount() {
        // 5 people, 3 unique (2 dups), totalCount 3
        // Naive: 3 - 2 = 1, but floor is max(3, 1) = 3
        #expect(adjustedAvatarTotalCount(
            peopleCount: 5, uniqueCount: 3, totalCount: 3
        ) == 3)
    }

    @Test("Result never negative — extreme case")
    func neverNegative() {
        // 10 people, 1 unique (9 dups), totalCount 2
        // Naive: 2 - 9 = -7, but floor is max(1, -7) = 1
        #expect(adjustedAvatarTotalCount(
            peopleCount: 10, uniqueCount: 1, totalCount: 2
        ) == 1)
    }

    @Test("Duplicates beyond display limit — totalCount still adjusted correctly")
    func duplicatesBeyondDisplayLimit() {
        // 6 people, 5 unique (1 dup), totalCount 10
        // Even though only ~4 might display, the total adjusts: max(5, 10 - 1) = 9
        #expect(adjustedAvatarTotalCount(
            peopleCount: 6, uniqueCount: 5, totalCount: 10
        ) == 9)
    }

    @Test("Single person, no duplicates — returns 1")
    func singlePerson() {
        #expect(adjustedAvatarTotalCount(
            peopleCount: 1, uniqueCount: 1, totalCount: 1
        ) == 1)
    }
}

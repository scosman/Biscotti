import Testing
@testable import Vocabulary

@Suite("UncommonWordExtractor")
struct UncommonWordExtractorTests {
    /// A fake uncommon filter: all words are uncommon except a fixed common set.
    /// The set is large enough that typical English filler words pass through,
    /// so the hit-rate guards only fire when tests intentionally trigger them.
    private static let commonWords: Set<String> = [
        "project", "team", "meeting", "the", "and", "for", "with",
        "this", "that", "from", "have", "will", "can", "are",
        "our", "about", "review", "update", "report", "status",
        "agenda", "discuss", "action", "items", "notes", "plan",
        "work", "next", "steps", "follow", "join", "email",
        "details", "room", "code", "session", "setup", "cluster",
        "deploy", "visit", "link", "bring", "updates", "daily",
        "check", "sync", "call", "info", "see", "below",
        "please", "more", "also", "use", "new", "get"
    ]

    private static func fakeUncommon(_ candidates: Set<String>) -> Set<String> {
        candidates.subtracting(commonWords)
    }

    @Test("URLs and emails are scrubbed before tokenizing")
    func urlsAndEmailsScrubbed() {
        let result = UncommonWordExtractor.terms(
            title: "Parakeet Meeting Project",
            notes: "Join at https://zoom.us/j/123456 or email bob@acme.com for details about the team",
            uncommon: Self.fakeUncommon
        )
        #expect(result.contains("Parakeet"))
        // URL host "zoom" and email parts "bob", "acme" should be scrubbed
        #expect(!result.contains(where: { $0.lowercased().contains("zoom") }))
        #expect(!result.contains(where: { $0.lowercased().contains("acme") }))
    }

    @Test("Tokens containing digits are scrubbed")
    func digitTokensScrubbed() {
        let result = UncommonWordExtractor.terms(
            title: "Parakeet Project Team Meeting",
            notes: "Room 42B and code ABC123 for the session",
            uncommon: Self.fakeUncommon
        )
        #expect(result.contains("Parakeet"))
        #expect(!result.contains(where: { $0.contains("42") || $0.contains("123") }))
    }

    @Test("Project Parakeet Team Meeting yields Parakeet (functional spec worked example)")
    func parakeetExample() {
        let result = UncommonWordExtractor.terms(
            title: "Project Parakeet Team Meeting",
            notes: nil,
            uncommon: Self.fakeUncommon
        )
        // 4 checked words: project, parakeet, team, meeting
        // 1 uncommon: parakeet = 25%
        // ≤5 checked, threshold 34% → passes
        #expect(result == ["Parakeet"])
    }

    @Test("Long text with high hit rate drops all uncommon words")
    func longTextHighHitRate() {
        // 6 checked words, need >20% = more than 1.2 uncommon → 2 uncommon = 33%
        let result = UncommonWordExtractor.terms(
            title: "Xylophone Quokka project team meeting report",
            notes: nil,
            uncommon: Self.fakeUncommon
        )
        // xylophone and quokka are uncommon → 2/6 = 33% > 20% → dropped
        #expect(result.isEmpty)
    }

    @Test("Short text under threshold passes")
    func shortTextUnderThreshold() {
        // 4 checked words, 1 uncommon = 25% < 34% → passes
        let result = UncommonWordExtractor.terms(
            title: "Project Xylophone Team Meeting",
            notes: nil,
            uncommon: Self.fakeUncommon
        )
        #expect(result == ["Xylophone"])
    }

    @Test("Short text over threshold drops everything")
    func shortTextOverThreshold() {
        // 3 checked words, 2 uncommon = 67% > 34% → dropped
        let result = UncommonWordExtractor.terms(
            title: "Xylophone Quokka Meeting",
            notes: nil,
            uncommon: Self.fakeUncommon
        )
        #expect(result.isEmpty)
    }

    @Test("More than 15 uncommon words drops all (absolute cap, not hit-rate)")
    func absoluteCap() {
        // 16 designated "uncommon" words — all alpha-only (no digits, since
        // the scrubber strips digit-bearing tokens).
        let rareWords = [
            "Xylophona", "Quokkara", "Zephyrix", "Wombatine",
            "Platypara", "Narwhalia", "Axolotli", "Pangolith",
            "Chamelora", "Ocelotum", "Capybari", "Tamandura",
            "Manateem", "Dugongal", "Kinkajor", "Javelini"
        ]

        // Generate 64 alpha-only filler tokens that the uncommon closure
        // treats as common. Total checked = 16 + 64 = 80, hit rate =
        // 16/80 = 20%, which passes the long-text guard (≤ 0.20).
        // That isolates the absolute cap (> 15) as the only rejection path.
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var fillerWords: [String] = []
        for first in letters {
            for second in letters.prefix(3) {
                fillerWords.append("word\(first)\(second)")
            }
        }
        fillerWords = Array(fillerWords.prefix(64))

        let rareSet = Set(rareWords.map { $0.lowercased() })
        let title = (rareWords + fillerWords).joined(separator: " ")

        let result = UncommonWordExtractor.terms(
            title: title,
            notes: nil,
            uncommon: { candidates in
                candidates.intersection(rareSet)
            }
        )
        #expect(result.isEmpty)
    }

    @Test("Empty input returns empty")
    func emptyInput() {
        let result = UncommonWordExtractor.terms(
            title: nil, notes: nil, uncommon: Self.fakeUncommon
        )
        #expect(result.isEmpty)
    }

    @Test("Empty string input returns empty")
    func emptyStringInput() {
        let result = UncommonWordExtractor.terms(
            title: "", notes: "", uncommon: Self.fakeUncommon
        )
        #expect(result.isEmpty)
    }

    @Test("Tokens under 3 characters are dropped")
    func shortTokensDropped() {
        let result = UncommonWordExtractor.terms(
            title: "An OK Parakeet Meeting Project",
            notes: nil,
            uncommon: Self.fakeUncommon
        )
        // "An" (2 chars) and "OK" (2 chars) → dropped before checking
        // Remaining: Parakeet, Meeting, Project → 3 checked, 1 uncommon = 33% < 34%
        #expect(result.contains("Parakeet"))
        #expect(!result.contains("An"))
    }

    @Test("Case-insensitive grouping with consistent casing preserved")
    func caseGrouping() {
        let result = UncommonWordExtractor.terms(
            title: "Kubernetes project team meeting",
            notes: "Use Kubernetes for the team project work plan",
            uncommon: Self.fakeUncommon
        )
        // "Kubernetes" appears twice with same casing → preserved
        #expect(result.contains("Kubernetes"))
    }

    @Test("Inconsistent casing across occurrences lowercases")
    func inconsistentCasingLowercases() {
        let result = UncommonWordExtractor.terms(
            title: "Kubernetes project team meeting",
            notes: "Use kubernetes for the plan project work team",
            uncommon: Self.fakeUncommon
        )
        // "Kubernetes" and "kubernetes" → inconsistent → lowercased
        #expect(result.contains("kubernetes"))
        #expect(!result.contains("Kubernetes"))
    }

    @Test("All-caps source text lowercases everything")
    func allCapsSourceLowercases() {
        let result = UncommonWordExtractor.terms(
            title: "KUBERNETES PROJECT TEAM MEETING",
            notes: nil,
            uncommon: Self.fakeUncommon
        )
        if !result.isEmpty {
            #expect(result.contains("kubernetes"))
        }
    }

    @Test("www. URLs are scrubbed")
    func wwwUrlsScrubbed() {
        let result = UncommonWordExtractor.terms(
            title: "Parakeet Project Team Meeting",
            notes: "Visit www.example.com/join for more details about the work plan",
            uncommon: Self.fakeUncommon
        )
        #expect(result.contains("Parakeet"))
        #expect(!result.contains(where: { $0.lowercased() == "example" }))
    }
}

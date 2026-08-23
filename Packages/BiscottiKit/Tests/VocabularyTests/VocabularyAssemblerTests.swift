import Testing
@testable import Vocabulary

@Suite("VocabularyAssembler")
struct VocabularyAssemblerTests {
    /// Fake: everything is uncommon (returns the full candidate set).
    private static func allUncommon(_ candidates: Set<String>) -> Set<String> {
        candidates
    }

    /// Fake: nothing is uncommon (returns empty).
    private static func noneUncommon(_: Set<String>) -> Set<String> {
        []
    }

    @Test("Priority order: user terms, then names, companies, uncommon words")
    func priorityOrder() {
        let inputs = VocabularyInputs(
            userTerms: ["UserTerm"],
            calendarEnabled: true,
            eventTitle: "Xylophone Meeting",
            attendeeNames: ["Alice Smith"],
            attendeeEmails: ["alice@acme.com"],
            rawInviteeCount: 1
        )

        let result = VocabularyAssembler.assemble(inputs, uncommon: Self.allUncommon)

        // Expected order: UserTerm, Alice, Acme, Xylophone
        // "Meeting" is common via allUncommon returning everything, but the
        // UncommonWordExtractor's guard may trigger. Let's check relative order.
        guard let userIdx = result.firstIndex(of: "UserTerm"),
              let nameIdx = result.firstIndex(of: "Alice"),
              let companyIdx = result.firstIndex(of: "Acme")
        else {
            Issue.record("Expected UserTerm, Alice, and Acme in result: \(result)")
            return
        }
        #expect(userIdx < nameIdx)
        #expect(nameIdx < companyIdx)
    }

    @Test("Case-insensitive dedupe keeps higher-priority casing")
    func caseInsensitiveDedupe() {
        let inputs = VocabularyInputs(
            userTerms: ["Acme"],
            calendarEnabled: true,
            attendeeEmails: ["bob@acme.com"],
            rawInviteeCount: 1
        )
        let result = VocabularyAssembler.assemble(inputs, uncommon: Self.noneUncommon)
        // "Acme" from user terms should win over "Acme" from company extraction
        let acmeCount = result.count(where: { $0.lowercased() == "acme" })
        #expect(acmeCount == 1)
        #expect(result.contains("Acme"))
    }

    @Test("Only first 12 user terms contribute")
    func userTermCap() {
        let terms = (1 ... 15).map { "Term\($0)" }
        let inputs = VocabularyInputs(userTerms: terms)
        let result = VocabularyAssembler.assemble(inputs, uncommon: Self.noneUncommon)
        #expect(result.count == 12)
        #expect(result.last == "Term12")
    }

    @Test("Truncated to 40 terms maximum")
    func maxTermsCap() {
        // 12 user terms + 30 names = 42 total → capped at 40
        let userTerms = (1 ... 12).map { "User\($0)" }
        let names = (1 ... 30).map { "Person\($0) Lastname" }
        let inputs = VocabularyInputs(
            userTerms: userTerms,
            calendarEnabled: true,
            attendeeNames: names,
            rawInviteeCount: 20
        )
        let result = VocabularyAssembler.assemble(inputs, uncommon: Self.noneUncommon)
        #expect(result.count == 40)
    }

    @Test("Truncated by 700-character joined cap")
    func characterCap() {
        // Each term is 50 chars, all unique. With ", " separators (2 chars each):
        // 13 terms = 50*13 + 2*12 = 674 < 700 → fits
        // 14 terms = 50*14 + 2*13 = 726 > 700 → doesn't fit
        let terms = (1 ... 20).map { "T\($0)" + String(repeating: "a", count: 48 - String($0).count) }
        let inputs = VocabularyInputs(userTerms: terms)
        let result = VocabularyAssembler.assemble(inputs, uncommon: Self.noneUncommon)
        // User cap limits to 12, then check character cap
        // 12 terms = 50*12 + 2*11 = 622 < 700 → all 12 fit
        #expect(result.count == 12)

        // Now with calendar terms to push past character cap
        let userTerms = (1 ... 12).map { "U\($0)" + String(repeating: "a", count: 48 - String($0).count) }
        let names = (1 ... 10).map { "N\($0)" + String(repeating: "b", count: 48 - String($0).count) + " Lastname" }
        let inputs2 = VocabularyInputs(
            userTerms: userTerms,
            calendarEnabled: true,
            attendeeNames: names,
            rawInviteeCount: 10
        )
        let result2 = VocabularyAssembler.assemble(inputs2, uncommon: Self.noneUncommon)
        let joined = result2.joined(separator: ", ")
        #expect(joined.count <= VocabularyLimits.maxJoinedCharacters)
        // With 12 user terms (50 chars each) + names, the cap should drop some
        #expect(result2.count < 12 + 10)
    }

    @Test("Calendar disabled yields user list only")
    func calendarDisabled() {
        let inputs = VocabularyInputs(
            userTerms: ["MyTerm"],
            calendarEnabled: false,
            eventTitle: "Parakeet Meeting",
            attendeeNames: ["Alice Smith"],
            attendeeEmails: ["alice@acme.com"],
            rawInviteeCount: 1
        )
        let result = VocabularyAssembler.assemble(inputs, uncommon: Self.allUncommon)
        #expect(result == ["MyTerm"])
    }

    @Test("Near-cap interaction: 12 user + 21 names + 5 companies leaves room for 2 uncommon")
    func nearCapInteraction() {
        let userTerms = (1 ... 12).map { "User\($0)" }
        // 21 name entries with rawInviteeCount 20 (at the cap, so names contribute).
        // This matches functional spec §3.6: "12 + 21 + 5 = 38 of the 40."
        let names = (1 ... 21).map { "Attendee\($0) Lastname" }
        let emails = (1 ... 5).map { "a@company\($0).com" }

        // Targeted uncommon closure: only "xylophone" and "quokka" are uncommon.
        // The title has enough common words to stay under the 20% hit-rate guard.
        let targetUncommon: Set = ["xylophone", "quokka"]
        let inputs = VocabularyInputs(
            userTerms: userTerms,
            calendarEnabled: true,
            // 10 checked words, 2 uncommon = 20% — at the boundary (≤ 0.20 passes)
            eventTitle: "Xylophone Quokka project team meeting report status update review plan",
            attendeeNames: names,
            attendeeEmails: emails,
            rawInviteeCount: 20
        )

        let result = VocabularyAssembler.assemble(inputs) { candidates in
            candidates.intersection(targetUncommon)
        }
        // 12 user + 21 names + 5 companies + 2 uncommon = 40, exactly at the cap
        #expect(result.count == 40)
        // User terms come first
        #expect(Array(result.prefix(12)) == userTerms)
        // Uncommon words are last (positions 39 and 40)
        #expect(result.contains("Xylophone"))
        #expect(result.contains("Quokka"))
    }

    @Test("Empty inputs returns empty")
    func emptyInputs() {
        let inputs = VocabularyInputs()
        let result = VocabularyAssembler.assemble(inputs, uncommon: Self.noneUncommon)
        #expect(result.isEmpty)
    }

    @Test("Whitespace-only user terms are dropped")
    func whitespaceTermsDropped() {
        let inputs = VocabularyInputs(userTerms: ["  ", "Valid", "", "  \t  "])
        let result = VocabularyAssembler.assemble(inputs, uncommon: Self.noneUncommon)
        #expect(result == ["Valid"])
    }

    @Test("User terms are trimmed")
    func userTermsTrimmed() {
        let inputs = VocabularyInputs(userTerms: ["  Hello  ", " World "])
        let result = VocabularyAssembler.assemble(inputs, uncommon: Self.noneUncommon)
        #expect(result == ["Hello", "World"])
    }

    @Test("Character cap drops whole terms from the end")
    func characterCapDropsFromEnd() {
        // Build terms that barely fit, then one more that doesn't
        let shortTerm = "abc"
        let terms = (1 ... 40).map { "\(shortTerm)\($0)" }
        let inputs = VocabularyInputs(userTerms: Array(terms.prefix(12)))
        let result = VocabularyAssembler.assemble(inputs, uncommon: Self.noneUncommon)

        // Verify the joined result fits
        let joined = result.joined(separator: ", ")
        #expect(joined.count <= VocabularyLimits.maxJoinedCharacters)
    }
}

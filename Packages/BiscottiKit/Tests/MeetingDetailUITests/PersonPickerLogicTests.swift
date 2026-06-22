import DataStore
import Foundation
import Testing
@testable import MeetingDetailUI

// MARK: - Test helpers

private func makePerson(
    name: String, email: String? = nil
) -> PersonData {
    PersonData(id: UUID(), name: name, email: email)
}

private func makePersons(
    count: Int, prefix: String = "Person", emailDomain: String? = nil
) -> [PersonData] {
    (0 ..< count).map { idx in
        let email = emailDomain.map { "\(prefix.lowercased())\(idx)@\($0)" }
        return PersonData(
            id: UUID(), name: "\(prefix) \(idx)", email: email
        )
    }
}

// MARK: - Windowing tests

@Suite("Person picker logic -- windowing")
struct PersonPickerWindowingTests {
    @Test("15+ invitees caps to 15 invitees, no all-people shown")
    func fifteenOrMoreInvitees() {
        let invitees = makePersons(count: 20, prefix: "Inv")
        let allPeople = makePersons(count: 10, prefix: "All")

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: allPeople, query: ""
        )

        #expect(result.invitees.count == 15)
        #expect(result.allPeople.isEmpty)
        #expect(result.hiddenCount == 15) // 20 + 10 - 15
    }

    @Test("exactly 15 invitees fills completely, no all-people")
    func exactlyFifteenInvitees() {
        let invitees = makePersons(count: 15, prefix: "Inv")
        let allPeople = makePersons(count: 5, prefix: "All")

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: allPeople, query: ""
        )

        #expect(result.invitees.count == 15)
        #expect(result.allPeople.isEmpty)
        #expect(result.hiddenCount == 5)
    }

    @Test("<15 invitees fills remainder from all-people to 15")
    func inviteesPlusAllPeopleFillToLimit() {
        let invitees = makePersons(count: 5, prefix: "Inv")
        let allPeople = makePersons(count: 20, prefix: "All")

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: allPeople, query: ""
        )

        #expect(result.invitees.count == 5)
        #expect(result.allPeople.count == 10)
        #expect(result.hiddenCount == 10) // 25 - 15
    }

    @Test("0 invitees shows first 15 all-people")
    func zeroInviteesFifteenAllPeople() {
        let allPeople = makePersons(count: 20, prefix: "All")

        let result = computePersonPickerResult(
            invitees: [], allPeople: allPeople, query: ""
        )

        #expect(result.invitees.isEmpty)
        #expect(result.allPeople.count == 15)
        #expect(result.hiddenCount == 5)
    }

    @Test("small lists that fit within 15 have zero hidden count")
    func allFitNoHiddenCount() {
        let invitees = makePersons(count: 3, prefix: "Inv")
        let allPeople = makePersons(count: 4, prefix: "All")

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: allPeople, query: ""
        )

        #expect(result.invitees.count == 3)
        #expect(result.allPeople.count == 4)
        #expect(result.hiddenCount == 0)
    }

    @Test("empty lists produce empty result")
    func emptyLists() {
        let result = computePersonPickerResult(
            invitees: [], allPeople: [], query: ""
        )

        #expect(result.invitees.isEmpty)
        #expect(result.allPeople.isEmpty)
        #expect(result.hiddenCount == 0)
        #expect(result.addOption == nil)
    }

    @Test("custom limit is respected")
    func customLimit() {
        let invitees = makePersons(count: 3, prefix: "Inv")
        let allPeople = makePersons(count: 10, prefix: "All")

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: allPeople,
            query: "", limit: 5
        )

        #expect(result.invitees.count == 3)
        #expect(result.allPeople.count == 2)
        #expect(result.hiddenCount == 8) // 13 - 5
    }
}

// MARK: - Filtering tests

@Suite("Person picker logic -- filtering")
struct PersonPickerFilteringTests {
    @Test("filters by name case-insensitively")
    func filterByNameCaseInsensitive() {
        let invitees = [
            makePerson(name: "Daniel Lee", email: "d@test.com"),
            makePerson(name: "Alice Wong", email: "a@test.com")
        ]
        let allPeople = [
            makePerson(name: "danny smith")
        ]

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: allPeople, query: "dan"
        )

        #expect(result.invitees.count == 1)
        #expect(result.invitees[0].name == "Daniel Lee")
        #expect(result.allPeople.count == 1)
        #expect(result.allPeople[0].name == "danny smith")
    }

    @Test("filters by email substring")
    func filterByEmail() {
        let invitees = [
            makePerson(name: "Alice", email: "alice@acme.com"),
            makePerson(name: "Bob", email: "bob@other.com")
        ]

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: [], query: "acme"
        )

        #expect(result.invitees.count == 1)
        #expect(result.invitees[0].name == "Alice")
    }

    @Test("filter applies to both sections independently")
    func filterBothSections() {
        let invitees = [
            makePerson(name: "Jeff Lebowski"),
            makePerson(name: "Alice Wong")
        ]
        let allPeople = [
            makePerson(name: "Jeff Lin"),
            makePerson(name: "Bob Smith")
        ]

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: allPeople, query: "jeff"
        )

        #expect(result.invitees.count == 1)
        #expect(result.invitees[0].name == "Jeff Lebowski")
        #expect(result.allPeople.count == 1)
        #expect(result.allPeople[0].name == "Jeff Lin")
        #expect(result.hiddenCount == 0)
    }

    @Test("filter + windowing: caps at 15 with invitees first")
    func filterWithWindowing() {
        let invitees = makePersons(
            count: 20, prefix: "Match",
            emailDomain: "inv.com"
        )
        let allPeople = makePersons(
            count: 10, prefix: "Match",
            emailDomain: "all.com"
        )

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: allPeople, query: "match"
        )

        #expect(result.invitees.count == 15)
        #expect(result.allPeople.isEmpty)
        #expect(result.hiddenCount == 15) // 30 - 15
    }

    @Test("empty query shows unfiltered results")
    func emptyQueryUnfiltered() {
        let invitees = makePersons(count: 3, prefix: "Inv")
        let allPeople = makePersons(count: 3, prefix: "All")

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: allPeople, query: ""
        )

        #expect(result.invitees.count == 3)
        #expect(result.allPeople.count == 3)
    }

    @Test("whitespace-only query treated as empty")
    func whitespaceQueryEmpty() {
        let invitees = makePersons(count: 3, prefix: "Inv")

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: [], query: "   "
        )

        #expect(result.invitees.count == 3)
        #expect(result.addOption == nil)
    }

    @Test("no matches returns empty sections")
    func noMatches() {
        let invitees = [makePerson(name: "Alice")]
        let allPeople = [makePerson(name: "Bob")]

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: allPeople,
            query: "zzz"
        )

        #expect(result.invitees.isEmpty)
        #expect(result.allPeople.isEmpty)
        #expect(result.hiddenCount == 0)
    }
}

// MARK: - Add option tests

@Suite("Person picker logic -- add option")
struct PersonPickerAddOptionTests {
    @Test("non-empty query with no exact name match shows add option")
    func addOptionPresent() {
        let invitees = [makePerson(name: "Daniel Lee")]

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: [], query: "Dan"
        )

        #expect(result.addOption == "Dan")
    }

    @Test("exact name match suppresses add option (case-insensitive)")
    func addOptionSuppressedExactMatch() {
        let invitees = [makePerson(name: "Daniel Lee")]

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: [], query: "daniel lee"
        )

        #expect(result.addOption == nil)
    }

    @Test("exact match in all-people also suppresses add option")
    func addOptionSuppressedExactMatchAllPeople() {
        let allPeople = [makePerson(name: "Priya")]

        let result = computePersonPickerResult(
            invitees: [], allPeople: allPeople, query: "PRIYA"
        )

        #expect(result.addOption == nil)
    }

    @Test("empty query suppresses add option")
    func addOptionSuppressedEmptyQuery() {
        let result = computePersonPickerResult(
            invitees: [], allPeople: [], query: ""
        )
        #expect(result.addOption == nil)
    }

    @Test("whitespace-only query suppresses add option")
    func addOptionSuppressedWhitespaceQuery() {
        let result = computePersonPickerResult(
            invitees: [], allPeople: [], query: "   \t  "
        )
        #expect(result.addOption == nil)
    }

    @Test("add option uses trimmed query text")
    func addOptionTrimmed() {
        let result = computePersonPickerResult(
            invitees: [], allPeople: [], query: "  New Name  "
        )
        #expect(result.addOption == "New Name")
    }

    @Test("add option shown even when no people match (for creating new)")
    func addOptionWithNoMatches() {
        let invitees = [makePerson(name: "Alice")]

        let result = computePersonPickerResult(
            invitees: invitees, allPeople: [], query: "Bob"
        )

        #expect(result.invitees.isEmpty)
        #expect(result.addOption == "Bob")
    }

    @Test(
        "exact match check considers ALL matching people, not just displayed"
    )
    func exactMatchCheckIncludesHidden() {
        // Create 20 invitees all named "PersonN" and one named "Special"
        var invitees = makePersons(count: 20, prefix: "Person")
        invitees.append(makePerson(name: "Special"))

        // Query "special" -- the person named "Special" matches but may be
        // beyond the 15-row cap. Add option should still be suppressed.
        let result = computePersonPickerResult(
            invitees: invitees, allPeople: [], query: "Special"
        )

        #expect(result.addOption == nil)
    }
}

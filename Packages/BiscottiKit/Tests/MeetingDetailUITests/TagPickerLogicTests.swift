import DataStore
import Foundation
import Testing
@testable import MeetingDetailUI

// MARK: - Test helpers

private func makeTag(
    name: String, colorSlot: Int = 0
) -> TagData {
    TagData(id: UUID(), name: name, colorSlot: colorSlot)
}

// MARK: - Filtering tests

@Suite("Tag picker logic -- filtering")
struct TagPickerFilteringTests {
    @Test("contains filter matches substring case-insensitively")
    func containsFilter() {
        let tags = [
            makeTag(name: "Customer", colorSlot: 0),
            makeTag(name: "Important", colorSlot: 1),
            makeTag(name: "Custom Build", colorSlot: 2)
        ]

        let result = computeTagPickerResult(
            catalogue: tags, applied: [], query: "cus"
        )

        #expect(result.rows.count == 2)
        #expect(result.rows[0].tag.name == "Custom Build")
        #expect(result.rows[1].tag.name == "Customer")
    }

    @Test("case-insensitive filter")
    func caseInsensitiveFilter() {
        let tags = [makeTag(name: "customer")]

        let result = computeTagPickerResult(
            catalogue: tags, applied: [], query: "CUS"
        )

        #expect(result.rows.count == 1)
        #expect(result.rows[0].tag.name == "customer")
    }

    @Test("empty query shows all tags")
    func emptyQueryShowsAll() {
        let tags = [
            makeTag(name: "Alpha"),
            makeTag(name: "Beta"),
            makeTag(name: "Gamma")
        ]

        let result = computeTagPickerResult(
            catalogue: tags, applied: [], query: ""
        )

        #expect(result.rows.count == 3)
    }

    @Test("no matches returns empty rows")
    func noMatches() {
        let tags = [makeTag(name: "Customer")]

        let result = computeTagPickerResult(
            catalogue: tags, applied: [], query: "zzz"
        )

        #expect(result.rows.isEmpty)
    }

    @Test("rows sorted alphabetically case-insensitive")
    func alphabeticalOrdering() {
        let tags = [
            makeTag(name: "Zebra"),
            makeTag(name: "alpha"),
            makeTag(name: "Beta")
        ]

        let result = computeTagPickerResult(
            catalogue: tags, applied: [], query: ""
        )

        #expect(result.rows.count == 3)
        #expect(result.rows[0].tag.name == "alpha")
        #expect(result.rows[1].tag.name == "Beta")
        #expect(result.rows[2].tag.name == "Zebra")
    }
}

// MARK: - isApplied tests

@Suite("Tag picker logic -- isApplied flags")
struct TagPickerIsAppliedTests {
    @Test("applied tags flagged correctly")
    func isAppliedFlags() {
        let tag1 = makeTag(name: "Customer")
        let tag2 = makeTag(name: "Important")
        let tag3 = makeTag(name: "Follow-up")

        let result = computeTagPickerResult(
            catalogue: [tag1, tag2, tag3],
            applied: [tag1.id, tag3.id],
            query: ""
        )

        #expect(result.rows.count == 3)
        let byName = Dictionary(
            uniqueKeysWithValues: result.rows.map { ($0.tag.name, $0.isApplied) }
        )
        #expect(byName["Customer"] == true)
        #expect(byName["Important"] == false)
        #expect(byName["Follow-up"] == true)
    }

    @Test("applied flag persists through filtering")
    func isAppliedWithFilter() {
        let tag1 = makeTag(name: "Customer")
        let tag2 = makeTag(name: "Custom Build")

        let result = computeTagPickerResult(
            catalogue: [tag1, tag2],
            applied: [tag1.id],
            query: "cus"
        )

        #expect(result.rows.count == 2)
        let customer = result.rows.first { $0.tag.name == "Customer" }
        let customBuild = result.rows.first { $0.tag.name == "Custom Build" }
        #expect(customer?.isApplied == true)
        #expect(customBuild?.isApplied == false)
    }
}

// MARK: - Create option tests

@Suite("Tag picker logic -- create option")
struct TagPickerCreateOptionTests {
    @Test("create option shown for new name")
    func createOptionShown() {
        let tags = [makeTag(name: "Customer")]

        let result = computeTagPickerResult(
            catalogue: tags, applied: [], query: "NewTag"
        )

        #expect(result.createOption == "NewTag")
    }

    @Test("create option hidden for exact case-insensitive match")
    func createOptionHiddenExactMatch() {
        let tags = [makeTag(name: "Customer")]

        let result = computeTagPickerResult(
            catalogue: tags, applied: [], query: "Customer"
        )

        #expect(result.createOption == nil)
    }

    @Test("create option hidden for case-insensitive match")
    func createOptionCaseInsensitive() {
        let tags = [makeTag(name: "Customer")]

        let result = computeTagPickerResult(
            catalogue: tags, applied: [], query: "customer"
        )

        #expect(result.createOption == nil)
    }

    @Test("create option nil for empty query")
    func createOptionNilEmpty() {
        let result = computeTagPickerResult(
            catalogue: [], applied: [], query: ""
        )

        #expect(result.createOption == nil)
    }

    @Test("create option nil for whitespace-only query")
    func createOptionNilWhitespace() {
        let result = computeTagPickerResult(
            catalogue: [], applied: [], query: "   \t  "
        )

        #expect(result.createOption == nil)
    }

    @Test("create option uses trimmed query text")
    func createOptionTrimmed() {
        let result = computeTagPickerResult(
            catalogue: [], applied: [], query: "  NewTag  "
        )

        #expect(result.createOption == "NewTag")
    }

    @Test("create option shown with empty catalogue")
    func createOptionEmptyCatalogue() {
        let result = computeTagPickerResult(
            catalogue: [], applied: [], query: "FirstTag"
        )

        #expect(result.rows.isEmpty)
        #expect(result.createOption == "FirstTag")
    }

    @Test("exact match check uses full catalogue, not filtered results")
    func exactMatchCheckFullCatalogue() {
        // "Zebra" is in the catalogue but won't match the filter "Customer"
        // -- the create option should still be hidden when query exactly
        // matches a catalogue entry
        let tags = [
            makeTag(name: "Customer"),
            makeTag(name: "Zebra")
        ]

        let result = computeTagPickerResult(
            catalogue: tags, applied: [], query: "Zebra"
        )

        // "Zebra" matches in the filter and is an exact match in catalogue
        #expect(result.createOption == nil)
    }

    @Test("create option shown when query partially matches but is not exact")
    func partialMatchShowsCreate() {
        let tags = [makeTag(name: "Customer")]

        let result = computeTagPickerResult(
            catalogue: tags, applied: [], query: "Cust"
        )

        #expect(result.createOption == "Cust")
    }
}

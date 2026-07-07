import DataStore
import Foundation
import Testing

@Suite("Tag operations")
struct TagTests {
    private func makeStore() throws -> DataStore {
        try DataStore(storage: .inMemory)
    }

    // MARK: - createTag

    @Test("Round-robin slot assignment cycles 0-7")
    func roundRobinSlotAssignment() async throws {
        let store = try makeStore()
        var tags: [TagData] = []
        for idx in 0 ..< 10 {
            let tag = try await store.createTag(name: "Tag\(idx)")
            try tags.append(#require(tag))
        }
        let expectedSlots = [0, 1, 2, 3, 4, 5, 6, 7, 0, 1]
        #expect(tags.map(\.colorSlot) == expectedSlots)
    }

    @Test("Case-insensitive dedup returns existing tag")
    func caseInsensitiveDedup() async throws {
        let store = try makeStore()
        let first = try #require(try await store.createTag(name: "Customer"))
        let second = try #require(try await store.createTag(name: "customer"))
        #expect(first.id == second.id)
        // Name preserved from the original
        #expect(second.name == "Customer")

        let allTags = try await store.allTags()
        #expect(allTags.count == 1)
    }

    @Test("Trim and empty rejection")
    func trimAndEmptyRejection() async throws {
        let store = try makeStore()
        // Whitespace-only -> nil
        let empty = try await store.createTag(name: "   ")
        #expect(empty == nil)

        // Newlines and tabs only -> nil
        let newlinesOnly = try await store.createTag(name: "\t\n\r\n")
        #expect(newlinesOnly == nil)

        // Leading/trailing whitespace trimmed
        let trimmed = try #require(try await store.createTag(name: " X "))
        #expect(trimmed.name == "X")

        // Leading/trailing newlines and tabs trimmed
        let tabNewline = try #require(try await store.createTag(name: "\tCustomer\n"))
        #expect(tabNewline.name == "Customer")

        // Catalogue count should be 2 ("X" and "Customer")
        let allTags = try await store.allTags()
        #expect(allTags.count == 2)
    }

    @Test("allTags returns tags sorted alphabetically")
    func allTagsSorted() async throws {
        let store = try makeStore()
        _ = try await store.createTag(name: "Zebra")
        _ = try await store.createTag(name: "alpha")
        _ = try await store.createTag(name: "Mango")

        let allTags = try await store.allTags()
        #expect(allTags.map(\.name) == ["alpha", "Mango", "Zebra"])
    }

    // MARK: - applyTag / removeTag

    @Test("Apply is idempotent: applying twice creates one link")
    func applyIdempotency() async throws {
        let store = try makeStore()
        let tag = try #require(try await store.createTag(name: "Important"))
        let meetingID = try await store.createMeeting(title: "Test Meeting")

        try await store.applyTag(tagID: tag.id, to: meetingID)
        try await store.applyTag(tagID: tag.id, to: meetingID)

        let detail = try #require(try await store.meetingDetail(id: meetingID))
        #expect(detail.tags.count == 1)
        #expect(detail.tags.first?.id == tag.id)
    }

    @Test("Remove keeps tag in catalogue")
    func removeKeepsTagInCatalogue() async throws {
        let store = try makeStore()
        let tag = try #require(try await store.createTag(name: "Ephemeral"))
        let meetingID = try await store.createMeeting(title: "Test")

        try await store.applyTag(tagID: tag.id, to: meetingID)
        try await store.removeTag(tagID: tag.id, from: meetingID)

        // Tag removed from meeting
        let detail = try #require(try await store.meetingDetail(id: meetingID))
        #expect(detail.tags.isEmpty)

        // Tag still in catalogue
        let allTags = try await store.allTags()
        #expect(allTags.count == 1)
        #expect(allTags.first?.name == "Ephemeral")
    }

    @Test("Remove tag from one meeting preserves it on another")
    func removeFromOneMeeting() async throws {
        let store = try makeStore()
        let tag = try #require(try await store.createTag(name: "Shared"))
        let meeting1 = try await store.createMeeting(title: "Meeting 1")
        let meeting2 = try await store.createMeeting(title: "Meeting 2")

        try await store.applyTag(tagID: tag.id, to: meeting1)
        try await store.applyTag(tagID: tag.id, to: meeting2)

        try await store.removeTag(tagID: tag.id, from: meeting1)

        let detail1 = try #require(try await store.meetingDetail(id: meeting1))
        #expect(detail1.tags.isEmpty)

        let detail2 = try #require(try await store.meetingDetail(id: meeting2))
        #expect(detail2.tags.count == 1)
        #expect(detail2.tags.first?.name == "Shared")
    }

    // MARK: - createTagAndApply

    @Test("createTagAndApply creates and links atomically")
    func createTagAndApplyAtomic() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Test")

        let tag = try #require(try await store.createTagAndApply(name: "Urgent", to: meetingID))
        #expect(tag.name == "Urgent")

        let detail = try #require(try await store.meetingDetail(id: meetingID))
        #expect(detail.tags.count == 1)
        #expect(detail.tags.first?.id == tag.id)
    }

    @Test("createTagAndApply with existing tag reuses and applies")
    func createTagAndApplyReuses() async throws {
        let store = try makeStore()
        let existing = try #require(try await store.createTag(name: "Customer"))
        let meetingID = try await store.createMeeting(title: "Test")

        let result = try #require(try await store.createTagAndApply(name: "customer", to: meetingID))
        #expect(result.id == existing.id)

        let detail = try #require(try await store.meetingDetail(id: meetingID))
        #expect(detail.tags.count == 1)
    }

    @Test("createTagAndApply with empty name returns nil")
    func createTagAndApplyEmptyName() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Test")

        let result = try await store.createTagAndApply(name: "  ", to: meetingID)
        #expect(result == nil)

        let detail = try #require(try await store.meetingDetail(id: meetingID))
        #expect(detail.tags.isEmpty)
    }

    // MARK: - Meeting deletion

    @Test("Deleting a meeting preserves tags in catalogue")
    func deleteMeetingPreservesTags() async throws {
        let store = try makeStore()
        let tag = try #require(try await store.createTag(name: "Persistent"))
        let meeting1 = try await store.createMeeting(title: "Doomed")
        let meeting2 = try await store.createMeeting(title: "Safe")

        try await store.applyTag(tagID: tag.id, to: meeting1)
        try await store.applyTag(tagID: tag.id, to: meeting2)

        try await store.delete(meetingID: meeting1)

        // Tag still exists in catalogue
        let allTags = try await store.allTags()
        #expect(allTags.count == 1)
        #expect(allTags.first?.name == "Persistent")

        // Tag still on the surviving meeting
        let detail2 = try #require(try await store.meetingDetail(id: meeting2))
        #expect(detail2.tags.count == 1)
    }

    // MARK: - Read models carry tags

    @Test("meetingSummaries carries tags alphabetically sorted")
    func summariesCarryTagsAlphabetically() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(
            title: "Tagged",
            start: Date(timeIntervalSince1970: 1_700_000_000)
        )
        _ = try await store.createTagAndApply(name: "Zebra", to: meetingID)
        _ = try await store.createTagAndApply(name: "Alpha", to: meetingID)
        _ = try await store.createTagAndApply(name: "middle", to: meetingID)

        let summaries = try await store.meetingSummaries()
        let meeting = try #require(summaries.first(where: { $0.id == meetingID }))
        #expect(meeting.tags.count == 3)
        #expect(meeting.tags.map(\.name) == ["Alpha", "middle", "Zebra"])
    }

    @Test("meetingDetail carries tags alphabetically sorted")
    func detailCarriesTagsAlphabetically() async throws {
        let store = try makeStore()
        let meetingID = try await store.createMeeting(title: "Tagged")
        _ = try await store.createTagAndApply(name: "Beta", to: meetingID)
        _ = try await store.createTagAndApply(name: "Alpha", to: meetingID)

        let detail = try #require(try await store.meetingDetail(id: meetingID))
        #expect(detail.tags.count == 2)
        #expect(detail.tags.map(\.name) == ["Alpha", "Beta"])
    }

    @Test("Untagged meetings have empty tags in summaries")
    func untaggedMeetingsEmptyTags() async throws {
        let store = try makeStore()
        _ = try await store.createMeeting(title: "Plain")

        let summaries = try await store.meetingSummaries()
        #expect(summaries.first?.tags.isEmpty == true)
    }
}

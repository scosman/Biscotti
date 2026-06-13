import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import AppCore

// MARK: - Helpers

/// Polls a condition until true, up to 2 seconds.
private func pollUntil(
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0 ..< 40 {
        try await Task.sleep(for: .milliseconds(50))
        if await condition() { return }
    }
}

// MARK: - neighborID table tests

@Suite("AppCore -- neighborID")
struct NeighborIDTests {
    @Test("element after target (next/older)")
    @MainActor
    func elementAfterTarget() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let result = AppCore.neighborID(in: [id1, id2, id3], removing: id2)
        #expect(result == id3)
    }

    @Test("target is last: returns element before (newer)")
    @MainActor
    func targetIsLast() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let result = AppCore.neighborID(in: [id1, id2, id3], removing: id3)
        #expect(result == id2)
    }

    @Test("target is only element: returns nil")
    @MainActor
    func targetIsOnly() {
        let id1 = UUID()
        let result = AppCore.neighborID(in: [id1], removing: id1)
        #expect(result == nil)
    }

    @Test("target not found: returns nil")
    @MainActor
    func targetNotFound() {
        let id1 = UUID()
        let id2 = UUID()
        let result = AppCore.neighborID(in: [id1], removing: id2)
        #expect(result == nil)
    }

    @Test("empty list: returns nil")
    @MainActor
    func emptyList() {
        let result = AppCore.neighborID(in: [], removing: UUID())
        #expect(result == nil)
    }

    @Test("target is first of two: returns second")
    @MainActor
    func targetIsFirstOfTwo() {
        let id1 = UUID()
        let id2 = UUID()
        let result = AppCore.neighborID(in: [id1, id2], removing: id1)
        #expect(result == id2)
    }

    @Test("target is second of two: returns first")
    @MainActor
    func targetIsSecondOfTwo() {
        let id1 = UUID()
        let id2 = UUID()
        let result = AppCore.neighborID(in: [id1, id2], removing: id2)
        #expect(result == id1)
    }
}

// MARK: - Debounced search via FakeScheduler

@Suite("AppCore -- setMeetingsQuery with FakeScheduler")
struct MeetingsSearchDebouncedTests {
    @Test("search fires after 300ms debounce")
    @MainActor
    func debouncedSearchFiresAfterDelay() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "MeetingsSearch"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        _ = try await fix.store.createMeeting(title: "Budget review")
        await fix.core.reloadSummaries()

        fix.core.setMeetingsQuery("Budget")

        // Before debounce fires: searching should be true, no results
        #expect(fix.core.isSearchingMeetings == true)
        #expect(fix.core.meetingsResults.isEmpty)

        // Yield to let the search task register its sleep on FakeScheduler
        try await pollUntil { fakeScheduler.pendingCount > 0 }

        // Advance past the 300ms debounce
        fakeScheduler.advance(by: .milliseconds(300))
        // Poll until the search completes (store query is an async actor hop)
        try await pollUntil { fix.core.isSearchingMeetings == false }

        // Results should be populated
        #expect(fix.core.isSearchingMeetings == false)
        #expect(fix.core.meetingsResults.count == 1)
        #expect(fix.core.meetingsResults.first?.title == "Budget review")
    }

    @Test("rapid-fire queries cancel prior debounces")
    @MainActor
    func rapidFireCancelsPrior() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "MeetingsSearch"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        _ = try await fix.store.createMeeting(title: "Alpha Meeting")
        _ = try await fix.store.createMeeting(title: "Beta Meeting")
        await fix.core.reloadSummaries()

        // Rapid-fire queries
        fix.core.setMeetingsQuery("Alp")
        fix.core.setMeetingsQuery("Alpha")

        // Yield to let the search task register its sleep
        try await pollUntil { fakeScheduler.pendingCount > 0 }

        // Only the last query should execute after debounce
        fakeScheduler.advance(by: .milliseconds(300))
        try await pollUntil { fix.core.isSearchingMeetings == false }

        #expect(fix.core.meetingsQuery == "Alpha")
        #expect(fix.core.meetingsResults.count == 1)
        #expect(fix.core.meetingsResults.first?.title == "Alpha Meeting")
    }

    @Test("empty query clears results synchronously (no debounce)")
    @MainActor
    func emptyQueryClearsSynchronously() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "MeetingsSearch"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        _ = try await fix.store.createMeeting(title: "Test")
        await fix.core.reloadSummaries()

        // Run a search first
        fix.core.setMeetingsQuery("Test")
        try await pollUntil { fakeScheduler.pendingCount > 0 }
        fakeScheduler.advance(by: .milliseconds(300))
        try await pollUntil { !fix.core.meetingsResults.isEmpty }
        #expect(fix.core.meetingsResults.count == 1)

        // Clear with empty query
        fix.core.setMeetingsQuery("")
        // Should clear immediately, no debounce needed
        #expect(fix.core.meetingsResults.isEmpty)
        #expect(fix.core.isSearchingMeetings == false)
        #expect(fix.core.meetingsQuery == "")
    }
}

// MARK: - autoSelectTopResult

@Suite("AppCore -- autoSelectTopResult")
struct AutoSelectTopResultTests {
    @Test("search auto-selects top result when no current selection matches")
    @MainActor
    func autoSelectsTopResult() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "MeetingsSearch"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        let id1 = try await fix.store.createMeeting(title: "Alpha")
        _ = try await fix.store.createMeeting(title: "Beta")
        await fix.core.reloadSummaries()

        // No selection set
        fix.core.setMeetingsQuery("Alpha")
        try await pollUntil { fakeScheduler.pendingCount > 0 }
        fakeScheduler.advance(by: .milliseconds(300))
        try await pollUntil { fix.core.isSearchingMeetings == false }

        // Should auto-select the top result (Alpha)
        #expect(fix.core.meetingsResults.count == 1)
        #expect(fix.core.meetingsSelection == id1)
    }

    @Test("search always selects top result even when prior selection survives")
    @MainActor
    func searchAlwaysSelectsTopResult() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "MeetingsSearch"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        _ = try await fix.store.createMeeting(title: "Alpha One")
        try await Task.sleep(for: .milliseconds(10))
        let id2 = try await fix.store.createMeeting(title: "Alpha Two")
        await fix.core.reloadSummaries()

        // Pre-select id2 (not the top result for "Alpha")
        fix.core.selectFromList(id2)
        #expect(fix.core.meetingsSelection == id2)

        // Search for "Alpha" -- both match; selection should jump to the
        // top result, NOT stick to id2.
        fix.core.setMeetingsQuery("Alpha")
        try await pollUntil { fakeScheduler.pendingCount > 0 }
        fakeScheduler.advance(by: .milliseconds(300))
        try await pollUntil { fix.core.isSearchingMeetings == false }

        #expect(fix.core.meetingsResults.count == 2)
        let topResultID = fix.core.meetingsResults.first?.id
        #expect(fix.core.meetingsSelection == topResultID)
    }

    @Test("search results change moves selection to new top result")
    @MainActor
    func searchResultsChangeSelectsNewTop() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "MeetingsSearch"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        let id1 = try await fix.store.createMeeting(title: "Alpha One")
        try await Task.sleep(for: .milliseconds(10))
        _ = try await fix.store.createMeeting(title: "Alpha Two")
        try await Task.sleep(for: .milliseconds(10))
        _ = try await fix.store.createMeeting(title: "Beta Only")
        await fix.core.reloadSummaries()

        // First search: "Alpha" matches two meetings
        fix.core.setMeetingsQuery("Alpha")
        try await pollUntil { fakeScheduler.pendingCount > 0 }
        fakeScheduler.advance(by: .milliseconds(300))
        try await pollUntil { fix.core.isSearchingMeetings == false }

        #expect(fix.core.meetingsResults.count == 2)
        let firstTopID = fix.core.meetingsResults.first?.id
        #expect(fix.core.meetingsSelection == firstTopID)

        // Refine search: "One" matches only id1; selection moves to new top
        fix.core.setMeetingsQuery("One")
        try await pollUntil { fakeScheduler.pendingCount > 0 }
        fakeScheduler.advance(by: .milliseconds(300))
        try await pollUntil { fix.core.isSearchingMeetings == false }

        #expect(fix.core.meetingsResults.count == 1)
        #expect(fix.core.meetingsSelection == id1)
    }

    @Test("search with no results sets selection to nil")
    @MainActor
    func noResultsSetsNilSelection() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "MeetingsSearch"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        _ = try await fix.store.createMeeting(title: "Alpha")
        await fix.core.reloadSummaries()

        fix.core.setMeetingsQuery("nonexistent")
        try await pollUntil { fakeScheduler.pendingCount > 0 }
        fakeScheduler.advance(by: .milliseconds(300))
        try await pollUntil { fix.core.isSearchingMeetings == false }

        #expect(fix.core.meetingsResults.isEmpty)
        #expect(fix.core.meetingsSelection == nil)
    }
}

// MARK: - Delete-select-next

@Suite("AppCore -- delete selects neighbor")
struct DeleteSelectNeighborTests {
    @Test("delete in browse mode selects next meeting")
    @MainActor
    func deleteSelectsNextInBrowseMode() async throws {
        let fix = try makeCoreFixture(testName: "DeleteSelect")
        defer { fix.cleanup() }

        // Create meetings in order: A (oldest), B, C (newest)
        let idA = try await fix.store.createMeeting(title: "Meeting A")
        try await Task.sleep(for: .milliseconds(10))
        let idB = try await fix.store.createMeeting(title: "Meeting B")
        try await Task.sleep(for: .milliseconds(10))
        let idC = try await fix.store.createMeeting(title: "Meeting C")
        await fix.core.reloadSummaries()

        // Summaries are newest-first: [C, B, A]
        #expect(fix.core.summaries.map(\.id) == [idC, idB, idA])

        // Select B
        fix.core.select(idB)
        #expect(fix.core.meetingsSelection == idB)

        // Delete B -> should select the NEXT element (A, since B is at index 1)
        await fix.core.deleteMeeting(meetingID: idB)

        #expect(fix.core.route == .meetings)
        #expect(fix.core.meetingsSelection == idA)
    }

    @Test("delete last meeting in browse mode selects previous")
    @MainActor
    func deleteLastSelectsPreviousInBrowseMode() async throws {
        let fix = try makeCoreFixture(testName: "DeleteSelect")
        defer { fix.cleanup() }

        let idA = try await fix.store.createMeeting(title: "Meeting A")
        try await Task.sleep(for: .milliseconds(10))
        let idB = try await fix.store.createMeeting(title: "Meeting B")
        await fix.core.reloadSummaries()

        // Summaries: [B, A]. Select A (last in the list).
        fix.core.select(idA)

        // Delete A -> should select B (the one before)
        await fix.core.deleteMeeting(meetingID: idA)

        #expect(fix.core.meetingsSelection == idB)
    }

    @Test("delete only meeting sets selection to nil")
    @MainActor
    func deleteOnlyMeetingSetsNil() async throws {
        let fix = try makeCoreFixture(testName: "DeleteSelect")
        defer { fix.cleanup() }

        let id = try await fix.store.createMeeting(title: "Sole Meeting")
        await fix.core.reloadSummaries()

        fix.core.select(id)
        await fix.core.deleteMeeting(meetingID: id)

        #expect(fix.core.meetingsSelection == nil)
        #expect(fix.core.route == .meetings)
    }

    @Test("delete in search mode selects neighbor from search results order")
    @MainActor
    func deleteSelectsNeighborFromSearchResults() async throws {
        let fix = try makeCoreFixture(
            useFakeScheduler: true,
            testName: "DeleteSelect"
        )
        defer { fix.cleanup() }

        guard let fakeScheduler = fix.fakeScheduler else {
            Issue.record("Expected FakeScheduler")
            return
        }

        // Create meetings: A (oldest), B, C (newest)
        let idA = try await fix.store.createMeeting(title: "Sprint Alpha")
        try await Task.sleep(for: .milliseconds(10))
        let idB = try await fix.store.createMeeting(title: "Sprint Beta")
        try await Task.sleep(for: .milliseconds(10))
        _ = try await fix.store.createMeeting(title: "Sprint Gamma")
        await fix.core.reloadSummaries()

        // Search for "Sprint" -- all three match; search results order
        // is determined by the DataStore (relevance / newest-first).
        fix.core.setMeetingsQuery("Sprint")
        try await pollUntil { fakeScheduler.pendingCount > 0 }
        fakeScheduler.advance(by: .milliseconds(300))
        try await pollUntil { fix.core.isSearchingMeetings == false }

        #expect(fix.core.meetingsResults.count == 3)

        // Select B in the search results
        fix.core.selectFromList(idB)
        #expect(fix.core.meetingsSelection == idB)

        // The search results list is the active order. Find B's index
        // and verify the neighbor is computed from meetingsResults.
        let searchOrder = fix.core.meetingsResults.map(\.id)
        let expectedNeighbor = AppCore.neighborID(
            in: searchOrder, removing: idB
        )

        // Delete B
        await fix.core.deleteMeeting(meetingID: idB)

        // Should NOT fall back to summaries order; should use search
        // results order. The neighbor should match what neighborID
        // computes from the pre-delete search order.
        #expect(fix.core.meetingsSelection == expectedNeighbor)
        #expect(fix.core.route == .meetings)
        // Query preserved after delete
        #expect(fix.core.meetingsQuery == "Sprint")
        // Results refreshed (B removed)
        #expect(!fix.core.meetingsResults.contains { $0.id == idB })
        _ = idA // silence unused warning
    }
}

// MARK: - DataStore meetingSummaries limit tests

@Suite("DataStore -- meetingSummaries limit parameter")
struct MeetingSummariesLimitTests {
    @Test("meetingSummaries with no limit returns all")
    @MainActor
    func noLimitReturnsAll() async throws {
        let store = try DataStore(storage: .inMemory)
        _ = try await store.createMeeting(title: "A")
        _ = try await store.createMeeting(title: "B")
        _ = try await store.createMeeting(title: "C")

        let all = try await store.meetingSummaries()
        #expect(all.count == 3)
    }

    @Test("meetingSummaries with limit caps results")
    @MainActor
    func limitCapsResults() async throws {
        let store = try DataStore(storage: .inMemory)
        _ = try await store.createMeeting(title: "A")
        _ = try await store.createMeeting(title: "B")
        _ = try await store.createMeeting(title: "C")

        let limited = try await store.meetingSummaries(limit: 2)
        #expect(limited.count == 2)
    }
}

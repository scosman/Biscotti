import BiscottiTestSupport
import DataStore
import Foundation
import Testing
import Transcription
@testable import AppCore
@testable import SearchUI

// MARK: - Helpers

/// Polls a condition until true, up to `timeout` (default 2 s).
/// Checks every 50 ms so tests pass fast on idle machines but survive
/// parallel-load slowdowns that make a fixed `Task.sleep` flaky.
private func pollUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async throws {
    let iterations = Int(timeout.components.seconds * 20
        + timeout.components.attoseconds / 50_000_000_000_000_000)
    for _ in 0 ..< max(iterations, 1) {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
}

// MARK: - Search result tests

@Suite("SearchViewModel -- results")
struct SearchViewModelResultTests {
    @Test("search returns ranked results from DataStore")
    @MainActor
    func searchReturnsRankedResults() async throws {
        let fix = try makeCoreFixture(testName: "SearchUITests")
        defer { fix.cleanup() }

        // Create meetings with searchable titles
        _ = try await fix.store.createMeeting(title: "Meeting with Sam")
        _ = try await fix.store.createMeeting(title: "Planning session")
        await fix.core.reloadSummaries()

        let viewModel = SearchViewModel(core: fix.core)
        viewModel.updateQuery("Sam")

        // Wait for debounce + search to settle
        try await pollUntil {
            viewModel.isSearching == false
                && viewModel.results.count == 1
        }

        #expect(viewModel.results.count == 1)
        #expect(viewModel.results.first?.title == "Meeting with Sam")
        #expect(viewModel.isSearching == false)
    }

    @Test("search debounce cancels prior queries")
    @MainActor
    func searchDebouncesCancelsPrior() async throws {
        let fix = try makeCoreFixture(testName: "SearchUITests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "Alpha Meeting")
        _ = try await fix.store.createMeeting(title: "Beta Meeting")
        await fix.core.reloadSummaries()

        let viewModel = SearchViewModel(core: fix.core)

        // Rapid-fire queries; only the last should execute
        viewModel.updateQuery("Al")
        viewModel.updateQuery("Alp")
        viewModel.updateQuery("Alpha")

        // Wait for final debounce + search to settle
        try await pollUntil {
            viewModel.isSearching == false
                && viewModel.results.count == 1
        }

        // The query should be "Alpha" and results should match
        #expect(viewModel.query == "Alpha")
        #expect(viewModel.results.count == 1)
        #expect(viewModel.results.first?.title == "Alpha Meeting")
    }

    @Test("no results shows empty state message")
    @MainActor
    func searchNoResultsShowsMessage() async throws {
        let fix = try makeCoreFixture(testName: "SearchUITests")
        defer { fix.cleanup() }

        let viewModel = SearchViewModel(core: fix.core)
        viewModel.updateQuery("nonexistent")

        // Wait for debounce + search to settle
        try await pollUntil {
            viewModel.isSearching == false && viewModel.showNoResults
        }

        #expect(viewModel.showNoResults == true)
        #expect(viewModel.noResultsMessage == "No meetings match 'nonexistent'.")
    }

    @Test("empty query clears results without searching")
    @MainActor
    func searchEmptyQueryClearsResults() async throws {
        let fix = try makeCoreFixture(testName: "SearchUITests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "Test Meeting")
        await fix.core.reloadSummaries()

        let viewModel = SearchViewModel(core: fix.core)

        // First populate results
        viewModel.updateQuery("Test")
        try await pollUntil {
            viewModel.isSearching == false
                && !viewModel.results.isEmpty
        }
        #expect(!viewModel.results.isEmpty)

        // Clear with empty query
        viewModel.updateQuery("")
        // Should clear immediately (no debounce needed)
        #expect(viewModel.results.isEmpty)
        #expect(viewModel.query == "")
        #expect(viewModel.isSearching == false)
    }

    @Test("search ranks title matches above transcript matches")
    @MainActor
    func searchRanksTitleAboveTranscript() async throws {
        let fix = try makeCoreFixture(testName: "SearchUITests")
        defer { fix.cleanup() }

        // Meeting A: "budget" in title only (score 3 -- title weight)
        _ = try await fix.store.createMeeting(title: "Budget review")

        // Meeting B: "budget" only in transcript text (score 1 -- transcript weight)
        let meetingBID = try await fix.store.createMeeting(title: "Planning session")
        let seg = TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0",
            startTime: 0, endTime: 5,
            text: "We need to finalize the budget for next quarter",
            confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
        let result = TranscriptResult(
            transcriptionMethodId: "v1", language: "en", speakerCount: 1,
            segments: [seg], speakerEmbeddings: [:], processingDuration: 1.0
        )
        let txID = try await fix.store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingBID
        )
        try await fix.store.setPreferredTranscript(txID, for: meetingBID)

        await fix.core.reloadSummaries()

        let viewModel = SearchViewModel(core: fix.core)
        viewModel.updateQuery("budget")
        try await pollUntil {
            viewModel.isSearching == false
                && viewModel.results.count == 2
        }

        // Both meetings match "budget"
        #expect(viewModel.results.count == 2)
        // Title match (score 3) ranks above transcript match (score 1)
        #expect(viewModel.results[0].title == "Budget review")
        #expect(viewModel.results[0].matchedFields.contains(.title) == true)
        #expect(viewModel.results[1].title == "Planning session")
        #expect(viewModel.results[1].matchedFields.contains(.transcript) == true)
    }
}

// MARK: - Navigation tests

@Suite("SearchViewModel -- navigation")
struct SearchViewModelNavigationTests {
    @Test("dismiss restores pre-search route")
    @MainActor
    func searchBackRestoresRoute() throws {
        let fix = try makeCoreFixture(testName: "SearchUITests")
        defer { fix.cleanup() }

        // Navigate to settings first
        fix.core.showSettings()
        #expect(fix.core.route == .settings)

        // Enter search
        fix.core.presentSearch()
        #expect(fix.core.route == .search)

        let viewModel = SearchViewModel(core: fix.core)
        viewModel.dismiss()

        // Route restored to settings
        #expect(fix.core.route == .settings)
    }

    @Test("selectResult navigates to meeting detail")
    @MainActor
    func selectResultNavigates() throws {
        let fix = try makeCoreFixture(testName: "SearchUITests")
        defer { fix.cleanup() }

        let viewModel = SearchViewModel(core: fix.core)
        let meetingID = UUID()
        viewModel.selectResult(meetingID)

        #expect(fix.core.route == .meeting(meetingID))
    }
}

// MARK: - Formatting tests

@Suite("SearchViewModel -- formatting")
struct SearchViewModelFormattingTests {
    @Test("matchedFieldsText formats field names correctly")
    func matchedFieldsTextFormats() {
        let text = SearchViewModel.matchedFieldsText(
            [.title, .transcript]
        )
        #expect(text == "title, transcript")

        let single = SearchViewModel.matchedFieldsText([.people])
        #expect(single == "people")

        let all = SearchViewModel.matchedFieldsText(
            [.title, .people, .transcript]
        )
        #expect(all == "title, people, transcript")

        let empty = SearchViewModel.matchedFieldsText([])
        #expect(empty == "")
    }

    @Test("matchedFieldsText includes notes field")
    func matchedFieldsTextIncludesNotes() {
        let text = SearchViewModel.matchedFieldsText(
            [.title, .notes]
        )
        #expect(text == "title, notes")

        let notesOnly = SearchViewModel.matchedFieldsText([.notes])
        #expect(notesOnly == "notes")
    }
}

// MARK: - Immediate clear + spinner tests

@Suite("SearchViewModel -- clear results on query change")
struct SearchViewModelClearTests {
    @Test("updateQuery clears results and sets searching synchronously")
    @MainActor
    func updateQueryClearsResultsImmediately() async throws {
        let fix = try makeCoreFixture(testName: "SearchUITests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "Test Meeting")
        await fix.core.reloadSummaries()

        let viewModel = SearchViewModel(core: fix.core)

        // First, get some results
        viewModel.updateQuery("Test")
        try await pollUntil {
            viewModel.isSearching == false
                && !viewModel.results.isEmpty
        }
        #expect(viewModel.results.count == 1)

        // Now change the query -- results should clear and spinner
        // should show SYNCHRONOUSLY (before debounce fires)
        viewModel.updateQuery("Other")

        // Check immediately: results cleared, isSearching true
        #expect(viewModel.results.isEmpty)
        #expect(viewModel.isSearching == true)
        #expect(viewModel.query == "Other")

        // Let debounce complete
        try await pollUntil {
            viewModel.isSearching == false
        }
        // "Other" has no matches
        #expect(viewModel.results.isEmpty)
        #expect(viewModel.showNoResults == true)
    }

    @Test("empty query clears results and stops searching immediately, no spinner")
    @MainActor
    func emptyQueryClearsImmediatelyNoSpinner() async throws {
        let fix = try makeCoreFixture(testName: "SearchUITests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "Alpha")
        await fix.core.reloadSummaries()

        let viewModel = SearchViewModel(core: fix.core)

        // Get results first
        viewModel.updateQuery("Alpha")
        try await pollUntil {
            viewModel.isSearching == false
                && !viewModel.results.isEmpty
        }

        // Clear with empty query
        viewModel.updateQuery("")

        // Synchronous: no spinner, no results
        #expect(viewModel.results.isEmpty)
        #expect(viewModel.isSearching == false)
        #expect(viewModel.query == "")
    }

    @Test("new query during debounce clears stale results immediately")
    @MainActor
    func newQueryDuringDebounceClearsStale() async throws {
        let fix = try makeCoreFixture(testName: "SearchUITests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "First Meeting")
        _ = try await fix.store.createMeeting(title: "Second Meeting")
        await fix.core.reloadSummaries()

        let viewModel = SearchViewModel(core: fix.core)

        // Get "First" results
        viewModel.updateQuery("First")
        try await pollUntil {
            viewModel.isSearching == false
                && !viewModel.results.isEmpty
        }
        #expect(viewModel.results.count == 1)
        #expect(viewModel.results.first?.title == "First Meeting")

        // Change to "Second" -- stale "First" results must clear immediately
        viewModel.updateQuery("Second")
        #expect(viewModel.results.isEmpty, "Stale results should clear synchronously")
        #expect(viewModel.isSearching == true, "Spinner should show during debounce")

        // Wait for "Second" search to complete
        try await pollUntil {
            viewModel.isSearching == false
                && !viewModel.results.isEmpty
        }
        #expect(viewModel.results.count == 1)
        #expect(viewModel.results.first?.title == "Second Meeting")
    }
}

// MARK: - Back button tests

@Suite("SearchViewModel -- back button bug fix")
struct SearchViewModelBackButtonTests {
    @Test("enter search from meeting, Back returns to that meeting in one step")
    @MainActor
    func backFromMeetingRestoresRoute() throws {
        let fix = try makeCoreFixture(testName: "SearchUITests")
        defer { fix.cleanup() }

        let meetingID = UUID()
        fix.core.select(meetingID)
        #expect(fix.core.route == .meeting(meetingID))

        // Enter search (simulates typing in the search field)
        fix.core.presentSearch()
        #expect(fix.core.route == .search)
        #expect(fix.core.searchReturnRoute == .meeting(meetingID))

        // Simulate continued typing (more presentSearch calls)
        fix.core.presentSearch()
        fix.core.presentSearch()
        // Return route should NOT have been overwritten to .search
        #expect(fix.core.searchReturnRoute == .meeting(meetingID))

        // Tap Back
        let viewModel = SearchViewModel(core: fix.core)
        viewModel.dismiss()

        // Route should be the meeting, not .home, in ONE tap
        #expect(fix.core.route == .meeting(meetingID))
    }

    @Test("presentSearch is idempotent -- does not overwrite return route")
    @MainActor
    func presentSearchIdempotent() throws {
        let fix = try makeCoreFixture(testName: "SearchUITests")
        defer { fix.cleanup() }

        // Start on an event page
        fix.core.selectEvent("event-123")
        #expect(fix.core.route == .event("event-123"))

        // First presentSearch captures the return route
        fix.core.presentSearch()
        #expect(fix.core.searchReturnRoute == .event("event-123"))

        // Subsequent calls do NOT overwrite
        fix.core.presentSearch()
        #expect(fix.core.searchReturnRoute == .event("event-123"))

        // Dismiss returns to the event
        fix.core.dismissSearch()
        #expect(fix.core.route == .event("event-123"))
    }
}

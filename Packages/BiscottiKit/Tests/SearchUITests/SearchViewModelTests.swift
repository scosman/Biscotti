import BiscottiTestSupport
import DataStore
import Foundation
import Testing
import Transcription
@testable import AppCore
@testable import SearchUI

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

        // Wait for debounce to complete
        try await Task.sleep(for: .milliseconds(500))

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

        // Wait for final debounce
        try await Task.sleep(for: .milliseconds(500))

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

        // Wait for debounce
        try await Task.sleep(for: .milliseconds(500))

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
        try await Task.sleep(for: .milliseconds(500))
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
        try await Task.sleep(for: .milliseconds(500))

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
}

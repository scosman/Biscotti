import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import AppCore
@testable import MeetingListUI

// MARK: - Core projection tests

@Suite("MeetingListViewModel")
struct MeetingListViewModelTests {
    @Test("meetings reflects AppCore summaries")
    @MainActor
    func meetingsReflectsSummaries() async throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "Meeting A")
        _ = try await fix.store.createMeeting(title: "Meeting B")
        await fix.core.reloadSummaries()

        let viewModel = MeetingListViewModel(core: fix.core)

        #expect(viewModel.meetings.count == 2)
    }

    @Test("meetings is empty when store is empty")
    @MainActor
    func meetingsEmpty() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)

        #expect(viewModel.meetings.isEmpty)
    }

    @Test("select sets meetingsSelection (in-list selection, preserves route)")
    @MainActor
    func selectSetsSelection() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        fix.core.showMeetings()
        let viewModel = MeetingListViewModel(core: fix.core)
        let meetingID = UUID()
        viewModel.select(meetingID)

        #expect(fix.core.meetingsSelection == meetingID)
        #expect(fix.core.route == .meetings)
    }

    @Test("selectedID reflects current meetingsSelection")
    @MainActor
    func selectedIDReflectsSelection() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)

        #expect(viewModel.selectedID == nil)

        let meetingID = UUID()
        fix.core.select(meetingID)
        #expect(viewModel.selectedID == meetingID)
    }

    @Test("selectedID is nil when route is .home")
    @MainActor
    func selectedIDNilWhenHome() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)
        #expect(viewModel.selectedID == nil)
    }

    @Test("selectedID is nil when route is .recording")
    @MainActor
    func selectedIDNilWhenRecording() async throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let viewModel = MeetingListViewModel(core: fix.core)
        #expect(viewModel.selectedID == nil)
    }
}

// MARK: - Mode tests

@Suite("MeetingListViewModel -- mode")
struct MeetingListModeTests {
    @Test("mode is .browse when query is empty")
    @MainActor
    func modeIsBrowseWhenNoQuery() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)
        #expect(viewModel.mode == .browse)
    }

    @Test("mode is .search when query is non-empty")
    @MainActor
    func modeIsSearchWhenQuerySet() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        fix.core.setMeetingsQuery("test")
        let viewModel = MeetingListViewModel(core: fix.core)
        #expect(viewModel.mode == .search)
    }

    @Test("results reflects core meetingsResults")
    @MainActor
    func resultsReflectsCore() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)
        #expect(viewModel.results.isEmpty)
    }

    @Test("isSearching reflects core isSearchingMeetings")
    @MainActor
    func isSearchingReflectsCore() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)
        #expect(viewModel.isSearching == false)
    }

    @Test("query reflects core meetingsQuery")
    @MainActor
    func queryReflectsCore() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        fix.core.setMeetingsQuery("hello")
        let viewModel = MeetingListViewModel(core: fix.core)
        #expect(viewModel.query == "hello")
    }
}

// MARK: - matchedFieldsText tests

@Suite("MeetingListViewModel -- matchedFieldsText")
struct MeetingListMatchedFieldsTests {
    @Test("formats field names correctly")
    func matchedFieldsTextFormats() {
        let text = MeetingListViewModel.matchedFieldsText(
            [.title, .transcript]
        )
        #expect(text == "title, transcript")

        let single = MeetingListViewModel.matchedFieldsText([.people])
        #expect(single == "people")

        let all = MeetingListViewModel.matchedFieldsText(
            [.title, .people, .transcript]
        )
        #expect(all == "title, people, transcript")

        let empty = MeetingListViewModel.matchedFieldsText([])
        #expect(empty == "")
    }

    @Test("includes notes field")
    func matchedFieldsTextIncludesNotes() {
        let text = MeetingListViewModel.matchedFieldsText(
            [.title, .notes]
        )
        #expect(text == "title, notes")

        let notesOnly = MeetingListViewModel.matchedFieldsText([.notes])
        #expect(notesOnly == "notes")
    }
}

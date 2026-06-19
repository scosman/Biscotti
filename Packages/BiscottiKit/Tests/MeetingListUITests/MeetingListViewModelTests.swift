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
        viewModel.select([meetingID])

        #expect(fix.core.meetingsSelection == [meetingID])
        #expect(fix.core.route == .meetings)
    }

    @Test("selectedIDs reflects current meetingsSelection")
    @MainActor
    func selectedIDsReflectsSelection() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)

        #expect(viewModel.selectedIDs.isEmpty)

        let meetingID = UUID()
        fix.core.select(meetingID)
        #expect(viewModel.selectedIDs == [meetingID])
    }

    @Test("selectedIDs is empty when route is .home")
    @MainActor
    func selectedIDsEmptyWhenHome() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)
        #expect(viewModel.selectedIDs.isEmpty)
    }

    @Test("selectedIDs is empty when route is .recording")
    @MainActor
    func selectedIDsEmptyWhenRecording() async throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let viewModel = MeetingListViewModel(core: fix.core)
        #expect(viewModel.selectedIDs.isEmpty)
    }
}

// MARK: - Delete confirmation tests (7b)

@Suite("MeetingListViewModel -- delete confirmation")
struct MeetingListDeleteConfirmationTests {
    @Test("requestDeleteSelection with empty selection does not show alert")
    @MainActor
    func requestDeleteSelectionGuardsEmpty() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)
        // Selection is empty
        viewModel.requestDeleteSelection()
        #expect(viewModel.showDeleteConfirmation == false)
        #expect(viewModel.deleteConfirmationCount == 0)
    }

    @Test("requestDeleteSelection with selection shows alert with correct count")
    @MainActor
    func requestDeleteSelectionShowsAlert() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let id1 = UUID()
        let id2 = UUID()
        fix.core.selectFromList([id1, id2])

        let viewModel = MeetingListViewModel(core: fix.core)
        viewModel.requestDeleteSelection()

        #expect(viewModel.showDeleteConfirmation == true)
        #expect(viewModel.deleteConfirmationCount == 2)
    }

    @Test("requestDeleteSelection with single selection sets count to 1")
    @MainActor
    func requestDeleteSelectionSingular() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        fix.core.select(UUID())
        let viewModel = MeetingListViewModel(core: fix.core)
        viewModel.requestDeleteSelection()

        #expect(viewModel.showDeleteConfirmation == true)
        #expect(viewModel.deleteConfirmationCount == 1)
    }

    @Test("cancelDelete dismisses confirmation")
    @MainActor
    func cancelDeleteDismisses() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        fix.core.select(UUID())
        let viewModel = MeetingListViewModel(core: fix.core)
        viewModel.requestDeleteSelection()
        #expect(viewModel.showDeleteConfirmation == true)

        viewModel.cancelDelete()
        #expect(viewModel.showDeleteConfirmation == false)
    }

    @Test("confirmDelete deletes selected meetings")
    @MainActor
    func confirmDeleteRemovesMeetings() async throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let id1 = try await fix.store.createMeeting(title: "Delete A")
        let id2 = try await fix.store.createMeeting(title: "Delete B")
        await fix.core.reloadSummaries()
        fix.core.selectFromList([id1, id2])

        let viewModel = MeetingListViewModel(core: fix.core)
        viewModel.requestDeleteSelection()
        #expect(viewModel.showDeleteConfirmation == true)

        await viewModel.confirmDelete()

        #expect(viewModel.showDeleteConfirmation == false)
        #expect(try await fix.store.meetingExists(id: id1) == false)
        #expect(try await fix.store.meetingExists(id: id2) == false)
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

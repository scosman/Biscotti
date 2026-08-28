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

// MARK: - Context menu delete tests

@Suite("MeetingListViewModel -- context menu delete")
struct MeetingListContextMenuDeleteTests {
    @Test("requestDeleteContextMenu with empty set does not show alert")
    @MainActor
    func contextMenuEmptyGuard() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)
        viewModel.requestDeleteContextMenu([])
        #expect(viewModel.showDeleteConfirmation == false)
        #expect(viewModel.deleteConfirmationCount == 0)
    }

    @Test("requestDeleteContextMenu with single ID shows alert with count 1")
    @MainActor
    func contextMenuSingleItem() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)
        let id = UUID()
        viewModel.requestDeleteContextMenu([id])

        #expect(viewModel.showDeleteConfirmation == true)
        #expect(viewModel.deleteConfirmationCount == 1)
    }

    @Test("requestDeleteContextMenu with multiple IDs shows alert with correct count")
    @MainActor
    func contextMenuMultipleItems() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)
        let ids: Set<UUID> = [UUID(), UUID(), UUID()]
        viewModel.requestDeleteContextMenu(ids)

        #expect(viewModel.showDeleteConfirmation == true)
        #expect(viewModel.deleteConfirmationCount == 3)
    }

    @Test("confirmDelete after context menu request deletes the correct meetings")
    @MainActor
    func contextMenuConfirmDeleteRemovesMeetings() async throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let id1 = try await fix.store.createMeeting(title: "Context A")
        let id2 = try await fix.store.createMeeting(title: "Context B")
        let id3 = try await fix.store.createMeeting(title: "Keep Me")
        await fix.core.reloadSummaries()

        let viewModel = MeetingListViewModel(core: fix.core)
        viewModel.requestDeleteContextMenu([id1, id2])
        #expect(viewModel.showDeleteConfirmation == true)

        await viewModel.confirmDelete()

        #expect(viewModel.showDeleteConfirmation == false)
        #expect(try await fix.store.meetingExists(id: id1) == false)
        #expect(try await fix.store.meetingExists(id: id2) == false)
        #expect(try await fix.store.meetingExists(id: id3) == true)
    }

    @Test("deleteMenuLabel returns 'Delete' for single item")
    func deleteMenuLabelSingular() {
        #expect(MeetingListViewModel.deleteMenuLabel(for: 1) == "Delete")
    }

    @Test("deleteMenuLabel returns 'Delete N' for multiple items")
    func deleteMenuLabelPlural() {
        #expect(MeetingListViewModel.deleteMenuLabel(for: 3) == "Delete 3")
    }

    @Test("deleteMenuLabel returns 'Delete' for zero")
    func deleteMenuLabelZero() {
        #expect(MeetingListViewModel.deleteMenuLabel(for: 0) == "Delete")
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

    @Test("showsSearchSpinner reflects core showsMeetingsSearchSpinner")
    @MainActor
    func showsSearchSpinnerReflectsCore() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)
        #expect(viewModel.showsSearchSpinner == false)
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

// MARK: - Search-result second line tests

@Suite("MeetingListViewModel -- searchSecondLine(for:)")
struct MeetingListSearchSecondLineTests {
    private func hit(
        title: String, snippet: String, preview: String = "Preview text"
    ) -> SearchHit {
        SearchHit(
            id: UUID(), title: title, date: Date(),
            score: 1.0, snippet: snippet, preview: preview
        )
    }

    @Test("prefers the match excerpt")
    func secondLineKeepsBodyExcerpt() {
        let line = MeetingListViewModel.searchSecondLine(
            for: hit(
                title: "Weekly Sync",
                snippet: "\u{2026}we should refactor the database layer\u{2026}"
            )
        )
        #expect(line == "\u{2026}we should refactor the database layer\u{2026}")
    }

    /// FTS5 picks the best-matching column. For a title-only match that is
    /// the title, which would repeat the row's own first line.
    @Test("falls back to the preview when the excerpt echoes the title")
    func secondLineFallsBackOnTitleEcho() {
        let line = MeetingListViewModel.searchSecondLine(
            for: hit(
                title: "Sprint Planning", snippet: "Sprint Planning",
                preview: "Q3 priorities were agreed."
            )
        )
        #expect(line == "Q3 priorities were agreed.")
    }

    @Test("falls back when the excerpt is a truncated title echo")
    func secondLineFallsBackOnTruncatedTitleEcho() {
        let line = MeetingListViewModel.searchSecondLine(
            for: hit(
                title: "Quarterly Roadmap Review With The Platform Team",
                snippet: "Quarterly Roadmap Review With The\u{2026}",
                preview: "Owners assigned for each workstream."
            )
        )
        #expect(line == "Owners assigned for each workstream.")
    }

    @Test("never returns an empty line")
    func secondLineIsNeverEmpty() {
        #expect(MeetingListViewModel.searchSecondLine(
            for: hit(title: "Standup", snippet: "", preview: "")
        ) == "No transcript yet")
        #expect(MeetingListViewModel.searchSecondLine(
            for: hit(title: "Standup", snippet: "\u{2026}", preview: "  ")
        ) == "No transcript yet")
    }
}

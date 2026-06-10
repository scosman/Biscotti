import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import AppCore
@testable import MeetingListUI

// MARK: - Tests

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

    @Test("select updates route to .meeting")
    @MainActor
    func selectUpdatesRoute() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)
        let meetingID = UUID()
        viewModel.select(meetingID)

        #expect(fix.core.route == .meeting(meetingID))
    }

    @Test("selectedMeetingID reflects current route")
    @MainActor
    func selectedMeetingIDReflectsRoute() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)

        #expect(viewModel.selectedMeetingID == nil)

        let meetingID = UUID()
        fix.core.select(meetingID)
        #expect(viewModel.selectedMeetingID == meetingID)
    }

    @Test("selectedMeetingID is nil when route is .home")
    @MainActor
    func selectedMeetingIDNilWhenHome() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        let viewModel = MeetingListViewModel(core: fix.core)
        #expect(viewModel.selectedMeetingID == nil)
    }

    @Test("selectedMeetingID is nil when route is .recording")
    @MainActor
    func selectedMeetingIDNilWhenRecording() async throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        await fix.core.startRecording()
        let viewModel = MeetingListViewModel(core: fix.core)
        #expect(viewModel.selectedMeetingID == nil)
    }

    @Test("relativeDate produces non-empty string")
    @MainActor
    func relativeDateFormatsCorrectly() {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let result = MeetingListViewModel.relativeDate(oneHourAgo)
        #expect(!result.isEmpty)
    }
}

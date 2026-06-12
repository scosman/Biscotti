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

    @Test("select sets meetingsSelection (in-list selection, preserves route)")
    @MainActor
    func selectSetsSelection() throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        // The list is shown inside .meetings; selectFromList only updates selection.
        fix.core.showMeetings()
        let viewModel = MeetingListViewModel(core: fix.core)
        let meetingID = UUID()
        viewModel.select(meetingID)

        #expect(fix.core.meetingsSelection == meetingID)
        #expect(fix.core.route == .meetings) // unchanged
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

// MARK: - Grouping tests

@Suite("MeetingListViewModel -- groupByEffectiveDate")
struct MeetingListGroupingTests {
    /// Creates a MeetingSummary with a specific date.
    private static func makeSummary(
        title: String,
        date: Date,
        id: UUID = UUID()
    ) -> MeetingSummary {
        MeetingSummary(
            id: id,
            title: title,
            date: date,
            hasTranscript: false
        )
    }

    @Test("groups meetings into Today, Yesterday, This Week, Earlier")
    @MainActor
    func pastListGroupsByEffectiveDate() {
        let cal = Foundation.Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)

        let todayMeeting = Self.makeSummary(
            title: "Today",
            date: startOfToday.addingTimeInterval(3600) // 1am today
        )
        let yesterdayMeeting = Self.makeSummary(
            title: "Yesterday",
            date: startOfToday.addingTimeInterval(-3600) // yesterday 11pm
        )
        let earlierMeeting = Self.makeSummary(
            title: "Last Month",
            date: startOfToday.addingTimeInterval(-30 * 24 * 3600)
        )

        let groups = MeetingListViewModel.groupByEffectiveDate(
            [todayMeeting, yesterdayMeeting, earlierMeeting],
            relativeTo: now,
            calendar: cal
        )

        // Should have at least 2 groups (Today, Yesterday or Earlier depending on week)
        #expect(groups.count >= 2)
        #expect(groups.first?.title == "Today")
        #expect(groups.first?.meetings.count == 1)
        #expect(groups.first?.meetings.first?.title == "Today")
    }

    @Test("omits empty groups")
    @MainActor
    func pastListOmitsEmptyGroups() {
        let cal = Foundation.Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)

        // Only one meeting from today -> only one group
        let todayMeeting = Self.makeSummary(
            title: "Today Only",
            date: startOfToday.addingTimeInterval(100)
        )

        let groups = MeetingListViewModel.groupByEffectiveDate(
            [todayMeeting],
            relativeTo: now,
            calendar: cal
        )

        #expect(groups.count == 1)
        #expect(groups.first?.title == "Today")
    }

    @Test("sorts newest first within group")
    @MainActor
    func pastListSortsNewestFirst() {
        let cal = Foundation.Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)

        let earlier = Self.makeSummary(
            title: "Morning",
            date: startOfToday.addingTimeInterval(100)
        )
        let later = Self.makeSummary(
            title: "Afternoon",
            date: startOfToday.addingTimeInterval(50000)
        )

        let groups = MeetingListViewModel.groupByEffectiveDate(
            [earlier, later],
            relativeTo: now.addingTimeInterval(86400), // "now" is tomorrow so both are "yesterday" or "today"
            calendar: cal
        )

        // Within each group, newest first
        if let first = groups.first {
            if first.meetings.count >= 2 {
                #expect(first.meetings[0].date > first.meetings[1].date)
            }
        }
    }

    @Test("empty input produces empty groups")
    @MainActor
    func groupingEmptyInput() {
        let groups = MeetingListViewModel.groupByEffectiveDate([])
        #expect(groups.isEmpty)
    }

    @Test("grouping uses effective date (startDate when present, else createdAt)")
    @MainActor
    func groupingUsesEffectiveDate() {
        let cal = Foundation.Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)

        // Simulate a meeting whose effective date (= startDate) is yesterday,
        // even though we construct it "now". The MeetingSummary.date field
        // IS the effective date -- DataStore resolves startDate vs createdAt
        // before populating the DTO. This test verifies groupByEffectiveDate
        // sorts on that resolved date, not on some other timestamp.
        let yesterdayEffective = Self.makeSummary(
            title: "Started Yesterday",
            date: startOfToday.addingTimeInterval(-7200) // 2 hours before today
        )
        let todayEffective = Self.makeSummary(
            title: "Started Today",
            date: startOfToday.addingTimeInterval(3600) // 1 hour into today
        )

        let groups = MeetingListViewModel.groupByEffectiveDate(
            [yesterdayEffective, todayEffective],
            relativeTo: now,
            calendar: cal
        )

        // Should split into Today and Yesterday based on the effective date
        #expect(groups.count == 2)

        let todayGroup = groups.first { $0.id == "today" }
        let yesterdayGroup = groups.first { $0.id == "yesterday" }

        #expect(todayGroup?.meetings.count == 1)
        #expect(todayGroup?.meetings.first?.title == "Started Today")
        #expect(yesterdayGroup?.meetings.count == 1)
        #expect(yesterdayGroup?.meetings.first?.title == "Started Yesterday")
    }

    @Test("groupedMeetings property mirrors static function")
    @MainActor
    func groupedMeetingsReflectsCore() async throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "A")
        _ = try await fix.store.createMeeting(title: "B")
        await fix.core.reloadSummaries()

        let listVM = MeetingListViewModel(core: fix.core)
        let grouped = listVM.groupedMeetings

        // Should have at least one group containing the meetings
        let totalMeetings = grouped.reduce(0) { $0 + $1.meetings.count }
        #expect(totalMeetings == 2)
    }
}

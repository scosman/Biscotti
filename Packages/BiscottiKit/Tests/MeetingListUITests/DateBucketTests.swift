import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import AppCore
@testable import MeetingListUI

// MARK: - Shared helpers

/// Creates a MeetingSummary with a specific date.
private func makeSummary(
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

/// Fixed reference date: 2026-06-15 12:00:00 UTC (a Monday).
private let referenceDate: Date = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .gmt
    return cal.date(
        from: DateComponents(year: 2026, month: 6, day: 15, hour: 12)
    ) ?? Date()
}()

/// A calendar fixed to UTC for deterministic tests.
private let utcCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .gmt
    return cal
}()

// MARK: - Individual bucket tests

@Suite("groupByDateBuckets -- individual buckets")
struct DateBucketIndividualTests {
    @Test("empty input produces empty groups")
    func groupingEmptyInput() {
        let groups = MeetingListViewModel.groupByDateBuckets(
            [], relativeTo: referenceDate, calendar: utcCalendar
        )
        #expect(groups.isEmpty)
    }

    @Test("today bucket captures meetings from today")
    func todayBucket() {
        let todayMorning = utcCalendar.startOfDay(
            for: referenceDate
        ).addingTimeInterval(3600)
        let meeting = makeSummary(title: "Today", date: todayMorning)

        let groups = MeetingListViewModel.groupByDateBuckets(
            [meeting], relativeTo: referenceDate, calendar: utcCalendar
        )

        #expect(groups.count == 1)
        #expect(groups[0].id == "today")
        #expect(groups[0].title == "Today")
        #expect(groups[0].meetings.count == 1)
    }

    @Test("yesterday bucket captures meetings from yesterday")
    func yesterdayBucket() {
        let startOfToday = utcCalendar.startOfDay(for: referenceDate)
        let yesterdayEvening = startOfToday.addingTimeInterval(-3600)
        let meeting = makeSummary(
            title: "Yesterday", date: yesterdayEvening
        )

        let groups = MeetingListViewModel.groupByDateBuckets(
            [meeting], relativeTo: referenceDate, calendar: utcCalendar
        )

        #expect(groups.count == 1)
        #expect(groups[0].id == "yesterday")
        #expect(groups[0].title == "Yesterday")
    }

    @Test("previous 7 days bucket captures 2-7 days ago")
    func prev7DaysBucket() {
        let startOfToday = utcCalendar.startOfDay(for: referenceDate)
        let threeDaysAgo = startOfToday.addingTimeInterval(
            -3 * 24 * 3600 + 3600
        )
        let meeting = makeSummary(
            title: "3 Days Ago", date: threeDaysAgo
        )

        let groups = MeetingListViewModel.groupByDateBuckets(
            [meeting], relativeTo: referenceDate, calendar: utcCalendar
        )

        #expect(groups.count == 1)
        #expect(groups[0].id == "prev7")
        #expect(groups[0].title == "Previous 7 Days")
    }

    @Test("previous 30 days bucket captures 8-30 days ago")
    func prev30DaysBucket() {
        let startOfToday = utcCalendar.startOfDay(for: referenceDate)
        let fifteenDaysAgo = startOfToday.addingTimeInterval(
            -15 * 24 * 3600 + 3600
        )
        let meeting = makeSummary(
            title: "15 Days Ago", date: fifteenDaysAgo
        )

        let groups = MeetingListViewModel.groupByDateBuckets(
            [meeting], relativeTo: referenceDate, calendar: utcCalendar
        )

        #expect(groups.count == 1)
        #expect(groups[0].id == "prev30")
        #expect(groups[0].title == "Previous 30 Days")
    }

    @Test("month bucket captures older dates in the current year")
    func monthBucket() {
        let marchDate = utcCalendar.date(
            from: DateComponents(
                year: 2026, month: 3, day: 15, hour: 12
            )
        ) ?? referenceDate
        let meeting = makeSummary(title: "March", date: marchDate)

        let groups = MeetingListViewModel.groupByDateBuckets(
            [meeting], relativeTo: referenceDate, calendar: utcCalendar
        )

        #expect(groups.count == 1)
        #expect(groups[0].id == "month-3")
        #expect(groups[0].title == "March")
    }

    @Test("year bucket captures dates in prior years")
    func yearBucket() {
        let dec2025 = utcCalendar.date(
            from: DateComponents(
                year: 2025, month: 12, day: 15, hour: 12
            )
        ) ?? referenceDate
        let meeting = makeSummary(title: "Dec 2025", date: dec2025)

        let groups = MeetingListViewModel.groupByDateBuckets(
            [meeting], relativeTo: referenceDate, calendar: utcCalendar
        )

        #expect(groups.count == 1)
        #expect(groups[0].id == "year-2025")
        #expect(groups[0].title == "2025")
    }

    @Test("empty buckets are omitted")
    func emptyBucketsOmitted() {
        let todayMorning = utcCalendar.startOfDay(
            for: referenceDate
        ).addingTimeInterval(3600)
        let meeting = makeSummary(
            title: "Only Today", date: todayMorning
        )

        let groups = MeetingListViewModel.groupByDateBuckets(
            [meeting], relativeTo: referenceDate, calendar: utcCalendar
        )

        #expect(groups.count == 1)
        #expect(groups[0].id == "today")
    }
}

// MARK: - Multi-bucket and invariant tests

@Suite("groupByDateBuckets -- multi-bucket and invariants")
struct DateBucketCompositeTests {
    @Test("multiple months are grouped separately, most-recent first")
    func multipleMonthsBuckets() {
        let jan = utcCalendar.date(
            from: DateComponents(
                year: 2026, month: 1, day: 10, hour: 12
            )
        ) ?? referenceDate
        let march = utcCalendar.date(
            from: DateComponents(
                year: 2026, month: 3, day: 10, hour: 12
            )
        ) ?? referenceDate
        let meetings = [
            makeSummary(title: "March", date: march),
            makeSummary(title: "January", date: jan)
        ]

        let groups = MeetingListViewModel.groupByDateBuckets(
            meetings, relativeTo: referenceDate, calendar: utcCalendar
        )

        #expect(groups.count == 2)
        #expect(groups[0].title == "March")
        #expect(groups[1].title == "January")
    }

    @Test("multiple years are grouped separately, most-recent first")
    func multipleYearsBuckets() {
        let y2024 = utcCalendar.date(
            from: DateComponents(
                year: 2024, month: 6, day: 10, hour: 12
            )
        ) ?? referenceDate
        let y2025 = utcCalendar.date(
            from: DateComponents(
                year: 2025, month: 6, day: 10, hour: 12
            )
        ) ?? referenceDate
        let meetings = [
            makeSummary(title: "2025", date: y2025),
            makeSummary(title: "2024", date: y2024)
        ]

        let groups = MeetingListViewModel.groupByDateBuckets(
            meetings, relativeTo: referenceDate, calendar: utcCalendar
        )

        #expect(groups.count == 2)
        #expect(groups[0].title == "2025")
        #expect(groups[1].title == "2024")
    }

    @Test("all six bucket types in one grouping")
    func allSixBucketTypes() {
        let startOfToday = utcCalendar.startOfDay(for: referenceDate)

        let meetings = [
            makeSummary(
                title: "Today",
                date: startOfToday.addingTimeInterval(3600)
            ),
            makeSummary(
                title: "Yesterday",
                date: startOfToday.addingTimeInterval(-3600)
            ),
            makeSummary(
                title: "4 days ago",
                date: startOfToday.addingTimeInterval(-4 * 86400 + 3600)
            ),
            makeSummary(
                title: "20 days ago",
                date: startOfToday.addingTimeInterval(-20 * 86400 + 3600)
            ),
            makeSummary(
                title: "February",
                date: utcCalendar.date(
                    from: DateComponents(
                        year: 2026, month: 2, day: 10, hour: 12
                    )
                ) ?? referenceDate
            ),
            makeSummary(
                title: "Last year",
                date: utcCalendar.date(
                    from: DateComponents(
                        year: 2025, month: 11, day: 10, hour: 12
                    )
                ) ?? referenceDate
            )
        ]

        let groups = MeetingListViewModel.groupByDateBuckets(
            meetings, relativeTo: referenceDate, calendar: utcCalendar
        )

        #expect(groups.count == 6)
        #expect(groups[0].id == "today")
        #expect(groups[1].id == "yesterday")
        #expect(groups[2].id == "prev7")
        #expect(groups[3].id == "prev30")
        #expect(groups[4].id == "month-2")
        #expect(groups[5].id == "year-2025")
    }

    @Test("flattened group order equals input order for newest-first input")
    func flattenedOrderEqualsInput() {
        let startOfToday = utcCalendar.startOfDay(for: referenceDate)

        let meetings = [
            makeSummary(
                title: "A",
                date: startOfToday.addingTimeInterval(7200)
            ),
            makeSummary(
                title: "B",
                date: startOfToday.addingTimeInterval(3600)
            ),
            makeSummary(
                title: "C",
                date: startOfToday.addingTimeInterval(-3600)
            ),
            makeSummary(
                title: "D",
                date: startOfToday.addingTimeInterval(-5 * 86400)
            ),
            makeSummary(
                title: "E",
                date: utcCalendar.date(
                    from: DateComponents(
                        year: 2025, month: 6, day: 1, hour: 12
                    )
                ) ?? referenceDate
            )
        ]

        let groups = MeetingListViewModel.groupByDateBuckets(
            meetings, relativeTo: referenceDate, calendar: utcCalendar
        )

        let flattened = groups.flatMap(\.meetings).map(\.id)
        let inputIDs = meetings.map(\.id)
        #expect(flattened == inputIDs)
    }

    @Test("groups property mirrors static function")
    @MainActor
    func groupsPropertyReflectsCore() async throws {
        let fix = try makeCoreFixture(testName: "MeetingListUITests")
        defer { fix.cleanup() }

        _ = try await fix.store.createMeeting(title: "A")
        _ = try await fix.store.createMeeting(title: "B")
        await fix.core.reloadSummaries()

        let listVM = MeetingListViewModel(core: fix.core)
        let grouped = listVM.groups

        let totalMeetings = grouped.reduce(0) { $0 + $1.meetings.count }
        #expect(totalMeetings == 2)
    }
}

import AppCore
import DataStore
import Foundation

/// A group of meetings for sidebar display (Today, Yesterday, etc.).
public struct MeetingGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let meetings: [MeetingSummary]

    public init(id: String, title: String, meetings: [MeetingSummary]) {
        self.id = id
        self.title = title
        self.meetings = meetings
    }
}

/// View model for the sidebar's past-meetings list.
///
/// Reads `AppCore.summaries` and forwards selection to `AppCore.select(_:)`.
/// Provides grouped display of meetings by effective date.
@MainActor @Observable
public final class MeetingListViewModel {
    private let core: AppCore

    /// The meetings to display, newest first.
    public var meetings: [MeetingSummary] {
        core.summaries
    }

    /// Meetings grouped by effective date for sectioned display.
    public var groupedMeetings: [MeetingGroup] {
        Self.groupByEffectiveDate(meetings)
    }

    /// The currently selected meeting ID (derived from the route).
    public var selectedMeetingID: UUID? {
        if case let .meeting(id) = core.route {
            return id
        }
        return nil
    }

    public init(core: AppCore) {
        self.core = core
    }

    /// Called when the user selects a meeting in the list.
    public func select(_ meetingID: UUID) {
        core.select(meetingID)
    }

    // MARK: - Grouping (pure, testable)

    /// Groups meetings into Today / Yesterday / This Week / Earlier
    /// by comparing `meeting.date` against `now`.
    ///
    /// Each group is sorted newest-first. Empty groups are omitted.
    public static func groupByEffectiveDate(
        _ meetings: [MeetingSummary],
        relativeTo now: Date = Date(),
        calendar: Foundation.Calendar = .autoupdatingCurrent
    ) -> [MeetingGroup] {
        var today: [MeetingSummary] = []
        var yesterday: [MeetingSummary] = []
        var thisWeek: [MeetingSummary] = []
        var earlier: [MeetingSummary] = []

        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(
            byAdding: .day, value: -1, to: startOfToday
        ) ?? startOfToday
        let startOfWeek = startOfWeek(for: now, calendar: calendar)

        for meeting in meetings {
            let date = meeting.date
            if date >= startOfToday {
                today.append(meeting)
            } else if date >= startOfYesterday {
                yesterday.append(meeting)
            } else if date >= startOfWeek {
                thisWeek.append(meeting)
            } else {
                earlier.append(meeting)
            }
        }

        var groups: [MeetingGroup] = []
        if !today.isEmpty {
            groups.append(MeetingGroup(
                id: "today", title: "Today",
                meetings: today.sorted { $0.date > $1.date }
            ))
        }
        if !yesterday.isEmpty {
            groups.append(MeetingGroup(
                id: "yesterday", title: "Yesterday",
                meetings: yesterday.sorted { $0.date > $1.date }
            ))
        }
        if !thisWeek.isEmpty {
            groups.append(MeetingGroup(
                id: "thisWeek", title: "This Week",
                meetings: thisWeek.sorted { $0.date > $1.date }
            ))
        }
        if !earlier.isEmpty {
            groups.append(MeetingGroup(
                id: "earlier", title: "Earlier",
                meetings: earlier.sorted { $0.date > $1.date }
            ))
        }
        return groups
    }

    // MARK: - Formatting

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Formats a meeting date as a relative string for sidebar display.
    public static func relativeDate(_ date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Private

    private static func startOfWeek(
        for date: Date,
        calendar: Foundation.Calendar
    ) -> Date {
        let components = calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear],
            from: date
        )
        return calendar.date(from: components) ?? date
    }
}

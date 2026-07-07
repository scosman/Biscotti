import AppCore
import DataStore
import DesignSystem
import Foundation

/// A group of meetings for list display with a section header.
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

/// View model for the Meetings screen's left-bar list.
///
/// Thin presenter over `AppCore`: reads summaries, selection, search
/// state, and forwards list selection back to `AppCore.selectFromList`.
/// The 6-bucket date grouping and mode derivation are pure logic.
@MainActor @Observable
public final class MeetingListViewModel {
    private let core: AppCore

    /// The display mode: browse (grouped) or search (flat results).
    public enum Mode { case browse, search }

    /// The meetings to display, newest first.
    public var meetings: [MeetingSummary] {
        core.summaries
    }

    /// The current display mode based on the search query.
    public var mode: Mode {
        core.meetingsQuery.isEmpty ? .browse : .search
    }

    /// Meetings grouped by date buckets for sectioned display (browse mode).
    public var groups: [MeetingGroup] {
        Self.groupByDateBuckets(meetings)
    }

    /// Search results for search mode.
    public var results: [SearchHit] {
        core.meetingsResults
    }

    /// Whether a search query is currently in flight.
    public var isSearching: Bool {
        core.isSearchingMeetings
    }

    /// The current search query text.
    public var query: String {
        core.meetingsQuery
    }

    /// The currently selected meeting IDs (from AppCore's meetings state).
    public var selectedIDs: Set<UUID> {
        core.meetingsSelection
    }

    /// Whether a delete confirmation alert should be shown.
    public var showDeleteConfirmation = false

    /// The number of meetings that will be deleted (for alert copy).
    public var deleteConfirmationCount = 0

    /// The IDs captured at request time, deleted on confirm. Avoids
    /// TOCTOU: the user confirms exactly the set they were shown.
    private var pendingDeleteIDs: Set<UUID> = []

    public init(core: AppCore) {
        self.core = core
    }

    /// Called when the list selection changes (shift/cmd multi-select).
    /// Uses `selectFromList` to preserve the current search mode.
    public func select(_ ids: Set<UUID>) {
        core.selectFromList(ids)
    }

    /// Triggered by Delete key or the multi-select placeholder's button.
    /// Captures the current selection and shows a confirmation alert.
    public func requestDeleteSelection() {
        requestDelete(selectedIDs)
    }

    /// Triggered by the right-click context menu. The framework passes
    /// the IDs it resolved (respecting Apple's native selection semantics:
    /// right-click on a selected item operates on the whole selection,
    /// right-click on an unselected item operates on just that item).
    public func requestDeleteContextMenu(_ ids: Set<UUID>) {
        requestDelete(ids)
    }

    /// Shared implementation: captures the given IDs and shows the
    /// delete confirmation alert. Guards against empty sets.
    private func requestDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeleteIDs = ids
        deleteConfirmationCount = ids.count
        showDeleteConfirmation = true
    }

    /// The label for a context-menu delete action covering `count` items.
    /// "Delete" for a single item, "Delete N" for multiple.
    public nonisolated static func deleteMenuLabel(for count: Int) -> String {
        count <= 1 ? "Delete" : "Delete \(count)"
    }

    /// Confirms the pending delete. Deletes exactly the IDs that were
    /// captured when `requestDeleteSelection()` was called.
    public func confirmDelete() async {
        showDeleteConfirmation = false
        let ids = pendingDeleteIDs
        pendingDeleteIDs = []
        guard !ids.isEmpty else { return }
        await core.deleteMeetings(ids)
    }

    /// Cancels the pending delete.
    public func cancelDelete() {
        showDeleteConfirmation = false
        pendingDeleteIDs = []
    }

    // MARK: - Grouping (pure, testable)

    /// Groups meetings into 6 date buckets: Today / Yesterday /
    /// Previous 7 Days / Previous 30 Days / `<Month>` / `<Year>`.
    ///
    /// Each meeting falls into the **first** bucket it matches
    /// (evaluated top-down), so buckets never overlap. Empty buckets
    /// are omitted. Within each bucket, meetings retain their input
    /// order (assumed newest-first).
    ///
    /// **Invariant:** the flattened group order equals the input order
    /// when the input is sorted newest-first (which `summaries` always is).
    public nonisolated static func groupByDateBuckets(
        _ meetings: [MeetingSummary],
        relativeTo now: Date = Date(),
        calendar: Foundation.Calendar = .autoupdatingCurrent
    ) -> [MeetingGroup] {
        guard !meetings.isEmpty else { return [] }

        let sorted = partitionIntoBuckets(
            meetings, relativeTo: now, calendar: calendar
        )
        return assembleGroups(from: sorted, calendar: calendar)
    }

    // MARK: - Grouping internals

    /// Date boundaries used to partition meetings into buckets.
    private struct BucketBoundaries {
        let startOfToday: Date
        let startOfYesterday: Date
        let startOf7DaysAgo: Date
        let startOf30DaysAgo: Date
        let currentYear: Int
        let calendar: Foundation.Calendar
    }

    /// The raw partition result before assembly into `MeetingGroup`s.
    private struct BucketPartition {
        var today: [MeetingSummary] = []
        var yesterday: [MeetingSummary] = []
        var prev7: [MeetingSummary] = []
        var prev30: [MeetingSummary] = []
        var monthBuckets: [Int: [MeetingSummary]] = [:]
        var yearBuckets: [Int: [MeetingSummary]] = [:]
    }

    /// Distributes meetings into the first matching bucket.
    private nonisolated static func partitionIntoBuckets(
        _ meetings: [MeetingSummary],
        relativeTo now: Date,
        calendar: Foundation.Calendar
    ) -> BucketPartition {
        let startOfToday = calendar.startOfDay(for: now)
        let bounds = BucketBoundaries(
            startOfToday: startOfToday,
            startOfYesterday: calendar.date(
                byAdding: .day, value: -1, to: startOfToday
            ) ?? startOfToday,
            startOf7DaysAgo: calendar.date(
                byAdding: .day, value: -7, to: startOfToday
            ) ?? startOfToday,
            startOf30DaysAgo: calendar.date(
                byAdding: .day, value: -30, to: startOfToday
            ) ?? startOfToday,
            currentYear: calendar.component(.year, from: now),
            calendar: calendar
        )

        var result = BucketPartition()
        for meeting in meetings {
            assignMeeting(meeting, into: &result, bounds: bounds)
        }
        return result
    }

    /// Places a single meeting into the correct bucket.
    private nonisolated static func assignMeeting(
        _ meeting: MeetingSummary,
        into result: inout BucketPartition,
        bounds: BucketBoundaries
    ) {
        let date = meeting.date
        if date >= bounds.startOfToday {
            result.today.append(meeting)
        } else if date >= bounds.startOfYesterday {
            result.yesterday.append(meeting)
        } else if date >= bounds.startOf7DaysAgo {
            result.prev7.append(meeting)
        } else if date >= bounds.startOf30DaysAgo {
            result.prev30.append(meeting)
        } else {
            let year = bounds.calendar.component(.year, from: date)
            if year == bounds.currentYear {
                let month = bounds.calendar.component(.month, from: date)
                result.monthBuckets[month, default: []].append(meeting)
            } else {
                result.yearBuckets[year, default: []].append(meeting)
            }
        }
    }

    /// Converts a `BucketPartition` into the ordered `[MeetingGroup]` array.
    private nonisolated static func assembleGroups(
        from partition: BucketPartition,
        calendar: Foundation.Calendar
    ) -> [MeetingGroup] {
        var groups: [MeetingGroup] = []

        appendIfNonEmpty(
            &groups, id: "today", title: "Today",
            meetings: partition.today
        )
        appendIfNonEmpty(
            &groups, id: "yesterday", title: "Yesterday",
            meetings: partition.yesterday
        )
        appendIfNonEmpty(
            &groups, id: "prev7", title: "Previous 7 Days",
            meetings: partition.prev7
        )
        appendIfNonEmpty(
            &groups, id: "prev30", title: "Previous 30 Days",
            meetings: partition.prev30
        )

        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        for month in partition.monthBuckets.keys.sorted(by: >) {
            let name = monthFormatter.standaloneMonthSymbols[month - 1]
            appendIfNonEmpty(
                &groups, id: "month-\(month)", title: name,
                meetings: partition.monthBuckets[month] ?? []
            )
        }

        for year in partition.yearBuckets.keys.sorted(by: >) {
            appendIfNonEmpty(
                &groups, id: "year-\(year)", title: "\(year)",
                meetings: partition.yearBuckets[year] ?? []
            )
        }

        return groups
    }

    /// Appends a group only if it contains at least one meeting.
    private nonisolated static func appendIfNonEmpty(
        _ groups: inout [MeetingGroup],
        id: String, title: String,
        meetings: [MeetingSummary]
    ) {
        guard !meetings.isEmpty else { return }
        groups.append(MeetingGroup(
            id: id, title: title, meetings: meetings
        ))
    }

    // MARK: - Formatting

    /// Builds the second-line text for a meeting row.
    /// Format: "Jun 9, 2026 \u{00B7} 34m" (date + middot + duration),
    /// or just "Jun 9, 2026" when no recording duration is available.
    ///
    /// Delegates to `TimeFormatting.meetingSecondLine` so the Home
    /// screen's recent-meetings section produces byte-identical text.
    public nonisolated static func secondLineText(
        for meeting: MeetingSummary
    ) -> String {
        TimeFormatting.meetingSecondLine(
            date: meeting.date,
            duration: meeting.recordingDuration
        )
    }

    /// A human-readable description of which search fields matched.
    public nonisolated static func matchedFieldsText(
        _ fields: [SearchField]
    ) -> String {
        fields.map { field in
            switch field {
            case .title: "title"
            case .people: "people"
            case .transcript: "transcript"
            case .notes: "notes"
            case .tags: "tags"
            }
        }.joined(separator: ", ")
    }
}

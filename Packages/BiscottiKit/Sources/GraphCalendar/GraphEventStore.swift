import Calendar
import Foundation
import Synchronization

/// `EventStoreProviding` for Microsoft 365, served from memory.
///
/// `EventStoreProviding` is synchronous and Graph is not, so the store never
/// makes a request. `GraphCalendarPoller` fills it: a snapshot of every
/// calendar's events in the poll window, plus the events around one past
/// date that the association picker asked for. `CalendarService` then reads
/// it like EventKit, including the enabled-calendar filter.
///
/// `refreshEvent` answers from the same memory, so a snapshot is at most one
/// poll interval old when a meeting is linked to an event.
public final class GraphEventStore: EventStoreProviding {
    /// One successful poll.
    public struct Snapshot: Sendable, Equatable {
        public var calendars: [CalendarInfo]
        public var events: [EKEventDTO]
        /// The interval the events were read for.
        public var window: DateInterval
        public var fetchedAt: Date

        public init(calendars: [CalendarInfo], events: [EKEventDTO], window: DateInterval, fetchedAt: Date) {
            self.calendars = calendars
            self.events = events
            self.window = window
            self.fetchedAt = fetchedAt
        }
    }

    private struct State {
        var access = CalendarAuthStatus.notDetermined
        var snapshot: Snapshot?
        var isStale = false
        /// Events around a date outside the snapshot window, for the picker.
        var nearby: [EKEventDTO] = []
    }

    private let state = Mutex(State())

    public init() {}

    // MARK: - Poller side

    /// The last successful poll, or nil before the first one.
    public var snapshot: Snapshot? {
        state.withLock { $0.snapshot }
    }

    /// Whether the last poll failed, so `snapshot` may be out of date.
    public var isStale: Bool {
        state.withLock { $0.isStale }
    }

    /// `.authorized` while an account is signed in (or needs reconnecting:
    /// its snapshot is still served), `.notDetermined` otherwise.
    public func setAccess(_ access: CalendarAuthStatus) {
        state.withLock { $0.access = access }
    }

    /// Replaces the snapshot and clears the stale flag. Returns whether the
    /// calendars or events differ from the previous snapshot.
    @discardableResult
    public func replace(with snapshot: Snapshot) -> Bool {
        state.withLock { state in
            let changed = state.snapshot?.calendars != snapshot.calendars
                || state.snapshot?.events != snapshot.events
            state.snapshot = snapshot
            state.isStale = false
            return changed
        }
    }

    /// Keeps the snapshot after a failed poll.
    public func markStale() {
        state.withLock { $0.isStale = true }
    }

    /// Replaces the events kept for the association picker.
    public func setNearby(_ events: [EKEventDTO]) {
        state.withLock { $0.nearby = events }
    }

    /// Drops everything read for the account (sign-out or a different
    /// account). Access is left as it is.
    public func clear() {
        state.withLock { state in
            state.snapshot = nil
            state.isStale = false
            state.nearby = []
        }
    }

    // MARK: - EventStoreProviding

    public func authorizationStatus() -> CalendarAuthStatus {
        state.withLock { $0.access }
    }

    /// Microsoft 365 access is granted by signing in, not by a prompt.
    public func requestAccess() async throws -> Bool {
        authorizationStatus() == .authorized
    }

    public func calendars() -> [CalendarInfo] {
        state.withLock { $0.snapshot?.calendars ?? [] }
    }

    /// Events overlapping `interval`, sorted by start then identifier. An
    /// event in both the snapshot and the picker's events is returned once,
    /// from the snapshot.
    public func events(in interval: DateInterval, calendars: [String]?) -> [EKEventDTO] {
        let (snapshotEvents, nearby) = state.withLock { ($0.snapshot?.events ?? [], $0.nearby) }
        let enabled = calendars.map(Set.init)
        var seen = Set<String>()
        var result: [EKEventDTO] = []
        for event in snapshotEvents + nearby {
            guard Self.overlaps(event, interval),
                  enabled?.contains(event.calendarIdentifier) ?? true,
                  seen.insert(event.eventIdentifier).inserted
            else { continue }
            result.append(event)
        }
        return result.sorted { ($0.startDate, $0.eventIdentifier) < ($1.startDate, $1.eventIdentifier) }
    }

    /// The event as of the last poll (or picker fetch), or nil when it is no
    /// longer there. Graph gives each occurrence its own ID, so
    /// `occurrenceStart` only guards against an ID reused for another day.
    public func refreshEvent(eventIdentifier: String, occurrenceStart: Date) -> EKEventDTO? {
        let (snapshotEvents, nearby) = state.withLock { ($0.snapshot?.events ?? [], $0.nearby) }
        return (snapshotEvents + nearby).first {
            $0.eventIdentifier == eventIdentifier && $0.occurrenceDate == occurrenceStart
        }
    }

    /// EventKit's overlap rule: the event ends after the interval starts and
    /// starts before it ends. A zero-length event counts when it starts
    /// inside the interval.
    static func overlaps(_ event: EKEventDTO, _ interval: DateInterval) -> Bool {
        if event.endDate <= event.startDate {
            return event.startDate >= interval.start && event.startDate < interval.end
        }
        return event.startDate < interval.end && event.endDate > interval.start
    }
}

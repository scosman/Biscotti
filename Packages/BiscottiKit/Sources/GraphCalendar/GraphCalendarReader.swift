import Calendar
import Foundation
import MeetingCatalog

/// Reads Microsoft 365 calendars and events as the `Calendar` module's DTOs.
/// The async core a later `EventStoreProviding` adapter wraps; it does no
/// sign-in, caching or merging with EventKit.
public struct GraphCalendarReader: Sendable {
    public let client: GraphClient
    public let catalog: any MeetingCatalog
    public let localTimeZone: TimeZone

    public init(
        client: GraphClient,
        catalog: any MeetingCatalog = BundledMeetingCatalog(),
        localTimeZone: TimeZone = .current
    ) {
        self.client = client
        self.catalog = catalog
        self.localTimeZone = localTimeZone
    }

    /// The signed-in account (`GET /me`).
    public func account() async throws -> GraphAccount {
        try await GraphAccount(user: client.me())
    }

    /// The account's calendars, including shared ones the user added in
    /// Outlook.
    public func calendars(for account: GraphAccount) async throws -> [CalendarInfo] {
        let mapper = mapper(for: account)
        return try await client.calendars().map(mapper.calendarInfo)
    }

    /// Events overlapping `interval` on `calendars`, sorted by start then
    /// identifier. Calendars are read concurrently (the client caps requests
    /// at Graph's per-mailbox limit).
    ///
    /// A calendar Graph refuses (403) or no longer has (404), such as a
    /// revoked share, is logged and skipped; any other error fails the read.
    /// An event that cannot be mapped is logged and skipped.
    public func events(
        in interval: DateInterval,
        calendars: [CalendarInfo],
        account: GraphAccount
    ) async throws -> [EKEventDTO] {
        let mapper = mapper(for: account)
        let client = client
        let events = try await withThrowingTaskGroup(of: [EKEventDTO].self) { group in
            for calendar in calendars {
                group.addTask {
                    let graphEvents: [Graph.Event]
                    do {
                        graphEvents = try await client.calendarView(calendarID: calendar.id, in: interval)
                    } catch let error as GraphError where error.isUnreadableCalendar {
                        graphCalendarLog.error(
                            "Skipping calendar \(calendar.title): \(String(describing: error), privacy: .public)"
                        )
                        return []
                    }
                    return graphEvents.compactMap { event in
                        do {
                            return try mapper.event(event, calendar: calendar)
                        } catch {
                            graphCalendarLog.error(
                                "Skipping event \(event.id): \(String(describing: error), privacy: .public)"
                            )
                            return nil
                        }
                    }
                }
            }
            var all: [EKEventDTO] = []
            for try await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }
        return events.sorted { ($0.startDate, $0.eventIdentifier) < ($1.startDate, $1.eventIdentifier) }
    }

    /// Re-reads one event on `calendar`. Nil when it was deleted. Unlike
    /// `events`, a mapping failure throws, so it is not mistaken for a
    /// deletion.
    public func event(id: String, calendar: CalendarInfo, account: GraphAccount) async throws -> EKEventDTO? {
        guard let event = try await client.event(id: id, calendarID: calendar.id) else { return nil }
        return try mapper(for: account).event(event, calendar: calendar)
    }

    private func mapper(for account: GraphAccount) -> GraphEventMapper {
        GraphEventMapper(account: account, catalog: catalog, localTimeZone: localTimeZone)
    }
}

extension GraphError {
    /// 403 or 404 for a whole calendar: it was unshared or removed.
    var isUnreadableCalendar: Bool {
        switch self {
        case .forbidden: true
        case let .http(status, _, _): status == 404
        default: false
        }
    }
}

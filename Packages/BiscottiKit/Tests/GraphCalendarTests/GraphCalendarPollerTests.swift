import Calendar
import Foundation
import Synchronization
import Testing
@testable import GraphCalendar

/// `GraphCalendarPoller` over the fake transport: filling the store,
/// failures, shared and superseded polls, the next poll's timing, the
/// picker's on-demand read, and the loop.
@Suite("GraphCalendarPoller")
struct GraphCalendarPollerTests {
    /// Noon on the fixtures' first day.
    private static let now = testWeek.start.addingTimeInterval(12 * 3600)

    private final class Harness: Sendable {
        let transport: FakeGraphTransport
        let store = GraphEventStore()
        let poller: GraphCalendarPoller
        let outcomes = Mutex<[GraphSyncOutcome]>([])

        init(
            transport: FakeGraphTransport = FakeGraphTransport(),
            now: Date = GraphCalendarPollerTests.now,
            sleep: @escaping GraphCalendarPoller.Sleeper = { _ in throw CancellationError() }
        ) throws {
            self.transport = transport
            let reader = try GraphCalendarReader(client: makeClient(transport), localTimeZone: zone("America/Los_Angeles"))
            poller = GraphCalendarPoller(reader: reader, store: store, now: { now }, sleep: sleep)
        }

        func recordOutcomes() async {
            await poller.setOutcomeHandler { [self] outcome in outcomes.withLock { $0.append(outcome) } }
        }

        /// `/me`, the four fixture calendars, and their events: `own` in
        /// turn on the own calendar, nothing on Project X, and the two
        /// shared calendars unreadable.
        func stubTenant(own: [String] = ["calendarView_week"]) async throws {
            try await transport.stub("/v1.0/me", .fixture("me"))
            try await transport.stub("/v1.0/me/calendars", .fixture("calendars"))
            for name in own {
                try await transport.stub("/v1.0/me/calendars/cal-own/calendarView", .fixture(name))
            }
            try await transport.stub("/v1.0/me/calendars/cal-project/calendarView", .fixture("calendarView_empty"))
            try await transport.stub("/v1.0/me/calendars/cal-shared/calendarView", .fixture("error_403", status: 403))
            try await transport.stub("/v1.0/me/calendars/cal-partner/calendarView", .fixture("error_404", status: 404))
        }
    }

    @Test("a poll reads every calendar over the window into the store")
    func pollFillsStore() async throws {
        let harness = try Harness()
        try await harness.stubTenant()
        await harness.recordOutcomes()

        #expect(await harness.poller.refresh() == .synced(changed: true))
        let snapshot = try #require(harness.store.snapshot)
        #expect(snapshot.calendars.map(\.id) == ["cal-own", "cal-project", "cal-shared", "cal-partner"])
        #expect(snapshot.events.map(\.eventIdentifier).contains("evt-teams"))
        #expect(snapshot.fetchedAt == Self.now)
        #expect(snapshot.window == DateInterval(
            start: Self.now.addingTimeInterval(-GraphCalendarPoller.lookBehind),
            end: Self.now.addingTimeInterval(GraphCalendarPoller.lookAhead)
        ))
        let query = try query(#require(await harness.transport.requests(to: "/v1.0/me/calendars/cal-own/calendarView").first))
        #expect(query["startDateTime"] == GraphClient.isoString(snapshot.window.start))
        #expect(query["endDateTime"] == GraphClient.isoString(snapshot.window.end))

        // The same calendars and events again are not a change; /me is
        // read once.
        #expect(await harness.poller.refresh() == .synced(changed: false))
        #expect(await harness.transport.requests(to: "/v1.0/me").count == 1)
        #expect(harness.outcomes.withLock { $0 } == [.synced(changed: true), .synced(changed: false)])
    }

    @Test("a failed poll keeps the snapshot and marks it stale")
    func failureKeepsSnapshot() async throws {
        let harness = try Harness()
        try await harness.stubTenant()
        await harness.poller.refresh()
        await harness.transport.failAll(with: URLError(.notConnectedToInternet))

        let outcome = await harness.poller.refresh()

        guard case .failed(.transport) = outcome else {
            Issue.record("expected a transport failure, got \(outcome)")
            return
        }
        #expect(harness.store.isStale)
        #expect(harness.store.snapshot?.events.isEmpty == false)
    }

    @Test("concurrent refreshes share one poll")
    func sharedPoll() async throws {
        let harness = try Harness()
        try await harness.stubTenant()
        await harness.transport.hold()

        async let first = harness.poller.refresh()
        await harness.transport.waitForRequests(1)
        async let second = harness.poller.refresh()
        // Let the second refresh reach the poller before the first ends.
        try await Task.sleep(for: .milliseconds(50))
        await harness.transport.release()

        #expect(await first == .synced(changed: true))
        #expect(await second == .synced(changed: true))
        #expect(await harness.transport.requests(to: "/v1.0/me").count == 1)
        #expect(await harness.transport.requests(to: "/v1.0/me/calendars").count == 1)
    }

    @Test("reset drops the store, and a poll still running leaves it alone")
    func resetSupersedesPoll() async throws {
        let harness = try Harness()
        try await harness.stubTenant()
        await harness.poller.refresh()
        await harness.recordOutcomes()
        await harness.transport.hold()

        let requestsBefore = await harness.transport.requests.count
        let poll = Task { await harness.poller.refresh() }
        await harness.transport.waitForRequests(requestsBefore + 1)
        await harness.poller.reset()
        #expect(harness.store.snapshot == nil)
        await harness.transport.release()

        #expect(await poll.value == .superseded)
        #expect(harness.store.snapshot == nil)
        #expect(harness.outcomes.withLock { $0 }.isEmpty)

        // The next poll reads /me again: the account may have changed.
        #expect(await harness.poller.refresh() == .synced(changed: true))
        #expect(await harness.transport.requests(to: "/v1.0/me").count == 2)
    }

    @Test("the next poll is a minute before the next timed event, within limits")
    func nextPollDelay() async throws {
        let harness = try Harness()
        let now = Self.now
        func delay(_ events: [EKEventDTO]) async -> TimeInterval {
            harness.store.replace(with: .init(
                calendars: [TestAccount.ownCalendar],
                events: events,
                window: DateInterval(start: now, duration: 3600),
                fetchedAt: now
            ))
            return await harness.poller.nextPollDelay()
        }
        func event(_ id: String, startsIn minutes: Double, allDay: Bool = false) -> EKEventDTO {
            let start = now.addingTimeInterval(minutes * 60)
            return dto(id, start: start, end: start.addingTimeInterval(1800), isAllDay: allDay)
        }

        #expect(await delay([]) == GraphCalendarPoller.pollInterval)
        #expect(await delay([event("later", startsIn: 4), event("next", startsIn: 3)]) == 2 * 60)
        #expect(await delay([event("soon", startsIn: 1.1)]) == GraphCalendarPoller.minimumInterval)
        #expect(await delay([event("far", startsIn: 60)]) == GraphCalendarPoller.pollInterval)
        // Started and all-day events have no prompt to poll for.
        #expect(await delay([event("started", startsIn: -5), event("allday", startsIn: 3, allDay: true)])
            == GraphCalendarPoller.pollInterval)
    }

    @Test("the picker's read skips a fresh snapshot that covers the date")
    func loadNearbyCovered() async throws {
        let harness = try Harness()
        try await harness.stubTenant()
        await harness.poller.refresh()
        let requests = await harness.transport.requests.count

        await harness.poller.loadNearby(around: Self.now.addingTimeInterval(3600))

        #expect(await harness.transport.requests.count == requests)
    }

    @Test("the picker's read fetches ±1.5 h around an older date")
    func loadNearbyOlderDate() async throws {
        // A week after the fixtures: the poll finds nothing, the picker's
        // read finds the fixtures' week.
        let harness = try Harness(now: Self.now.addingTimeInterval(7 * 24 * 3600))
        try await harness.stubTenant(own: ["calendarView_empty", "calendarView_week"])
        await harness.poller.refresh()
        let date = try instant("2026-10-27T16:30:00Z")
        let window = DateInterval(
            start: date.addingTimeInterval(-GraphCalendarPoller.nearbyRadius),
            end: date.addingTimeInterval(GraphCalendarPoller.nearbyRadius)
        )

        await harness.poller.loadNearby(around: date)

        let lastRead = try #require(await harness.transport.requests(to: "/v1.0/me/calendars/cal-own/calendarView").last)
        #expect(try query(lastRead)["startDateTime"] == GraphClient.isoString(window.start))
        // The snapshot's calendars are reused.
        #expect(await harness.transport.requests(to: "/v1.0/me/calendars").count == 1)
        #expect(harness.store.events(in: window, calendars: nil).map(\.eventIdentifier).contains("evt-teams"))
    }

    @Test("the loop polls, then sleeps until the next poll")
    func loop() async throws {
        let (sleeps, continuation) = AsyncStream.makeStream(of: Duration.self)
        let harness = try Harness { duration in
            continuation.yield(duration)
            throw CancellationError()
        }
        try await harness.stubTenant()

        await harness.poller.start()
        var iterator = sleeps.makeAsyncIterator()
        let sleep = await iterator.next()

        #expect(harness.store.snapshot != nil)
        // The fixtures' first meeting is the next day.
        #expect(sleep == .seconds(GraphCalendarPoller.pollInterval))
    }
}

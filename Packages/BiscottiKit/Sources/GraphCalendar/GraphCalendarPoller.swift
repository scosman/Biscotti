import Calendar
import Foundation

/// The result of one poll, reported to the poller's `onOutcome`.
public enum GraphSyncOutcome: Sendable, Equatable {
    /// The snapshot was replaced. `changed` is false when the calendars and
    /// events matched the previous snapshot.
    case synced(changed: Bool)
    /// The poll failed. The previous snapshot is kept and marked stale.
    case failed(GraphError)
    /// A `reset()` (sign-out or another account) superseded the poll, so its
    /// result was dropped.
    case superseded
}

/// Fills a `GraphEventStore` from `GraphCalendarReader`.
///
/// Polls every 5 minutes while started, and one minute before each timed
/// event so the meeting prompt sees late changes. Concurrent `refresh()`
/// calls share one poll. A poll reads every calendar (the enabled-calendar
/// filter is applied when `CalendarService` queries the store) over the
/// last day and the next 8 days, which covers `CalendarService`'s 7-day
/// upcoming window and the picker's ±1.5 h around a recent recording.
public actor GraphCalendarPoller {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void
    public typealias OutcomeHandler = @Sendable (GraphSyncOutcome) async -> Void

    /// Time between polls when no meeting is about to start.
    public static let pollInterval: TimeInterval = 5 * 60
    /// How long before a timed event starts a poll runs.
    public static let preMeetingLead: TimeInterval = 60
    /// The shortest wait between polls.
    public static let minimumInterval: TimeInterval = 15
    public static let lookBehind: TimeInterval = 24 * 60 * 60
    public static let lookAhead: TimeInterval = 8 * 24 * 60 * 60
    /// The picker's window around a recording's start, as
    /// `CalendarService.eventsNear`.
    public static let nearbyRadius: TimeInterval = 1.5 * 60 * 60

    private let reader: GraphCalendarReader
    private let store: GraphEventStore
    private let now: @Sendable () -> Date
    private let sleep: Sleeper
    private var onOutcome: OutcomeHandler?

    /// Bumped by `reset()`. A poll from an older generation drops its result.
    private var generation = 0
    private var account: GraphAccount?
    private var inFlight: Task<GraphSyncOutcome, Never>?
    private var loop: Task<Void, Never>?

    public init(
        reader: GraphCalendarReader,
        store: GraphEventStore,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.reader = reader
        self.store = store
        self.now = now
        self.sleep = sleep
    }

    /// Called after every poll that ran, from the poller's executor.
    public func setOutcomeHandler(_ handler: OutcomeHandler?) {
        onOutcome = handler
    }

    /// Whether the poll loop is running.
    public var isStarted: Bool {
        loop != nil
    }

    /// Starts the loop with an immediate poll, or restarts it (after wake
    /// or a network change) so the next poll runs now. A `refresh()` after
    /// `start()` returns joins that poll.
    public func start() {
        loop?.cancel()
        let first = beginPoll()
        loop = Task { [weak self] in
            _ = await first.value
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await nextPollDelay()
                do {
                    try await sleep(.seconds(delay))
                } catch {
                    return
                }
                await refresh()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Stops the loop and forgets the account and its events. A poll still
    /// running finishes without touching the store.
    public func reset() {
        stop()
        generation += 1
        account = nil
        inFlight = nil
        store.clear()
    }

    /// Polls now, or joins the poll already running.
    @discardableResult
    public func refresh() async -> GraphSyncOutcome {
        await beginPoll().value
    }

    /// Reads the events around `date` for the association picker when the
    /// snapshot doesn't cover them. Failures are logged; the picker then
    /// shows what the snapshot has.
    public func loadNearby(around date: Date) async {
        let window = DateInterval(
            start: date.addingTimeInterval(-Self.nearbyRadius),
            end: date.addingTimeInterval(Self.nearbyRadius)
        )
        if let snapshot = store.snapshot, !store.isStale,
           snapshot.window.start <= window.start, window.end <= snapshot.window.end
        {
            return
        }
        let generation = generation
        do {
            let account = try await currentAccount(generation: generation)
            var calendars = store.calendars()
            if calendars.isEmpty {
                calendars = try await reader.calendars(for: account)
            }
            let events = try await reader.events(in: window, calendars: calendars, account: account)
            guard generation == self.generation else { return }
            store.setNearby(events)
        } catch {
            graphCalendarLog.error("Reading events near a recording failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Seconds until the next poll: the poll interval, or sooner when a
    /// timed event starts within it.
    func nextPollDelay() -> TimeInterval {
        let now = now()
        let promptTimes = (store.snapshot?.events ?? [])
            .lazy
            .filter { !$0.isAllDay }
            .map { $0.startDate.addingTimeInterval(-Self.preMeetingLead) }
            .filter { $0 > now }
        guard let next = promptTimes.min() else { return Self.pollInterval }
        return min(Self.pollInterval, max(Self.minimumInterval, next.timeIntervalSince(now)))
    }

    // MARK: - Private

    /// The poll already running, or a new one.
    private func beginPoll() -> Task<GraphSyncOutcome, Never> {
        if let inFlight {
            return inFlight
        }
        let generation = generation
        let task = Task { await self.poll(generation: generation) }
        inFlight = task
        return task
    }

    private func poll(generation: Int) async -> GraphSyncOutcome {
        defer {
            // After a reset, `inFlight` is the new generation's poll.
            if generation == self.generation {
                inFlight = nil
            }
        }
        let fetchedAt = now()
        let window = DateInterval(
            start: fetchedAt.addingTimeInterval(-Self.lookBehind),
            end: fetchedAt.addingTimeInterval(Self.lookAhead)
        )
        let outcome: GraphSyncOutcome
        do {
            let account = try await currentAccount(generation: generation)
            let calendars = try await reader.calendars(for: account)
            let events = try await reader.events(in: window, calendars: calendars, account: account)
            guard generation == self.generation else { return .superseded }
            let changed = store.replace(with: .init(
                calendars: calendars,
                events: events,
                window: window,
                fetchedAt: fetchedAt
            ))
            graphCalendarLog.info(
                "Read \(events.count) events from \(calendars.count) calendars (changed: \(changed))"
            )
            outcome = .synced(changed: changed)
        } catch {
            guard generation == self.generation else { return .superseded }
            store.markStale()
            let graphError = error as? GraphError ?? .transport(String(describing: error))
            graphCalendarLog.error("Calendar poll failed: \(String(describing: graphError), privacy: .public)")
            outcome = .failed(graphError)
        }
        await onOutcome?(outcome)
        return outcome
    }

    /// `/me`, read once per generation.
    private func currentAccount(generation: Int) async throws -> GraphAccount {
        if let account {
            return account
        }
        let account = try await reader.account()
        if generation == self.generation {
            self.account = account
        }
        return account
    }
}

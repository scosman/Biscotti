import AppKit
import Calendar
import DataStore
import Foundation
import GraphAuth
import GraphCalendar
import MeetingCatalog
import Network
import Observation
import os

/// Feeds Microsoft 365 calendars into `CalendarService` (Synderys fork,
/// o365_calendar Phase 3).
///
/// Owns the `GraphEventStore` that `AppCore+Live` gives `CalendarService` as
/// its provider, and the poller that fills it. Follows the account:
/// - signed in: the store reports `.authorized` and the poller runs;
/// - sign-in expired: polling stops and the last snapshot stays;
/// - signed out: the snapshot is dropped and access reverts.
///
/// Each change posts `.calendarProviderDidChange`, so `CalendarService`
/// refreshes `upcoming` and `auth`.
@MainActor @Observable
public final class Microsoft365CalendarSync {
    /// The provider `CalendarService` reads.
    public let store: GraphEventStore
    /// When the last successful poll read the calendars.
    public private(set) var lastSynced: Date?
    /// The last poll's failure, cleared by the next success.
    public private(set) var lastSyncFailure: GraphError?

    /// User-defaults key for the account `enabledCalendarIDs` was last
    /// chosen for. Another account's (or EventKit's) calendar IDs would
    /// filter out every Graph calendar, so the selection is cleared when the
    /// account changes.
    static let selectionAccountKey = "microsoft365CalendarSelectionAccount"

    /// How long the association picker waits for events around an older
    /// recording before showing what the snapshot has.
    @ObservationIgnored var prepareTimeout: Duration = .seconds(5)

    @ObservationIgnored private let account: GraphAccountController
    @ObservationIgnored private let poller: GraphCalendarPoller
    @ObservationIgnored private let dataStore: DataStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(subsystem: "net.scosman.biscotti", category: "AppCore")

    /// The account the store holds events for.
    @ObservationIgnored private var activeAccountID: String?
    @ObservationIgnored private var appliedState: GraphAccountState?
    @ObservationIgnored private var hasStarted = false
    /// Account transitions run in order; each waits for the previous one.
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkSatisfied: Bool?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    public init(
        account: GraphAccountController,
        dataStore: DataStore,
        transport: any GraphHTTPTransport = URLSessionGraphTransport(),
        catalog: any MeetingCatalog = BundledMeetingCatalog(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping GraphCalendarPoller.Sleeper = { try await Task.sleep(for: $0) }
    ) {
        let store = GraphEventStore()
        let reader = GraphCalendarReader(
            client: GraphClient(tokens: account.tokens, transport: transport),
            catalog: catalog
        )
        self.store = store
        self.account = account
        self.dataStore = dataStore
        self.defaults = defaults
        poller = GraphCalendarPoller(reader: reader, store: store, now: now, sleep: sleep)
    }

    /// Starts following the account. With `observeSystem`, also polls again
    /// after wake and when the network comes back. Runs once.
    public func start(observeSystem: Bool = true) async {
        guard !hasStarted else { return }
        hasStarted = true
        await poller.setOutcomeHandler { [weak self] outcome in
            await self?.handle(outcome)
        }
        observeAccount()
        if observeSystem {
            observeWakeAndNetwork()
        }
    }

    /// Polls now and waits for it (or the poll already running). Nothing
    /// happens unless an account is signed in.
    public func refresh() async {
        // A sign-in that just finished may not have reached the observer.
        if hasStarted {
            accountStateChanged(account.state)
        }
        await transition?.value
        guard account.state.isSignedIn else { return }
        await poller.refresh()
    }

    /// Makes the events around `date` available to
    /// `CalendarService.eventsNear` when they are older than the snapshot.
    /// Gives up after `prepareTimeout`.
    public func prepare(around date: Date) async {
        guard store.authorizationStatus() == .authorized else { return }
        let poller = poller
        let timeout = prepareTimeout
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await poller.loadNearby(around: date) }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    /// The failure in words for Settings, or nil. An expired sign-in shows
    /// as "Reconnect" on the row instead.
    public var syncErrorMessage: String? {
        switch lastSyncFailure {
        case nil, .unauthorized:
            nil
        case .transport:
            "Couldn't reach Microsoft 365. Showing meetings from the last sync."
        case .throttled:
            "Microsoft 365 is busy. Biscotti will try again shortly."
        case let .forbidden(_, message), let .http(_, _, message):
            "Couldn't read your calendars" + (message.map { ": \($0)" } ?? ".")
        case .invalidRequest, .invalidResponse, .decoding, .untrustedNextLink:
            "Couldn't read your calendars. Showing meetings from the last sync."
        }
    }

    // MARK: - Account

    private func observeAccount() {
        let state = withObservationTracking {
            account.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAccount()
            }
        }
        accountStateChanged(state)
    }

    private func accountStateChanged(_ state: GraphAccountState) {
        guard state != appliedState else { return }
        appliedState = state
        switch state {
        case let .signedIn(user):
            let isNewAccount = adopt(user)
            enqueue { [self] in
                if isNewAccount {
                    await switchAccount(to: user)
                }
                await poller.start()
            }
        case let .needsReconnect(user):
            // Nothing can be read until the user signs in again; the last
            // snapshot keeps the upcoming list.
            let isNewAccount = adopt(user)
            enqueue { [self] in
                if isNewAccount {
                    await switchAccount(to: user)
                }
                await poller.stop()
            }
        case .signingIn:
            break
        case .signedOut, .notConfigured:
            guard activeAccountID != nil else { return }
            activeAccountID = nil
            enqueue { [self] in
                await poller.reset()
                store.setAccess(.notDetermined)
                lastSynced = nil
                lastSyncFailure = nil
                NotificationCenter.default.post(name: .calendarProviderDidChange, object: nil)
            }
        }
    }

    /// Records `user` as the active account. Returns whether it differs
    /// from the previous one.
    private func adopt(_ user: Microsoft365Account) -> Bool {
        defer { activeAccountID = user.objectID }
        return activeAccountID != user.objectID
    }

    /// Drops the previous account's events and calendar selection, then
    /// serves (empty) data for `user` until the first poll.
    private func switchAccount(to user: Microsoft365Account) async {
        await poller.reset()
        lastSynced = nil
        lastSyncFailure = nil
        if defaults.string(forKey: Self.selectionAccountKey) != user.objectID {
            do {
                try await dataStore.updateSettings { $0.enabledCalendarIDs = nil }
                defaults.set(user.objectID, forKey: Self.selectionAccountKey)
            } catch {
                logger.error("Couldn't reset the calendar selection: \(error)")
            }
        }
        store.setAccess(.authorized)
        NotificationCenter.default.post(name: .calendarProviderDidChange, object: nil)
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = transition
        transition = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    // MARK: - Polls

    private func handle(_ outcome: GraphSyncOutcome) {
        switch outcome {
        case let .synced(changed):
            lastSynced = store.snapshot?.fetchedAt
            lastSyncFailure = nil
            if changed {
                NotificationCenter.default.post(name: .calendarProviderDidChange, object: nil)
            }
        case let .failed(error):
            lastSyncFailure = error
        case .superseded:
            break
        }
    }

    /// Restarts a running poll loop so the next poll is now.
    private func pollNow() {
        let poller = poller
        Task {
            if await poller.isStarted {
                await poller.start()
            }
        }
    }

    private func observeWakeAndNetwork() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollNow()
            }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.networkChanged(satisfied: satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "net.scosman.biscotti.graph-network"))
        pathMonitor = monitor
    }

    /// Polls when the network comes back. The first report only records
    /// the starting state.
    private func networkChanged(satisfied: Bool) {
        defer { networkSatisfied = satisfied }
        if satisfied, networkSatisfied == false {
            pollNow()
        }
    }
}

// MARK: - Launch

extension AppCore {
    /// Restores the Microsoft 365 account and starts following it.
    func startMicrosoft365() async {
        // Not awaited: reading the keychain can wait on an access prompt,
        // and the launch check refreshes over the network.
        Task { await microsoft365.restore() }
        await microsoft365Calendar?.start()
    }
}

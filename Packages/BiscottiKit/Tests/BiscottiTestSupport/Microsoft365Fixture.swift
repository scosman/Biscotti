import AppCore
import DataStore
import Foundation
import GraphAuth
import GraphCalendar

/// A configured Microsoft 365 account controller for UI tests: a made-up
/// registration, an in-memory session store, a scripted browser, and by
/// default no network (every token request fails as offline, which keeps
/// the session). Pass `controller` to `makeCoreFixture(microsoft365:)`,
/// and for calendars a `StubGraphTenant` as `transport` and
/// `makeCalendarSync` to `makeCoreFixture(microsoft365Calendar:)`.
@MainActor
public struct Microsoft365Fixture {
    public nonisolated static let clientID = "11111111-2222-3333-4444-555555555555"
    public nonisolated static let tenantID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    public nonisolated static let account = Microsoft365Account(
        username: "jane@synderys.com",
        displayName: "Jane Doe",
        objectID: "00000000-0000-0000-0000-00000000000a",
        tenantID: tenantID
    )

    public let controller: GraphAccountController
    public let store: InMemoryGraphTokenStore
    public let browser: ScriptedWebSession

    /// A saved session for `account`. A nil refresh token is an account
    /// that needs reconnecting.
    public static func session(refreshToken: String? = "rt-1") -> GraphStoredSession {
        GraphStoredSession(account: account, refreshToken: refreshToken, clientID: clientID)
    }

    public init(session: GraphStoredSession? = nil, transport: (any GraphHTTPTransport)? = nil) throws {
        store = InMemoryGraphTokenStore(session: session)
        browser = ScriptedWebSession()
        controller = try GraphAccountController(
            configuration: GraphAuthConfiguration(clientID: Self.clientID, tenant: Self.tenantID),
            store: store,
            transport: transport ?? OfflineGraphTransport(),
            webSession: browser
        )
    }

    /// The calendar sync for `controller`, reading Graph through
    /// `transport`. The poll loop waits a day between polls, so tests poll
    /// with `refresh()`. The selection key is kept in `defaults`, a
    /// throwaway suite unless a test shares one.
    public func makeCalendarSync(
        dataStore: DataStore,
        transport: any GraphHTTPTransport,
        defaults: UserDefaults = Microsoft365Fixture.scratchDefaults(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> Microsoft365CalendarSync {
        Microsoft365CalendarSync(
            account: controller,
            dataStore: dataStore,
            transport: transport,
            defaults: defaults,
            now: now,
            sleep: { _ in try await Task.sleep(for: .seconds(86400)) }
        )
    }

    /// An empty user-defaults suite of its own.
    public static func scratchDefaults() -> UserDefaults {
        let name = "BiscottiTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("couldn't create defaults suite \(name)")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

/// A browser that returns `result` for every sign-in.
@MainActor
public final class ScriptedWebSession: WebAuthenticationSessionRunning {
    public var result: Result<URL, GraphAuthError> = .failure(.cancelled)
    public private(set) var openedURLs: [URL] = []
    public private(set) var cancelCount = 0

    public init() {}

    public func authenticate(url: URL, callbackScheme _: String) async throws(GraphAuthError) -> URL {
        openedURLs.append(url)
        return try result.get()
    }

    public func cancel() {
        cancelCount += 1
    }
}

/// Fails every request as offline.
private struct OfflineGraphTransport: GraphHTTPTransport {
    func send(_: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// A core whose Microsoft 365 account is signed in to an in-memory tenant,
/// with the calendar sync started (no wake or network observers) and its
/// first poll done.
@MainActor
public struct Microsoft365CalendarHarness {
    public let tenant: StubGraphTenant
    public let account: Microsoft365Fixture
    public let fix: CoreFixture
    public let sync: Microsoft365CalendarSync

    /// `prepare` runs on the fixture's store before the account signs in.
    public init(
        tenant: StubGraphTenant = StubGraphTenant(),
        defaults: UserDefaults = Microsoft365Fixture.scratchDefaults(),
        testName: String = "Test",
        prepare: (DataStore) async throws -> Void = { _ in }
    ) async throws {
        let account = try Microsoft365Fixture(session: Microsoft365Fixture.session(), transport: tenant)
        let fix = try makeCoreFixture(
            microsoft365: account.controller,
            microsoft365Calendar: { account.makeCalendarSync(dataStore: $0, transport: tenant, defaults: defaults) },
            testName: testName
        )
        try await prepare(fix.store)
        guard let sync = fix.microsoft365Calendar else {
            preconditionFailure("makeCoreFixture didn't build the calendar sync")
        }
        await sync.start(observeSystem: false)
        await account.controller.restore()
        await sync.refresh()
        self.tenant = tenant
        self.account = account
        self.fix = fix
        self.sync = sync
    }
}

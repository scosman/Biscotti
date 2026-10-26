import Foundation
import GraphCalendar
import Testing
@testable import GraphAuth

/// The account state the UI renders, end to end through a fake browser and
/// a fake token endpoint.
@MainActor
@Suite("GraphAccountController")
struct GraphAccountControllerTests {
    private static func controller(
        _ transport: FakeTokenTransport,
        store: InMemoryGraphTokenStore = InMemoryGraphTokenStore(),
        webSession: FakeWebSession = FakeWebSession()
    ) throws -> GraphAccountController {
        try GraphAccountController(
            configuration: TestRegistration.configuration(),
            store: store,
            transport: transport,
            webSession: webSession
        )
    }

    /// A browser that approves the sign-in and queues the token response
    /// Entra would send for that request's nonce.
    private static func approvingWebSession(
        _ transport: FakeTokenTransport,
        refresh: String = "rt-1"
    ) -> FakeWebSession {
        FakeWebSession { url in
            let nonce = queryItems(url)["nonce"]
            await transport.enqueue(.tokens(
                access: "at-1", refresh: refresh, idToken: makeIDToken(janeClaims(nonce: nonce))
            ))
            return FakeWebSession.approve(url)
        }
    }

    /// Waits for the provider's invalidation report to reach the main actor.
    private static func settle(until condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Not configured

    @Test("without a registration nothing happens and tokens are unauthorized")
    func notConfigured() async {
        let controller = GraphAccountController(notConfigured: .missingClientID)
        await controller.restore()
        await controller.signIn()
        await controller.signOut()
        #expect(controller.state == .notConfigured(.missingClientID))
        #expect(!controller.isConfigured)
        await #expect(throws: GraphError.unauthorized) {
            try await controller.tokens.accessToken(forceRefresh: false)
        }
    }

    // MARK: - Restore

    @Test("restore with nothing saved stays signed out")
    func restoreEmpty() async throws {
        let transport = FakeTokenTransport()
        let controller = try Self.controller(transport)
        await controller.restore()
        #expect(controller.state == .signedOut)
        #expect(controller.isConfigured)
        #expect(await transport.requests.isEmpty)
    }

    @Test("restore signs in the saved account and checks its token once")
    func restoreSession() async throws {
        let transport = FakeTokenTransport(.tokens(access: "at-1"))
        let store = InMemoryGraphTokenStore(session: TestRegistration.session())
        let controller = try Self.controller(transport, store: store)

        await controller.restore()
        await controller.restore()
        #expect(controller.state == .signedIn(TestRegistration.jane))
        #expect(controller.lastError == nil)
        #expect(await transport.requests.count == 1)
        #expect(try await controller.tokens.accessToken(forceRefresh: false) == "at-1")
    }

    @Test("restore offline keeps the account signed in")
    func restoreOffline() async throws {
        let transport = FakeTokenTransport(.failure(URLError(.notConnectedToInternet)))
        let store = InMemoryGraphTokenStore(session: TestRegistration.session())
        let controller = try Self.controller(transport, store: store)

        await controller.restore()
        #expect(controller.state == .signedIn(TestRegistration.jane))
        #expect(controller.lastError == nil)
        #expect(store.stored == TestRegistration.session())
    }

    @Test("restore with a refused refresh token asks to reconnect")
    func restoreRefused() async throws {
        let transport = FakeTokenTransport(.oauthError("invalid_grant", description: "AADSTS70043: expired"))
        let store = InMemoryGraphTokenStore(session: TestRegistration.session())
        let controller = try Self.controller(transport, store: store)

        await controller.restore()
        try await Self.settle { controller.state != .signedIn(TestRegistration.jane) }
        #expect(controller.state == .needsReconnect(TestRegistration.jane))
        #expect(controller.lastError == "Microsoft 365 needs you to sign in again: AADSTS70043: expired")
    }

    @Test("a saved reconnect state is shown without a network request")
    func restoreNeedsReconnect() async throws {
        let transport = FakeTokenTransport()
        let store = InMemoryGraphTokenStore(session: TestRegistration.session(refreshToken: nil))
        let controller = try Self.controller(transport, store: store)

        await controller.restore()
        #expect(controller.state == .needsReconnect(TestRegistration.jane))
        #expect(await transport.requests.isEmpty)
    }

    // MARK: - Sign-in

    @Test("signing in redeems the code with the matching verifier")
    func signIn() async throws {
        let transport = FakeTokenTransport()
        let store = InMemoryGraphTokenStore()
        let webSession = Self.approvingWebSession(transport)
        let controller = try Self.controller(transport, store: store, webSession: webSession)
        let approve = webSession.respond
        let seen = StateRecorder()
        webSession.respond = { url in
            seen.states.append(controller.state)
            return await approve(url)
        }

        await controller.signIn()

        #expect(seen.states == [.signingIn])
        #expect(controller.state == .signedIn(TestRegistration.jane))
        #expect(controller.lastError == nil)
        #expect(store.stored == TestRegistration.session())
        let authorize = try #require(webSession.openedURLs.first)
        #expect(queryItems(authorize)["prompt"] == "select_account")
        let redeem = try #require(await transport.requests.first)
        let body = try form(redeem)
        #expect(body["code"] == "auth-code")
        let verifier = try #require(body["code_verifier"])
        #expect(PKCE(verifier: verifier).challenge == queryItems(authorize)["code_challenge"])
        // The sign-in's own access token is used; no extra refresh.
        #expect(try await controller.tokens.accessToken(forceRefresh: false) == "at-1")
        #expect(await transport.requests.count == 1)
    }

    @Test("cancelling the browser returns to the previous state quietly")
    func signInCancelled() async throws {
        let transport = FakeTokenTransport()
        let webSession = FakeWebSession { _ in .failure(.cancelled) }
        let controller = try Self.controller(transport, webSession: webSession)

        await controller.signIn()
        #expect(controller.state == .signedOut)
        #expect(controller.lastError == nil)
        #expect(await transport.requests.isEmpty)

        controller.cancelSignIn()
        #expect(webSession.cancelCount == 1)
    }

    @Test("a declined consent shows Entra's reason")
    func signInDenied() async throws {
        let transport = FakeTokenTransport()
        let webSession = FakeWebSession { _ in
            .success(URL(string: "msauth.com.synderys.biscotti://auth?error=access_denied&error_description=AADSTS65004%3a+User+declined")
                ?? URL(fileURLWithPath: "/"))
        }
        let controller = try Self.controller(transport, webSession: webSession)

        await controller.signIn()
        #expect(controller.state == .signedOut)
        #expect(controller.lastError == "Microsoft sign-in didn't complete: AADSTS65004: User declined")
    }

    @Test("reconnecting pre-fills the account and signs it back in")
    func reconnect() async throws {
        let transport = FakeTokenTransport()
        let store = InMemoryGraphTokenStore(session: TestRegistration.session(refreshToken: nil))
        let webSession = Self.approvingWebSession(transport, refresh: "rt-new")
        let controller = try Self.controller(transport, store: store, webSession: webSession)

        await controller.restore()
        #expect(controller.state == .needsReconnect(TestRegistration.jane))
        await controller.signIn()

        #expect(controller.state == .signedIn(TestRegistration.jane))
        #expect(store.stored?.refreshToken == "rt-new")
        let authorize = try #require(webSession.openedURLs.first)
        #expect(queryItems(authorize)["login_hint"] == "jane@synderys.com")
    }

    // MARK: - Sign-out and invalidation

    @Test("signing out forgets the account")
    func signOut() async throws {
        let transport = FakeTokenTransport(.tokens(access: "at-1"))
        let store = InMemoryGraphTokenStore(session: TestRegistration.session())
        let controller = try Self.controller(transport, store: store)
        await controller.restore()

        await controller.signOut()
        #expect(controller.state == .signedOut)
        #expect(store.stored == nil)
        await #expect(throws: GraphError.unauthorized) {
            try await controller.tokens.accessToken(forceRefresh: false)
        }
    }

    @Test("a refresh refused while signed in switches to reconnect")
    func invalidatedLater() async throws {
        let transport = FakeTokenTransport(
            .tokens(access: "at-1"),
            .oauthError("invalid_grant", description: "AADSTS50173: The provided grant has expired.")
        )
        let store = InMemoryGraphTokenStore(session: TestRegistration.session())
        let controller = try Self.controller(transport, store: store)
        await controller.restore()
        #expect(controller.state == .signedIn(TestRegistration.jane))

        await #expect(throws: GraphError.unauthorized) {
            try await controller.tokens.accessToken(forceRefresh: true)
        }
        try await Self.settle { controller.state != .signedIn(TestRegistration.jane) }
        #expect(controller.state == .needsReconnect(TestRegistration.jane))
        #expect(controller.lastError?.contains("AADSTS50173") == true)
    }
}

/// What the controller's state was while the browser was open.
@MainActor
private final class StateRecorder {
    var states: [GraphAccountState] = []
}

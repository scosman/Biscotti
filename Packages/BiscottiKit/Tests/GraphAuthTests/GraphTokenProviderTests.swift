import Foundation
import GraphCalendar
import Testing
@testable import GraphAuth

/// The session owner: caching, refresh, rotation, and what a refused or
/// failed refresh does to the session.
@Suite("GraphTokenProvider")
struct GraphTokenProviderTests {
    /// A provider restored from a stored session with refresh token `rt-1`.
    private static func restored(
        _ transport: FakeTokenTransport,
        store: InMemoryGraphTokenStore = InMemoryGraphTokenStore(session: TestRegistration.session()),
        clock: TestClock = TestClock(),
        invalidations: InvalidationLog = InvalidationLog()
    ) async throws -> GraphTokenProvider {
        let provider = try makeProvider(transport, store: store, clock: clock, invalidations: invalidations)
        let stored = try await provider.restore()
        #expect(stored == store.stored)
        return provider
    }

    // MARK: - Signed out

    @Test("with no session, tokens are unauthorized and nothing is sent")
    func signedOut() async throws {
        let transport = FakeTokenTransport()
        let provider = try makeProvider(transport)
        #expect(try await provider.restore() == nil)
        #expect(await provider.accountState == .signedOut)
        await #expect(throws: GraphError.unauthorized) {
            try await provider.accessToken(forceRefresh: false)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test("a session from another registration is deleted on restore")
    func otherClientID() async throws {
        let store = InMemoryGraphTokenStore(
            session: TestRegistration.session(clientID: "99999999-2222-3333-4444-555555555555")
        )
        let provider = try makeProvider(FakeTokenTransport(), store: store)
        #expect(try await provider.restore() == nil)
        #expect(store.stored == nil)
        #expect(await provider.accountState == .signedOut)
    }

    // MARK: - Caching

    @Test("the first token comes from a refresh, then from the cache")
    func caching() async throws {
        let transport = FakeTokenTransport(.tokens(access: "at-1"))
        let provider = try await Self.restored(transport)
        #expect(await provider.accountState == .signedIn(TestRegistration.jane))

        #expect(try await provider.accessToken(forceRefresh: false) == "at-1")
        #expect(try await provider.accessToken(forceRefresh: false) == "at-1")
        #expect(await transport.requests.count == 1)
        let request = try #require(await transport.requests.first)
        #expect(try form(request)["refresh_token"] == "rt-1")
    }

    @Test("a token is refreshed five minutes before it expires")
    func expirySkew() async throws {
        let clock = TestClock()
        let transport = FakeTokenTransport(.tokens(access: "at-1", expiresIn: 3600), .tokens(access: "at-2"))
        let provider = try await Self.restored(transport, clock: clock)

        #expect(try await provider.accessToken(forceRefresh: false) == "at-1")
        clock.advance(by: 3600 - GraphTokenProvider.expirySkew - 1)
        #expect(try await provider.accessToken(forceRefresh: false) == "at-1")
        clock.advance(by: 1)
        #expect(try await provider.accessToken(forceRefresh: false) == "at-2")
        #expect(await transport.requests.count == 2)
    }

    @Test("forceRefresh skips the cache")
    func forceRefresh() async throws {
        let transport = FakeTokenTransport(.tokens(access: "at-1"), .tokens(access: "at-2"))
        let provider = try await Self.restored(transport)
        #expect(try await provider.accessToken(forceRefresh: false) == "at-1")
        #expect(try await provider.accessToken(forceRefresh: true) == "at-2")
    }

    @Test("concurrent callers share one refresh")
    func coalescing() async throws {
        let transport = FakeTokenTransport(.tokens(access: "at-1"))
        let provider = try await Self.restored(transport)
        await transport.hold()

        async let first = provider.accessToken(forceRefresh: false)
        async let second = provider.accessToken(forceRefresh: false)
        await transport.waitForRequests(1)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await transport.release()

        #expect(try await [first, second] == ["at-1", "at-1"])
        #expect(await transport.requests.count == 1)
    }

    @Test("a rotated refresh token is saved and used next")
    func rotation() async throws {
        let store = InMemoryGraphTokenStore(session: TestRegistration.session())
        let transport = FakeTokenTransport(.tokens(access: "at-1", refresh: "rt-2"), .tokens(access: "at-2"))
        let provider = try await Self.restored(transport, store: store)

        _ = try await provider.accessToken(forceRefresh: false)
        #expect(store.stored?.refreshToken == "rt-2")
        _ = try await provider.accessToken(forceRefresh: true)
        let second = try #require(await transport.requests.last)
        #expect(try form(second)["refresh_token"] == "rt-2")
        // No rotation on the second response: the saved token stays.
        #expect(store.stored?.refreshToken == "rt-2")
    }

    // MARK: - Failures

    @Test(
        "Entra refusing the refresh token means reconnect",
        arguments: ["invalid_grant", "interaction_required", "invalid_client", "unauthorized_client"]
    )
    func refused(code: String) async throws {
        let store = InMemoryGraphTokenStore(session: TestRegistration.session())
        let invalidations = InvalidationLog()
        let transport = FakeTokenTransport(.oauthError(code, description: "AADSTS700082: expired"))
        let provider = try await Self.restored(transport, store: store, invalidations: invalidations)

        await #expect(throws: GraphError.unauthorized) {
            try await provider.accessToken(forceRefresh: false)
        }
        #expect(await provider.accountState == .needsReconnect(TestRegistration.jane))
        #expect(store.stored == TestRegistration.session(refreshToken: nil))
        #expect(invalidations.all.map(\.account) == [TestRegistration.jane])
        #expect(invalidations.all.first?.error.userMessage.contains("AADSTS700082: expired") == true)

        // Later calls fail at once, without asking Entra again.
        await #expect(throws: GraphError.unauthorized) {
            try await provider.accessToken(forceRefresh: true)
        }
        #expect(await transport.requests.count == 1)
        #expect(invalidations.all.count == 1)
    }

    @Test("outages, proxies and portals keep the session")
    func transientFailures() async throws {
        let store = InMemoryGraphTokenStore(session: TestRegistration.session())
        let invalidations = InvalidationLog()
        let transport = FakeTokenTransport(
            .json(status: 503, body: "Service Unavailable"),
            .oauthError("temporarily_unavailable"),
            .json(status: 407, body: "Proxy Authentication Required"),
            .json(status: 200, body: "<html>Sign in to Wi-Fi</html>"),
            .failure(URLError(.timedOut)),
            .tokens(access: "at-1")
        )
        let provider = try await Self.restored(transport, store: store, invalidations: invalidations)

        for _ in 0 ..< 5 {
            let error = await #expect(throws: GraphError.self) {
                try await provider.accessToken(forceRefresh: false)
            }
            if case .transport = error {} else {
                Issue.record("expected GraphError.transport, got \(String(describing: error))")
            }
            #expect(await provider.accountState == .signedIn(TestRegistration.jane))
        }
        #expect(try await provider.accessToken(forceRefresh: false) == "at-1")
        #expect(store.stored == TestRegistration.session())
        #expect(invalidations.all.isEmpty)
    }

    // MARK: - Sign-in and sign-out

    @Test("completing a sign-in saves the session and caches its token")
    func completeSignIn() async throws {
        let store = InMemoryGraphTokenStore()
        let request = try AuthorizationRequest(configuration: TestRegistration.configuration(), nonce: "n1")
        let transport = FakeTokenTransport(
            .tokens(access: "at-1", refresh: "rt-1", idToken: makeIDToken(janeClaims(nonce: "n1")))
        )
        let provider = try makeProvider(transport, store: store)

        let account = try await provider.completeSignIn(code: "auth-code", request: request)
        #expect(account == TestRegistration.jane)
        #expect(store.stored == TestRegistration.session())
        #expect(await provider.accountState == .signedIn(TestRegistration.jane))
        #expect(try await provider.accessToken(forceRefresh: false) == "at-1")
        #expect(await transport.requests.count == 1)
        let redeem = try #require(await transport.requests.first)
        #expect(try form(redeem)["code_verifier"] == request.pkce.verifier)
    }

    @Test("a sign-in without a refresh token or ID token saves nothing")
    func incompleteSignIn() async throws {
        let store = InMemoryGraphTokenStore()
        let request = try AuthorizationRequest(configuration: TestRegistration.configuration(), nonce: "n1")
        let transport = FakeTokenTransport(
            .tokens(access: "at-1", idToken: makeIDToken(janeClaims(nonce: "n1"))),
            .tokens(access: "at-1", refresh: "rt-1")
        )
        let provider = try makeProvider(transport, store: store)

        await #expect(throws: GraphAuthError.invalidTokenResponse("no refresh_token; is offline_access granted?")) {
            try await provider.completeSignIn(code: "auth-code", request: request)
        }
        await #expect(throws: GraphAuthError.invalidTokenResponse("no id_token; is the openid scope granted?")) {
            try await provider.completeSignIn(code: "auth-code", request: request)
        }
        #expect(store.stored == nil)
        #expect(await provider.accountState == .signedOut)
    }

    @Test("signing out during a refresh discards the refresh's result")
    func signOutMidRefresh() async throws {
        let store = InMemoryGraphTokenStore(session: TestRegistration.session())
        let invalidations = InvalidationLog()
        let transport = FakeTokenTransport(.oauthError("invalid_grant"))
        let provider = try await Self.restored(transport, store: store, invalidations: invalidations)
        await transport.hold()

        let refresh = Task { try await provider.accessToken(forceRefresh: false) }
        await transport.waitForRequests(1)
        try await provider.signOut()
        await transport.release()

        await #expect(throws: GraphError.unauthorized) {
            try await refresh.value
        }
        // The late refusal belongs to the old session: no reconnect prompt.
        #expect(invalidations.all.isEmpty)
        #expect(store.stored == nil)
        #expect(await provider.accountState == .signedOut)
    }

    @Test("a token that arrives after sign-out is not cached")
    func lateTokenAfterSignOut() async throws {
        let transport = FakeTokenTransport(.tokens(access: "at-1", refresh: "rt-2"))
        let store = InMemoryGraphTokenStore(session: TestRegistration.session())
        let provider = try await Self.restored(transport, store: store)
        await transport.hold()

        let refresh = Task { try await provider.accessToken(forceRefresh: false) }
        await transport.waitForRequests(1)
        try await provider.signOut()
        await transport.release()

        await #expect(throws: GraphError.unauthorized) {
            try await refresh.value
        }
        #expect(store.stored == nil)
        await #expect(throws: GraphError.unauthorized) {
            try await provider.accessToken(forceRefresh: false)
        }
        #expect(await transport.requests.count == 1)
    }
}

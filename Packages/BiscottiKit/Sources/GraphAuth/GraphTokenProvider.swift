import Foundation
import GraphCalendar

/// Reported when Entra rejects the stored refresh token, so the account
/// controller can switch to "reconnect".
struct GraphSessionInvalidation: Equatable {
    let account: Microsoft365Account
    let error: GraphAuthError
}

/// Owns the signed-in session: the refresh token (persisted through the
/// store) and the current access token (memory only). Serves
/// `GraphClient` through `GraphAccessTokenProviding`.
///
/// Concurrent callers share one refresh. A refresh that Entra refuses with an
/// OAuth error clears the refresh token, reports a
/// `GraphSessionInvalidation`, and throws `GraphError.unauthorized`; later
/// calls throw the same without a network round trip until the user signs
/// in again. Outages and network failures throw `GraphError.transport` and
/// leave the session alone.
///
/// Store calls can block on a keychain prompt, which is why they run here
/// and not on the main actor.
actor GraphTokenProvider: GraphAccessTokenProviding {
    /// Refresh this long before Entra's stated expiry, so a token is not
    /// sent in its last minutes (clock skew, long paged reads).
    static let expirySkew: TimeInterval = 300

    private let configuration: GraphAuthConfiguration
    private let endpoint: TokenEndpoint
    private let store: any GraphTokenStore
    private let now: @Sendable () -> Date
    private let onInvalidated: @Sendable (GraphSessionInvalidation) -> Void

    private var session: GraphStoredSession?
    private var cached: (token: String, expiresAt: Date)?
    private var refreshTask: Task<String, any Error>?
    /// Bumped whenever the session is replaced or removed, so a refresh that
    /// started for an older session does not write its result back.
    private var generation = 0

    init(
        configuration: GraphAuthConfiguration,
        transport: any GraphHTTPTransport,
        store: any GraphTokenStore,
        now: @escaping @Sendable () -> Date,
        onInvalidated: @escaping @Sendable (GraphSessionInvalidation) -> Void
    ) {
        self.configuration = configuration
        endpoint = TokenEndpoint(configuration: configuration, transport: transport)
        self.store = store
        self.now = now
        self.onInvalidated = onInvalidated
    }

    /// The state the stored session implies.
    var accountState: GraphAccountState {
        guard let session else { return .signedOut }
        return session.refreshToken == nil ? .needsReconnect(session.account) : .signedIn(session.account)
    }

    /// Loads the saved session at launch. A session issued to a different
    /// client ID is deleted: its refresh token cannot be redeemed.
    func restore() throws(GraphAuthError) -> GraphStoredSession? {
        // A sign-in that finished first is newer than anything saved.
        guard session == nil, let stored = try store.load() else { return nil }
        guard stored.clientID.caseInsensitiveCompare(configuration.clientID) == .orderedSame else {
            graphAuthLog.info("Discarding a Microsoft 365 session from another app registration")
            try store.delete()
            return nil
        }
        replaceSession(with: stored)
        return stored
    }

    /// Redeems the code from an interactive sign-in, checks the ID token and
    /// saves the new session, replacing any previous one.
    func completeSignIn(code: String, request: AuthorizationRequest) async throws(GraphAuthError) -> Microsoft365Account {
        let response = try await endpoint.redeem(code: code, verifier: request.pkce.verifier)
        guard let idToken = response.idToken else {
            throw .invalidTokenResponse("no id_token; is the openid scope granted?")
        }
        let account = try IDTokenClaims(jwt: idToken).account(for: configuration, nonce: request.nonce)
        guard let refreshToken = response.refreshToken else {
            throw .invalidTokenResponse("no refresh_token; is offline_access granted?")
        }
        let newSession = GraphStoredSession(
            account: account, refreshToken: refreshToken, clientID: configuration.clientID
        )
        try store.save(newSession)
        replaceSession(with: newSession)
        cached = (response.accessToken, now().addingTimeInterval(response.expiresIn))
        return account
    }

    /// Forgets the session here and in the store. Entra has no revocation
    /// endpoint for public clients; the refresh token simply goes unused.
    func signOut() throws(GraphAuthError) {
        replaceSession(with: nil)
        try store.delete()
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached, cached.expiresAt.timeIntervalSince(now()) > Self.expirySkew {
            return cached.token
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task { try await self.refreshAccessToken() }
        refreshTask = task
        let result = await task.result
        // Another session may have replaced this task while it ran.
        if refreshTask == task { refreshTask = nil }
        return try result.get()
    }

    private func refreshAccessToken() async throws -> String {
        let startGeneration = generation
        guard let session, let refreshToken = session.refreshToken else {
            throw GraphError.unauthorized
        }

        let response: TokenResponse
        do throws(GraphAuthError) {
            response = try await endpoint.refresh(refreshToken: refreshToken)
        } catch {
            guard startGeneration == generation else { throw GraphError.unauthorized }
            if error == .cancelled { throw CancellationError() }
            guard Self.invalidatesSession(error) else {
                graphAuthLog.error("Token refresh failed; keeping the session: \(error.userMessage, privacy: .public)")
                throw GraphError.transport(error.userMessage)
            }
            graphAuthLog.error("Token refresh refused; reconnect needed: \(error.userMessage, privacy: .public)")
            invalidate(session, error: error)
            throw GraphError.unauthorized
        }

        // Signed out, or signed in again, while the request was in flight.
        guard startGeneration == generation else { throw GraphError.unauthorized }
        cached = (response.accessToken, now().addingTimeInterval(response.expiresIn))
        if let rotated = response.refreshToken, rotated != refreshToken {
            var updated = session
            updated.refreshToken = rotated
            self.session = updated
            do {
                try store.save(updated)
            } catch {
                // The previous refresh token stays valid until it expires,
                // so the next launch can still refresh with it.
                graphAuthLog.error("Couldn't save the rotated refresh token: \(error.userMessage, privacy: .public)")
            }
        }
        return response.accessToken
    }

    /// True when Entra itself refused the refresh token with an OAuth error.
    /// A status without an OAuth body (a proxy or captive portal) or a
    /// garbled 200 is treated as a network problem, not a dead session.
    static func invalidatesSession(_ error: GraphAuthError) -> Bool {
        switch error {
        case .reauthenticationRequired:
            true
        case let .tokenRequestFailed(_, code, _):
            code != nil
        default:
            false
        }
    }

    private func invalidate(_ session: GraphStoredSession, error: GraphAuthError) {
        var dead = session
        dead.refreshToken = nil
        self.session = dead
        cached = nil
        do {
            try store.save(dead)
        } catch {
            graphAuthLog.error("Couldn't save the reconnect state: \(error.userMessage, privacy: .public)")
        }
        onInvalidated(GraphSessionInvalidation(account: session.account, error: error))
    }

    private func replaceSession(with newSession: GraphStoredSession?) {
        session = newSession
        cached = nil
        refreshTask = nil
        generation += 1
    }
}

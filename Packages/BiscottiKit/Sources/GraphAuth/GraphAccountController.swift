import Foundation
import GraphCalendar
import Observation

/// The Microsoft 365 account behind the Settings row and the Home reconnect
/// banner: restores the saved session at launch, runs the interactive
/// sign-in, and signs out. `tokens` is what `GraphClient` reads Graph with.
///
/// Sign-in is OAuth 2.0 authorization code + PKCE against Entra ID's v2
/// endpoints, as a public client. The browser part runs in
/// `ASWebAuthenticationSession`; the refresh token is kept in the login
/// keychain.
@MainActor @Observable
public final class GraphAccountController {
    public private(set) var state: GraphAccountState
    /// The last sign-in, refresh or keychain failure, in words for the user.
    /// Cleared when a new sign-in starts.
    public private(set) var lastError: String?

    private let configuration: GraphAuthConfiguration?
    private let provider: GraphTokenProvider?
    private let webSession: (any WebAuthenticationSessionRunning)?
    private var hasRestored = false

    /// A controller without an app registration. It stays `.notConfigured`
    /// and every action is a no-op. AppCore's default for tests.
    public init(notConfigured reason: GraphAuthConfigurationError) {
        state = .notConfigured(reason)
        configuration = nil
        provider = nil
        webSession = nil
    }

    public init(
        configuration: GraphAuthConfiguration,
        store: any GraphTokenStore,
        transport: any GraphHTTPTransport = URLSessionGraphTransport(),
        webSession: any WebAuthenticationSessionRunning,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let relay = InvalidationRelay()
        state = .signedOut
        self.configuration = configuration
        self.webSession = webSession
        provider = GraphTokenProvider(
            configuration: configuration,
            transport: transport,
            store: store,
            now: now
        ) { invalidation in
            Task { @MainActor in relay.controller?.sessionInvalidated(invalidation) }
        }
        relay.controller = self
    }

    /// The app's controller: the registration from user defaults or
    /// `Info.plist`, the login keychain, URLSession and the system browser.
    public static func live() -> GraphAccountController {
        do {
            let configuration = try GraphAuthConfiguration.load()
            return GraphAccountController(
                configuration: configuration,
                store: KeychainGraphTokenStore(),
                webSession: SystemWebAuthenticationSession()
            )
        } catch {
            graphAuthLog.info("Microsoft 365 sign-in is not configured: \(error.userMessage, privacy: .public)")
            return GraphAccountController(notConfigured: error)
        }
    }

    /// Access tokens for `GraphClient`. Throws `GraphError.unauthorized`
    /// unless an account is signed in.
    public var tokens: any GraphAccessTokenProviding {
        provider ?? UnavailableGraphTokens()
    }

    public var isConfigured: Bool {
        configuration != nil
    }

    // MARK: - Actions

    /// Loads the saved session, then refreshes once so a refresh token that
    /// stopped working shows as "reconnect" now rather than at the first
    /// calendar read. Runs once; later calls return at once.
    public func restore() async {
        guard let provider, !hasRestored else { return }
        hasRestored = true
        let stored: GraphStoredSession?
        do {
            stored = try await provider.restore()
        } catch {
            graphAuthLog.error("Couldn't read the saved Microsoft 365 session: \(error.userMessage, privacy: .public)")
            lastError = error.userMessage
            return
        }
        // A sign-in that started while the keychain was being read wins.
        guard let stored, state == .signedOut else { return }
        state = await provider.accountState
        guard stored.refreshToken != nil else { return }
        do {
            _ = try await provider.accessToken(forceRefresh: false)
        } catch {
            // A refused token arrives through `sessionInvalidated`; anything
            // else (offline at launch) keeps the account signed in.
            graphAuthLog.info("Launch token check failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Runs the interactive sign-in. On reconnect the current username is
    /// pre-filled. Cancelling leaves the previous state without an error.
    public func signIn() async {
        guard let configuration, let provider, let webSession else { return }
        if state == .signingIn { return }
        let loginHint = state.account?.username
        state = .signingIn
        lastError = nil

        let request = AuthorizationRequest(configuration: configuration, loginHint: loginHint)
        do throws(GraphAuthError) {
            let callback = try await webSession.authenticate(
                url: request.url,
                callbackScheme: configuration.callbackScheme
            )
            let code = try request.authorizationCode(from: callback)
            let account = try await provider.completeSignIn(code: code, request: request)
            graphAuthLog.info("Signed in to Microsoft 365 as \(account.username, privacy: .private)")
            state = .signedIn(account)
        } catch {
            if error != .cancelled {
                graphAuthLog.error("Microsoft 365 sign-in failed: \(error.userMessage, privacy: .public)")
                lastError = error.userMessage
            }
            // The provider's session, not the state before sign-in: a refresh
            // may have been refused while the browser was open.
            state = await provider.accountState
        }
    }

    /// Closes an open sign-in window; `signIn()` then returns cancelled.
    public func cancelSignIn() {
        webSession?.cancel()
    }

    /// Forgets the account and deletes the saved session.
    public func signOut() async {
        guard let provider, state != .signingIn else { return }
        do {
            try await provider.signOut()
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        state = .signedOut
        graphAuthLog.info("Signed out of Microsoft 365")
    }

    private func sessionInvalidated(_ invalidation: GraphSessionInvalidation) {
        // During a sign-in the outcome of that sign-in decides the state.
        guard state != .signingIn else { return }
        state = .needsReconnect(invalidation.account)
        lastError = invalidation.error.userMessage
    }
}

/// Lets the token provider reach the controller without keeping it alive.
@MainActor
private final class InvalidationRelay {
    weak var controller: GraphAccountController?
}

/// Tokens when sign-in is not configured.
private struct UnavailableGraphTokens: GraphAccessTokenProviding {
    func accessToken(forceRefresh _: Bool) async throws -> String {
        throw GraphError.unauthorized
    }
}

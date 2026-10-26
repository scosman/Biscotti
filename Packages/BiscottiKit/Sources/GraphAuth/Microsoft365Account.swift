import Foundation

/// The signed-in Microsoft 365 user, from the ID token.
public struct Microsoft365Account: Sendable, Equatable, Codable {
    /// `preferred_username`: the sign-in name, usually the email address.
    /// Pre-filled as `login_hint` on reconnect.
    public let username: String
    /// `name`, when the `profile` scope returned one.
    public let displayName: String?
    /// `oid`: the user's object ID, stable across renames.
    public let objectID: String
    /// `tid`: the directory the user signed in to.
    public let tenantID: String

    public init(username: String, displayName: String?, objectID: String, tenantID: String) {
        self.username = username
        self.displayName = displayName
        self.objectID = objectID
        self.tenantID = tenantID
    }
}

/// The account state the Settings row and the Home banner render.
public enum GraphAccountState: Sendable, Equatable {
    /// No usable app registration; sign-in is unavailable.
    case notConfigured(GraphAuthConfigurationError)
    /// Configured, no account connected.
    case signedOut
    /// The browser sign-in is open.
    case signingIn
    case signedIn(Microsoft365Account)
    /// The refresh token stopped working; the account must sign in again.
    case needsReconnect(Microsoft365Account)

    public var account: Microsoft365Account? {
        switch self {
        case let .signedIn(account), let .needsReconnect(account): account
        case .notConfigured, .signedOut, .signingIn: nil
        }
    }

    /// Whether an app registration is configured. With one, Microsoft 365
    /// replaces Apple Calendar, so Home and Settings hide the Apple Calendar
    /// prompts.
    public var isConfigured: Bool {
        if case .notConfigured = self { return false }
        return true
    }

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

/// What the keychain holds between launches. `refreshToken` is nil once
/// Entra has rejected it, so the next launch shows "reconnect" without a
/// network round trip.
public struct GraphStoredSession: Sendable, Equatable, Codable {
    public var account: Microsoft365Account
    public var refreshToken: String?
    /// The registration the token was issued to. A different configured
    /// client ID makes the stored token useless, so it is discarded.
    public var clientID: String

    public init(account: Microsoft365Account, refreshToken: String?, clientID: String) {
        self.account = account
        self.refreshToken = refreshToken
        self.clientID = clientID
    }
}

/// The ID token claims Biscotti reads. The token comes straight from the
/// token endpoint over TLS, so the signature is not checked (OpenID Connect
/// Core §3.1.3.7 allows TLS validation for a direct token response); the
/// audience, tenant and nonce are.
struct IDTokenClaims: Equatable, Decodable {
    let audience: String
    let tenantID: String?
    let objectID: String?
    let preferredUsername: String?
    let email: String?
    let name: String?
    let nonce: String?

    private enum CodingKeys: String, CodingKey {
        case audience = "aud"
        case tenantID = "tid"
        case objectID = "oid"
        case preferredUsername = "preferred_username"
        case email
        case name
        case nonce
    }

    /// Decodes the payload of a compact JWS (`header.payload.signature`).
    init(jwt: String) throws(GraphAuthError) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Data(base64URLEncoded: String(parts[1])) else {
            throw .invalidIDToken("not a compact JWT")
        }
        do {
            self = try JSONDecoder().decode(Self.self, from: payload)
        } catch {
            throw .invalidIDToken("unreadable claims: \(error)")
        }
    }

    /// The account, after checking the token was issued to this app, in the
    /// configured tenant, and (on code redemption) for this sign-in attempt.
    func account(for configuration: GraphAuthConfiguration, nonce expectedNonce: String?) throws(GraphAuthError)
        -> Microsoft365Account
    {
        guard audience.caseInsensitiveCompare(configuration.clientID) == .orderedSame else {
            throw .invalidIDToken("issued to another application")
        }
        guard let tenantID, let objectID else {
            throw .invalidIDToken("missing tid or oid")
        }
        if configuration.tenantIsID, tenantID.caseInsensitiveCompare(configuration.tenant) != .orderedSame {
            throw .invalidIDToken("issued by another tenant")
        }
        if let expectedNonce, nonce != expectedNonce {
            throw .invalidIDToken("nonce does not match the sign-in request")
        }
        let username = [preferredUsername, email]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return Microsoft365Account(
            username: username ?? "Microsoft 365 account",
            displayName: name,
            objectID: objectID,
            tenantID: tenantID
        )
    }
}

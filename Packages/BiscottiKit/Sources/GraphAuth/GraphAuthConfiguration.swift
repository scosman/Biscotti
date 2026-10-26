import Foundation

/// The Entra ID app registration Biscotti signs in with: a single-tenant
/// public client (no secret) on the "Mobile and desktop applications"
/// platform. The client and tenant IDs come from the build or the machine,
/// never from source (see `docs/entra_app_registration.md`):
///
/// 1. User defaults, which includes managed preferences pushed by MDM:
///
///        defaults write com.synderys.biscotti MicrosoftGraphClientID <guid>
///        defaults write com.synderys.biscotti MicrosoftGraphTenantID <guid>
///
/// 2. The same keys in the app's `Info.plist`, filled at build time from
///    `MICROSOFT_GRAPH_CLIENT_ID` / `MICROSOFT_GRAPH_TENANT_ID` in the
///    git-ignored `Makefile.local`.
///
/// The redirect URI follows the MSAL convention for the bundle ID, so the
/// registration Entra generates for the iOS/macOS platform matches it.
public struct GraphAuthConfiguration: Sendable, Equatable {
    /// User-defaults and `Info.plist` key for the application (client) ID.
    public static let clientIDKey = "MicrosoftGraphClientID"
    /// User-defaults and `Info.plist` key for the directory (tenant) ID.
    public static let tenantKey = "MicrosoftGraphTenantID"

    public static let defaultRedirectURI = URL(string: "msauth.com.synderys.biscotti://auth")!
    public static let defaultAuthority = URL(string: "https://login.microsoftonline.com/")!
    /// OIDC scopes for the account name, `offline_access` for the refresh
    /// token, and the delegated Graph scopes the calendar reader needs.
    public static let defaultScopes = [
        "openid", "profile", "offline_access",
        "User.Read", "Calendars.Read", "Calendars.Read.Shared"
    ]

    /// Tenant aliases that would make the app multi-tenant. The registration
    /// is single-tenant, so only a tenant ID or a verified domain is valid.
    static let multiTenantAliases: Set = ["common", "organizations", "consumers"]

    public let clientID: String
    /// A tenant ID (GUID) or one of the tenant's verified domains.
    public let tenant: String
    public let redirectURI: URL
    public let scopes: [String]
    public let authority: URL

    public init(
        clientID: String,
        tenant: String,
        redirectURI: URL = defaultRedirectURI,
        scopes: [String] = defaultScopes,
        authority: URL = defaultAuthority
    ) throws(GraphAuthConfigurationError) {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let tenant = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw .missingClientID }
        guard UUID(uuidString: clientID) != nil else { throw .invalidClientID(clientID) }
        guard !tenant.isEmpty else { throw .missingTenant }
        guard Self.isValidTenant(tenant) else { throw .invalidTenant(tenant) }
        self.clientID = clientID
        self.tenant = tenant
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.authority = authority
    }

    /// Reads the IDs from `defaults`, then `infoDictionary`. A key that is
    /// present but blank counts as missing, so an empty `Info.plist`
    /// placeholder does not hide a value set in defaults.
    public static func load(
        defaults: UserDefaults = .standard,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) throws(GraphAuthConfigurationError) -> GraphAuthConfiguration {
        func value(_ key: String) -> String {
            for candidate in [defaults.string(forKey: key), infoDictionary?[key] as? String] {
                let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty { return trimmed }
            }
            return ""
        }
        return try GraphAuthConfiguration(clientID: value(clientIDKey), tenant: value(tenantKey))
    }

    public var authorizeEndpoint: URL {
        authority.appending(path: tenant).appending(path: "oauth2/v2.0/authorize")
    }

    public var tokenEndpoint: URL {
        authority.appending(path: tenant).appending(path: "oauth2/v2.0/token")
    }

    /// The scheme `ASWebAuthenticationSession` watches for.
    public var callbackScheme: String {
        redirectURI.scheme ?? ""
    }

    /// The scopes as the space-separated `scope` parameter.
    var scopeParameter: String {
        scopes.joined(separator: " ")
    }

    /// True when `tenant` is a tenant ID, so the ID token's `tid` can be
    /// checked against it. A domain cannot be compared offline.
    var tenantIsID: Bool {
        UUID(uuidString: tenant) != nil
    }

    static func isValidTenant(_ tenant: String) -> Bool {
        if UUID(uuidString: tenant) != nil { return true }
        if multiTenantAliases.contains(tenant.lowercased()) { return false }
        // A DNS name: at least two labels of letters, digits and hyphens.
        let labels = tenant.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

/// Why the app has no usable registration. The Settings row shows
/// `userMessage` under "Not configured".
public enum GraphAuthConfigurationError: Error, Sendable, Equatable {
    case missingClientID
    case invalidClientID(String)
    case missingTenant
    case invalidTenant(String)

    public var userMessage: String {
        switch self {
        case .missingClientID, .missingTenant:
            "This build has no Microsoft 365 app registration. Ask IT for the client and tenant IDs."
        case let .invalidClientID(value):
            "The Microsoft 365 client ID \u{201C}\(value)\u{201D} is not a valid ID."
        case let .invalidTenant(value):
            "The Microsoft 365 tenant \u{201C}\(value)\u{201D} must be a tenant ID or the organization's domain."
        }
    }
}

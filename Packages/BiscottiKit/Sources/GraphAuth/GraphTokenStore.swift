import Foundation
import os
import Security

/// Persists the signed-in session between launches. Calls are synchronous
/// and may block (a keychain access prompt), so `GraphTokenProvider` makes
/// them on its own executor, never the main actor.
public protocol GraphTokenStore: Sendable {
    func load() throws(GraphAuthError) -> GraphStoredSession?
    func save(_ session: GraphStoredSession) throws(GraphAuthError)
    func delete() throws(GraphAuthError)
}

/// The production store: one generic-password item in the login keychain
/// holding the session as JSON. The file-based login keychain, not the
/// data-protection keychain, because it needs no keychain-access-group
/// entitlement and so works in ad-hoc and Developer ID builds alike. The
/// access token is never stored; it lives in memory only.
///
/// An ad-hoc build gets a new code signature on every rebuild, so macOS asks
/// once per build whether Biscotti may read the item. Signed builds keep a
/// stable identity and are not asked again.
public struct KeychainGraphTokenStore: GraphTokenStore {
    public static let defaultService = "com.synderys.biscotti.microsoft365"

    private let service: String
    private let account: String

    public init(service: String = defaultService, account: String = "session") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: false
        ]
    }

    public func load() throws(GraphAuthError) -> GraphStoredSession? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw .keychain(status)
        }
        guard let session = try? JSONDecoder().decode(GraphStoredSession.self, from: data) else {
            // An unreadable item (e.g. an older format) is as good as none.
            graphAuthLog.error("Discarding an unreadable Microsoft 365 keychain item")
            try delete()
            return nil
        }
        return session
    }

    public func save(_ session: GraphStoredSession) throws(GraphAuthError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(session)
        } catch {
            throw .invalidTokenResponse("could not encode the session: \(error)")
        }
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw .keychain(status) }

        var add = baseQuery
        add[kSecValueData] = data
        add[kSecAttrLabel] = "Biscotti Microsoft 365 sign-in"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw .keychain(addStatus) }
    }

    public func delete() throws(GraphAuthError) {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .keychain(status)
        }
    }
}

/// A store that keeps the session in memory. For tests and previews.
public final class InMemoryGraphTokenStore: GraphTokenStore {
    private let session: OSAllocatedUnfairLock<GraphStoredSession?>

    public init(session: GraphStoredSession? = nil) {
        self.session = OSAllocatedUnfairLock(initialState: session)
    }

    public var stored: GraphStoredSession? {
        session.withLock { $0 }
    }

    public func load() throws(GraphAuthError) -> GraphStoredSession? {
        session.withLock { $0 }
    }

    public func save(_ newValue: GraphStoredSession) throws(GraphAuthError) {
        session.withLock { $0 = newValue }
    }

    public func delete() throws(GraphAuthError) {
        session.withLock { $0 = nil }
    }
}

import Foundation
import GraphCalendar
import os
import Testing
@testable import GraphAuth

// MARK: - Registration

/// A made-up single-tenant registration.
enum TestRegistration {
    static let clientID = "11111111-2222-3333-4444-555555555555"
    static let tenantID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    static func configuration() throws -> GraphAuthConfiguration {
        try GraphAuthConfiguration(clientID: clientID, tenant: tenantID)
    }

    static let jane = Microsoft365Account(
        username: "jane@synderys.com",
        displayName: "Jane Doe",
        objectID: "00000000-0000-0000-0000-00000000000a",
        tenantID: tenantID
    )

    static func session(refreshToken: String? = "rt-1", clientID: String = clientID) -> GraphStoredSession {
        GraphStoredSession(account: jane, refreshToken: refreshToken, clientID: clientID)
    }
}

// MARK: - Token responses

enum TokenReply {
    case json(status: Int, body: String)
    case failure(any Error)

    /// A 200 token response. `nil` fields are left out of the JSON.
    static func tokens(
        access: String,
        expiresIn: Int = 3600,
        refresh: String? = nil,
        idToken: String? = nil
    ) -> TokenReply {
        var body: [String: Any] = ["token_type": "Bearer", "access_token": access, "expires_in": expiresIn]
        body["refresh_token"] = refresh
        body["id_token"] = idToken
        return .json(status: 200, body: jsonString(body))
    }

    /// An OAuth error body (RFC 6749 §5.2).
    static func oauthError(_ code: String, status: Int = 400, description: String? = nil) -> TokenReply {
        var body: [String: Any] = ["error": code]
        body["error_description"] = description
        return .json(status: status, body: jsonString(body))
    }
}

func jsonString(_ object: [String: Any]) -> String {
    // Test-only input built from literals; it always serializes.
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return String(bytes: data, encoding: .utf8) ?? ""
}

/// An unsigned compact JWT carrying `claims`. Only the payload is read.
func makeIDToken(_ claims: [String: Any]) -> String {
    let header = Data(jsonString(["alg": "none", "typ": "JWT"]).utf8).base64URLEncodedString()
    let payload = Data(jsonString(claims).utf8).base64URLEncodedString()
    return "\(header).\(payload).signature"
}

/// The claims Entra returns for `TestRegistration.jane`.
func janeClaims(nonce: String? = nil) -> [String: Any] {
    var claims: [String: Any] = [
        "aud": TestRegistration.clientID,
        "tid": TestRegistration.tenantID,
        "oid": TestRegistration.jane.objectID,
        "preferred_username": TestRegistration.jane.username,
        "name": "Jane Doe"
    ]
    claims["nonce"] = nonce
    return claims
}

enum FakeTokenTransportError: Error {
    case noReplyQueued
}

// MARK: - Fake transport

/// Replies to token requests from a queue, in order, and records them.
/// `hold()` parks requests until `release()`, so a refresh can be kept in
/// flight while the test does something else.
actor FakeTokenTransport: GraphHTTPTransport {
    private var replies: [TokenReply]
    private(set) var requests: [URLRequest] = []
    private var isHolding = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ replies: TokenReply...) {
        self.replies = replies
    }

    func enqueue(_ reply: TokenReply) {
        replies.append(reply)
    }

    func hold() {
        isHolding = true
    }

    func release() {
        isHolding = false
        let waiting = parked
        parked = []
        waiting.forEach { $0.resume() }
    }

    /// Returns once `count` requests have arrived.
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let ready = requestWaiters.filter { $0.count <= requests.count }
        requestWaiters.removeAll { $0.count <= requests.count }
        ready.forEach { $0.continuation.resume() }

        if isHolding {
            await withCheckedContinuation { parked.append($0) }
        }
        guard !replies.isEmpty else { throw FakeTokenTransportError.noReplyQueued }
        switch replies.removeFirst() {
        case let .failure(error):
            throw error
        case let .json(status, body):
            let url = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
            )
            return (Data(body.utf8), response)
        }
    }
}

/// The decoded `application/x-www-form-urlencoded` body of `request`.
func form(_ request: URLRequest) throws -> [String: String] {
    let body = try #require(request.httpBody)
    let text = try #require(String(bytes: body, encoding: .utf8))
    var fields: [String: String] = [:]
    for pair in text.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = try #require(String(parts[0]).removingPercentEncoding)
        let value = try #require(String(parts.count > 1 ? parts[1] : "").removingPercentEncoding)
        fields[key] = value
    }
    return fields
}

func queryItems(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}

// MARK: - Clock and invalidations

/// A clock the test moves by hand.
final class TestClock: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_792_972_800))

    var now: @Sendable () -> Date {
        { self.current.withLock { $0 } }
    }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Collects the provider's invalidation reports.
final class InvalidationLog: Sendable {
    private let events = OSAllocatedUnfairLock<[GraphSessionInvalidation]>(initialState: [])

    var all: [GraphSessionInvalidation] {
        events.withLock { $0 }
    }

    var handler: @Sendable (GraphSessionInvalidation) -> Void {
        { event in self.events.withLock { $0.append(event) } }
    }
}

func makeProvider(
    _ transport: FakeTokenTransport,
    store: InMemoryGraphTokenStore = InMemoryGraphTokenStore(),
    clock: TestClock = TestClock(),
    invalidations: InvalidationLog = InvalidationLog()
) throws -> GraphTokenProvider {
    try GraphTokenProvider(
        configuration: TestRegistration.configuration(),
        transport: transport,
        store: store,
        now: clock.now,
        onInvalidated: invalidations.handler
    )
}

// MARK: - Fake browser

/// Stands in for `ASWebAuthenticationSession`: hands the authorize URL to
/// `respond`, which returns the redirect (or an error).
@MainActor
final class FakeWebSession: WebAuthenticationSessionRunning {
    var respond: @MainActor (URL) async -> Result<URL, GraphAuthError>
    private(set) var openedURLs: [URL] = []
    private(set) var cancelCount = 0

    init(respond: @escaping @MainActor (URL) async -> Result<URL, GraphAuthError> = FakeWebSession.approve) {
        self.respond = respond
    }

    func authenticate(url: URL, callbackScheme: String) async throws(GraphAuthError) -> URL {
        #expect(callbackScheme == "msauth.com.synderys.biscotti")
        openedURLs.append(url)
        return try await respond(url).get()
    }

    func cancel() {
        cancelCount += 1
    }

    /// The redirect Entra sends after a successful sign-in: the code and
    /// the request's own `state`.
    static func approve(_ url: URL) -> Result<URL, GraphAuthError> {
        let state = queryItems(url)["state"] ?? ""
        guard let callback = URL(string: "msauth.com.synderys.biscotti://auth?code=auth-code&state=\(state)") else {
            return .failure(.invalidCallback("test callback"))
        }
        return .success(callback)
    }
}

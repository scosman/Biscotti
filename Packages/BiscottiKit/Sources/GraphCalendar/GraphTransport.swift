import Foundation

/// Supplies the bearer token for Graph requests. The app's implementation is
/// `GraphAuth`'s token provider, which refreshes silently; tests and tools
/// inject a fixed token.
public protocol GraphAccessTokenProviding: Sendable {
    /// Returns an access token with the calendar scopes. `forceRefresh` is
    /// true after Graph rejected the previous token with 401, so a cached
    /// token must not be returned again.
    func accessToken(forceRefresh: Bool) async throws -> String
}

/// A fixed token, e.g. one copied from Graph Explorer for a manual check.
/// It cannot refresh, so a 401 surfaces as `GraphError.unauthorized`.
public struct StaticGraphAccessToken: GraphAccessTokenProviding {
    private let token: String

    public init(_ token: String) {
        self.token = token
    }

    public func accessToken(forceRefresh _: Bool) async throws -> String {
        token
    }
}

/// Sends one HTTP request. The seam tests use to replay recorded Graph
/// responses without a network.
public protocol GraphHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport.
public struct URLSessionGraphTransport: GraphHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GraphError.invalidResponse
        }
        return (data, http)
    }
}

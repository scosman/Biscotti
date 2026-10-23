import Foundation

/// Failures from `GraphClient`. Retries (one token refresh on 401, backoff on
/// 429/503) have already been spent by the time one of these is thrown.
public enum GraphError: Error, Sendable, Equatable {
    /// 401 even after a forced token refresh: the account needs to sign in
    /// again.
    case unauthorized
    /// 403: consent is missing, or a shared calendar is no longer readable.
    case forbidden(code: String?, message: String?)
    /// 429 or 503 on every attempt. `retryAfter` is the last server hint.
    case throttled(retryAfter: TimeInterval?)
    /// Any other non-2xx status.
    case http(status: Int, code: String?, message: String?)
    /// The request URL could not be built (for example, an unexpected
    /// base URL).
    case invalidRequest(String)
    /// The transport returned something that is not an HTTP response.
    case invalidResponse
    /// A 2xx body that did not decode into the expected shape.
    case decoding(String)
    /// A network-level failure (offline, DNS, TLS, timeout).
    case transport(String)
    /// An `@odata.nextLink` that points somewhere other than the Graph host
    /// the client was created for. Not followed, so the token is never sent
    /// to another host.
    case untrustedNextLink(String)
}

/// Failures mapping one Graph event. The reader logs and skips the event.
public enum GraphMappingError: Error, Sendable, Equatable {
    /// `start`/`end` (or `originalStart`) was not a parseable date.
    case invalidDateTime(String)
    /// A `dateTimeTimeZone` named a zone that is neither UTC nor resolvable.
    case unknownTimeZone(String)
}

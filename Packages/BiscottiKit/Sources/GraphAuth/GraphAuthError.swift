import Foundation

/// Failures from sign-in and token refresh. `GraphTokenProvider` maps these
/// to `GraphError` for `GraphClient`: anything that needs an interactive
/// sign-in becomes `.unauthorized`, anything worth retrying `.transport`.
public enum GraphAuthError: Error, Sendable, Equatable {
    /// The user closed the sign-in window.
    case cancelled
    /// The sign-in window could not be shown.
    case presentation(String)
    /// Entra redirected back with an error, e.g. consent was declined.
    case authorizationDenied(code: String, description: String?)
    /// The redirect did not match the request (wrong `state`, no `code`).
    case invalidCallback(String)
    /// The refresh token is no longer accepted: it expired, was revoked, the
    /// password changed, or Conditional Access now requires something new.
    /// Only an interactive sign-in fixes it.
    case reauthenticationRequired(code: String, description: String?)
    /// The token endpoint refused the request for another reason, usually a
    /// registration problem (`invalid_client`, `unauthorized_client`).
    case tokenRequestFailed(status: Int, code: String?, description: String?)
    /// The identity service is down or throttling. Worth retrying later.
    case temporarilyUnavailable(status: Int, description: String?)
    /// A 2xx token response without the expected fields.
    case invalidTokenResponse(String)
    /// The ID token is for another app or tenant, or fails the nonce check.
    case invalidIDToken(String)
    /// There is no signed-in account to refresh.
    case notSignedIn
    /// A keychain read or write failed with this `OSStatus`.
    case keychain(Int32)
    /// A network-level failure (offline, DNS, TLS, timeout).
    case transport(String)

    /// True for failures a later retry can fix without the user.
    public var isTransient: Bool {
        switch self {
        case .temporarilyUnavailable, .transport: true
        default: false
        }
    }

    /// The text the Settings row shows in red.
    public var userMessage: String {
        switch self {
        case .cancelled:
            "Sign-in was cancelled."
        case let .presentation(reason):
            "Couldn't open the Microsoft sign-in window. \(reason)"
        case let .authorizationDenied(code, description):
            "Microsoft sign-in didn't complete: \(Self.summary(code: code, description: description))"
        case .invalidCallback:
            "Microsoft sign-in returned an unexpected response. Try again."
        case let .reauthenticationRequired(code, description):
            "Microsoft 365 needs you to sign in again: \(Self.summary(code: code, description: description))"
        case let .tokenRequestFailed(status, code, description):
            "Microsoft sign-in failed: \(Self.summary(code: code ?? "HTTP \(status)", description: description))"
        case .temporarilyUnavailable:
            "Microsoft sign-in is temporarily unavailable. Try again later."
        case .invalidTokenResponse, .invalidIDToken:
            "Microsoft sign-in returned an unexpected response. Try again."
        case .notSignedIn:
            "No Microsoft 365 account is connected."
        case let .keychain(status):
            "Couldn't save the Microsoft 365 sign-in to the keychain (error \(status))."
        case .transport:
            "Couldn't reach Microsoft. Check your network connection."
        }
    }

    /// Entra's `error_description` runs to several lines with trace and
    /// correlation IDs; the first line carries the `AADSTS` code and reason.
    static func summary(code: String, description: String?) -> String {
        let firstLine = description?
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let firstLine, !firstLine.isEmpty else { return code }
        return firstLine
    }
}

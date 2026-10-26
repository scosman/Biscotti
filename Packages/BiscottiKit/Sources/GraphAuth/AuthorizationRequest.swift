import Foundation

/// One interactive authorization: the URL the browser opens and the
/// per-attempt secrets (`state`, `nonce`, PKCE verifier) needed to check
/// the redirect and redeem the code.
struct AuthorizationRequest {
    let url: URL
    let state: String
    let nonce: String
    let pkce: PKCE

    /// - Parameter loginHint: The username to pre-fill on reconnect. Without
    ///   one, the account picker is shown so a cached browser session for
    ///   another account is not picked silently.
    init(
        configuration: GraphAuthConfiguration,
        loginHint: String? = nil,
        pkce: PKCE = .generate(),
        state: String = randomURLSafeString(byteCount: 16),
        nonce: String = randomURLSafeString(byteCount: 16)
    ) {
        self.pkce = pkce
        self.state = state
        self.nonce = nonce

        var items = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: configuration.scopeParameter),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        if let loginHint, !loginHint.isEmpty {
            items.append(URLQueryItem(name: "login_hint", value: loginHint))
        } else {
            items.append(URLQueryItem(name: "prompt", value: "select_account"))
        }
        var components = URLComponents(url: configuration.authorizeEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = items
        // The endpoint is built from a validated tenant, so this cannot fail;
        // the fallback keeps the initializer non-optional.
        url = components?.url ?? configuration.authorizeEndpoint
    }

    /// The authorization code from the redirect, after checking `state`.
    func authorizationCode(from callback: URL) throws(GraphAuthError) -> String {
        // The redirect query is form-encoded (RFC 6749 appendix B): Entra
        // sends spaces in `error_description` as `+`, which `queryItems`
        // would leave in place.
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
                .map { $0.replacingOccurrences(of: "+", with: " ") }
                .map { $0.removingPercentEncoding ?? $0 }
        }
        // An error redirect is checked first: Entra still echoes `state`, but
        // the useful part is the error, not a state mismatch.
        if let error = value("error") {
            throw .authorizationDenied(code: error, description: value("error_description"))
        }
        guard value("state") == state else {
            throw .invalidCallback("state does not match the request")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw .invalidCallback("no authorization code")
        }
        return code
    }
}

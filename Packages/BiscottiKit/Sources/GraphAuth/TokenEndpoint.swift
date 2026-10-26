import Foundation
import GraphCalendar

/// A successful token response from Entra's v2 token endpoint.
struct TokenResponse: Equatable {
    let accessToken: String
    /// Seconds until `accessToken` expires.
    let expiresIn: TimeInterval
    /// Present on code redemption and usually on refresh. Entra rotates it,
    /// so a new one replaces the stored one.
    let refreshToken: String?
    let idToken: String?
}

extension TokenResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        // v2 sends a number; v1 sent a string. Accept both.
        if let seconds = try? container.decode(Double.self, forKey: .expiresIn) {
            expiresIn = seconds
        } else if let text = try? container.decode(String.self, forKey: .expiresIn), let seconds = Double(text) {
            expiresIn = seconds
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresIn, in: container, debugDescription: "expires_in is missing or not a number"
            )
        }
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
    }
}

/// An OAuth error body (RFC 6749 §5.2).
private struct TokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// The two token requests a public client makes: redeeming an authorization
/// code and refreshing. Requests carry no `Origin` header, so Entra treats
/// them as a native client rather than a single-page app.
struct TokenEndpoint {
    let configuration: GraphAuthConfiguration
    let transport: any GraphHTTPTransport

    /// OAuth errors that only an interactive sign-in fixes.
    static let reauthenticationCodes: Set = [
        "invalid_grant", "interaction_required", "login_required", "consent_required"
    ]
    /// OAuth errors Entra uses for outages, whatever the status code.
    static let transientCodes: Set = ["temporarily_unavailable", "server_error"]

    func redeem(code: String, verifier: String) async throws(GraphAuthError) -> TokenResponse {
        try await request([
            "client_id": configuration.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "code_verifier": verifier,
            "scope": configuration.scopeParameter
        ])
    }

    func refresh(refreshToken: String) async throws(GraphAuthError) -> TokenResponse {
        try await request([
            "client_id": configuration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": configuration.scopeParameter
        ])
    }

    private func request(_ parameters: [String: String]) async throws(GraphAuthError) -> TokenResponse {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncoded(parameters).utf8)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            if Task.isCancelled { throw .cancelled }
            throw .transport(error.localizedDescription)
        }
        return try Self.interpret(data: data, status: response.statusCode)
    }

    static func interpret(data: Data, status: Int) throws(GraphAuthError) -> TokenResponse {
        if (200 ..< 300).contains(status) {
            let decoded: TokenResponse
            do {
                decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            } catch {
                throw .invalidTokenResponse(String(describing: error))
            }
            guard !decoded.accessToken.isEmpty else {
                throw .invalidTokenResponse("empty access_token")
            }
            return decoded
        }

        let body = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
        if let body, reauthenticationCodes.contains(body.error) {
            throw .reauthenticationRequired(code: body.error, description: body.errorDescription)
        }
        if status >= 500 || status == 429 || body.map({ transientCodes.contains($0.error) }) == true {
            throw .temporarilyUnavailable(status: status, description: body?.errorDescription)
        }
        throw .tokenRequestFailed(status: status, code: body?.error, description: body?.errorDescription)
    }

    /// `application/x-www-form-urlencoded`, keys sorted so the body is
    /// stable. Everything but RFC 3986 unreserved characters is escaped.
    static func formEncoded(_ parameters: [String: String]) -> String {
        parameters
            .sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

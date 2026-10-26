import Foundation
import Testing
@testable import GraphAuth

/// The token requests and how their responses are classified.
@Suite("TokenEndpoint")
struct TokenEndpointTests {
    private static func endpoint(_ transport: FakeTokenTransport) throws -> TokenEndpoint {
        try TokenEndpoint(configuration: TestRegistration.configuration(), transport: transport)
    }

    private static let scope = "openid profile offline_access User.Read Calendars.Read Calendars.Read.Shared"

    // MARK: - Requests

    @Test("code redemption posts the code, verifier and redirect, with no secret")
    func redeemRequest() async throws {
        let transport = FakeTokenTransport(.tokens(access: "at", refresh: "rt", idToken: "id"))
        let response = try await Self.endpoint(transport).redeem(code: "auth-code", verifier: "verifier-1")

        #expect(response == TokenResponse(accessToken: "at", expiresIn: 3600, refreshToken: "rt", idToken: "id"))
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString
            == "https://login.microsoftonline.com/\(TestRegistration.tenantID)/oauth2/v2.0/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        // An Origin header would make Entra treat this as a SPA and refuse it.
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(try form(request) == [
            "client_id": TestRegistration.clientID,
            "grant_type": "authorization_code",
            "code": "auth-code",
            "redirect_uri": "msauth.com.synderys.biscotti://auth",
            "code_verifier": "verifier-1",
            "scope": Self.scope
        ])
    }

    @Test("refresh posts the refresh token")
    func refreshRequest() async throws {
        let transport = FakeTokenTransport(.tokens(access: "at-2", refresh: "rt-2"))
        let response = try await Self.endpoint(transport).refresh(refreshToken: "rt-1")

        #expect(response.accessToken == "at-2")
        #expect(response.refreshToken == "rt-2")
        let request = try #require(await transport.requests.first)
        #expect(try form(request) == [
            "client_id": TestRegistration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": "rt-1",
            "scope": Self.scope
        ])
    }

    @Test("form encoding escapes everything but unreserved characters")
    func formEncoding() {
        #expect(TokenEndpoint.formEncoded(["b": "x y+z/=&", "a": "0.AX4-_~"]) == "a=0.AX4-_~&b=x%20y%2Bz%2F%3D%26")
    }

    @Test("a network failure is a transport error")
    func transportFailure() async throws {
        let transport = FakeTokenTransport(.failure(URLError(.notConnectedToInternet)))
        await #expect(throws: GraphAuthError.transport(URLError(.notConnectedToInternet).localizedDescription)) {
            try await Self.endpoint(transport).refresh(refreshToken: "rt-1")
        }
    }

    // MARK: - Responses

    @Test("expires_in is accepted as a number or a string")
    func expiresInForms() throws {
        let number = try TokenEndpoint.interpret(
            data: Data(#"{"access_token":"a","expires_in":3599}"#.utf8), status: 200
        )
        #expect(number.expiresIn == 3599)
        let text = try TokenEndpoint.interpret(
            data: Data(#"{"access_token":"a","expires_in":"4000"}"#.utf8), status: 200
        )
        #expect(text.expiresIn == 4000)
        #expect(text.refreshToken == nil)
        #expect(text.idToken == nil)
    }

    @Test("a 200 that isn't a token response (captive portal) is invalid, not a refusal")
    func garbled200() {
        let error = #expect(throws: GraphAuthError.self) {
            try TokenEndpoint.interpret(data: Data("<html>Sign in to Wi-Fi</html>".utf8), status: 200)
        }
        if case .invalidTokenResponse = error {} else {
            Issue.record("expected invalidTokenResponse, got \(String(describing: error))")
        }
        // A portal page must not sign the user out.
        #expect(!GraphTokenProvider.invalidatesSession(error ?? .notSignedIn))
        #expect(throws: GraphAuthError.invalidTokenResponse("empty access_token")) {
            try TokenEndpoint.interpret(data: Data(#"{"access_token":"","expires_in":1}"#.utf8), status: 200)
        }
    }

    @Test(
        "errors only a sign-in fixes need reauthentication",
        arguments: ["invalid_grant", "interaction_required", "login_required", "consent_required"]
    )
    func reauthenticationErrors(code: String) {
        let body = jsonString(["error": code, "error_description": "AADSTS70043: The refresh token has expired.\r\nTrace ID: 1"])
        #expect(throws: GraphAuthError.reauthenticationRequired(
            code: code, description: "AADSTS70043: The refresh token has expired.\r\nTrace ID: 1"
        )) {
            try TokenEndpoint.interpret(data: Data(body.utf8), status: 400)
        }
    }

    @Test("outages and throttling are temporary")
    func transientErrors() {
        #expect(throws: GraphAuthError.temporarilyUnavailable(status: 503, description: nil)) {
            try TokenEndpoint.interpret(data: Data("Service Unavailable".utf8), status: 503)
        }
        #expect(throws: GraphAuthError.temporarilyUnavailable(status: 429, description: nil)) {
            try TokenEndpoint.interpret(data: Data(), status: 429)
        }
        let body = jsonString(["error": "temporarily_unavailable", "error_description": "AADSTS90033"])
        #expect(throws: GraphAuthError.temporarilyUnavailable(status: 400, description: "AADSTS90033")) {
            try TokenEndpoint.interpret(data: Data(body.utf8), status: 400)
        }
    }

    @Test("other refusals keep Entra's code; a bare status has none")
    func otherErrors() {
        let body = jsonString(["error": "invalid_client", "error_description": "AADSTS7000218: client_assertion required"])
        #expect(throws: GraphAuthError.tokenRequestFailed(
            status: 401, code: "invalid_client", description: "AADSTS7000218: client_assertion required"
        )) {
            try TokenEndpoint.interpret(data: Data(body.utf8), status: 401)
        }
        #expect(throws: GraphAuthError.tokenRequestFailed(status: 407, code: nil, description: nil)) {
            try TokenEndpoint.interpret(data: Data("Proxy Authentication Required".utf8), status: 407)
        }
    }

    @Test("user messages show the first line of Entra's description")
    func userMessages() {
        let error = GraphAuthError.reauthenticationRequired(
            code: "invalid_grant", description: "AADSTS50173: The provided grant has expired.\r\nTrace ID: x\r\nCorrelation ID: y"
        )
        #expect(error.userMessage == "Microsoft 365 needs you to sign in again: AADSTS50173: The provided grant has expired.")
        #expect(GraphAuthError.tokenRequestFailed(status: 407, code: nil, description: nil).userMessage
            == "Microsoft sign-in failed: HTTP 407")
        #expect(GraphAuthError.transport("x").isTransient)
        #expect(!GraphAuthError.reauthenticationRequired(code: "invalid_grant", description: nil).isTransient)
    }
}

/// Reading the account out of the ID token.
@Suite("IDTokenClaims")
struct IDTokenClaimsTests {
    @Test("the account comes from the claims")
    func account() throws {
        let claims = try IDTokenClaims(jwt: makeIDToken(janeClaims(nonce: "n1")))
        let account = try claims.account(for: TestRegistration.configuration(), nonce: "n1")
        #expect(account == TestRegistration.jane)
    }

    @Test("email stands in for a missing preferred_username")
    func emailFallback() throws {
        var raw = janeClaims()
        raw["preferred_username"] = " "
        raw["email"] = "jane.doe@synderys.com"
        let account = try IDTokenClaims(jwt: makeIDToken(raw)).account(for: TestRegistration.configuration(), nonce: nil)
        #expect(account.username == "jane.doe@synderys.com")
    }

    @Test("a token for another app, tenant or sign-in is rejected")
    func rejected() throws {
        let configuration = try TestRegistration.configuration()
        var otherApp = janeClaims()
        otherApp["aud"] = "99999999-2222-3333-4444-555555555555"
        #expect(throws: GraphAuthError.invalidIDToken("issued to another application")) {
            try IDTokenClaims(jwt: makeIDToken(otherApp)).account(for: configuration, nonce: nil)
        }
        var otherTenant = janeClaims()
        otherTenant["tid"] = "ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"
        #expect(throws: GraphAuthError.invalidIDToken("issued by another tenant")) {
            try IDTokenClaims(jwt: makeIDToken(otherTenant)).account(for: configuration, nonce: nil)
        }
        #expect(throws: GraphAuthError.invalidIDToken("nonce does not match the sign-in request")) {
            try IDTokenClaims(jwt: makeIDToken(janeClaims(nonce: "n1"))).account(for: configuration, nonce: "n2")
        }
        var noOID = janeClaims()
        noOID["oid"] = nil
        #expect(throws: GraphAuthError.invalidIDToken("missing tid or oid")) {
            try IDTokenClaims(jwt: makeIDToken(noOID)).account(for: configuration, nonce: nil)
        }
    }

    @Test("a domain tenant can't check tid, so any tid is accepted")
    func domainTenant() throws {
        let configuration = try GraphAuthConfiguration(clientID: TestRegistration.clientID, tenant: "synderys.com")
        var claims = janeClaims()
        claims["tid"] = "ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"
        let account = try IDTokenClaims(jwt: makeIDToken(claims)).account(for: configuration, nonce: nil)
        #expect(account.tenantID == "ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    @Test("a token that isn't a compact JWT is rejected")
    func malformed() {
        #expect(throws: GraphAuthError.invalidIDToken("not a compact JWT")) {
            try IDTokenClaims(jwt: "only.two")
        }
        #expect(throws: GraphAuthError.invalidIDToken("not a compact JWT")) {
            try IDTokenClaims(jwt: "a.!!!.c")
        }
    }
}

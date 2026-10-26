import Foundation
import Testing
@testable import GraphAuth

/// PKCE, the authorize URL, and checking the redirect.
@Suite("AuthorizationRequest")
struct AuthorizationRequestTests {
    @Test("PKCE S256 matches the RFC 7636 appendix B vector")
    func pkceVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("generated verifiers are 43 base64url characters and differ")
    func pkceGenerate() {
        let first = PKCE.generate()
        let second = PKCE.generate()
        #expect(first.verifier.count == 43)
        #expect(first.verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(first.verifier != second.verifier)
        #expect(PKCE(verifier: first.verifier).challenge == first.challenge)
    }

    @Test("base64url round-trips without padding")
    func base64URL() throws {
        let bytes = Data([0xFB, 0xFF, 0xBF, 0x00, 0x01])
        let encoded = bytes.base64URLEncodedString()
        #expect(encoded == "-_-_AAE")
        #expect(try #require(Data(base64URLEncoded: encoded)) == bytes)
    }

    @Test("the authorize URL carries the code flow, PKCE and the account picker")
    func authorizeURL() throws {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let request = try AuthorizationRequest(
            configuration: TestRegistration.configuration(),
            pkce: pkce,
            state: "state-1",
            nonce: "nonce-1"
        )
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.host == "login.microsoftonline.com")
        #expect(components.path == "/\(TestRegistration.tenantID)/oauth2/v2.0/authorize")
        #expect(queryItems(request.url) == [
            "client_id": TestRegistration.clientID,
            "response_type": "code",
            "redirect_uri": "msauth.com.synderys.biscotti://auth",
            "response_mode": "query",
            "scope": "openid profile offline_access User.Read Calendars.Read Calendars.Read.Shared",
            "state": "state-1",
            "nonce": "nonce-1",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
            "prompt": "select_account"
        ])
    }

    @Test("a reconnect pre-fills the username instead of the picker")
    func loginHint() throws {
        let request = try AuthorizationRequest(
            configuration: TestRegistration.configuration(),
            loginHint: "jane@synderys.com"
        )
        let items = queryItems(request.url)
        #expect(items["login_hint"] == "jane@synderys.com")
        #expect(items["prompt"] == nil)
    }

    @Test("each request gets its own state, nonce and verifier")
    func freshSecrets() throws {
        let configuration = try TestRegistration.configuration()
        let first = AuthorizationRequest(configuration: configuration)
        let second = AuthorizationRequest(configuration: configuration)
        #expect(first.state != second.state)
        #expect(first.nonce != second.nonce)
        #expect(first.pkce != second.pkce)
    }

    @Test("the redirect yields the code when state matches")
    func callbackCode() throws {
        let request = try AuthorizationRequest(configuration: TestRegistration.configuration(), state: "s1")
        let callback = try #require(URL(string: "msauth.com.synderys.biscotti://auth?code=0.AX4abc&state=s1&session_state=x"))
        #expect(try request.authorizationCode(from: callback) == "0.AX4abc")
    }

    @Test("a mismatched state or missing code is rejected")
    func callbackRejected() throws {
        let request = try AuthorizationRequest(configuration: TestRegistration.configuration(), state: "s1")
        let wrongState = try #require(URL(string: "msauth.com.synderys.biscotti://auth?code=abc&state=s2"))
        #expect(throws: GraphAuthError.invalidCallback("state does not match the request")) {
            try request.authorizationCode(from: wrongState)
        }
        let noCode = try #require(URL(string: "msauth.com.synderys.biscotti://auth?state=s1"))
        #expect(throws: GraphAuthError.invalidCallback("no authorization code")) {
            try request.authorizationCode(from: noCode)
        }
    }

    @Test("an error redirect reports Entra's error, not the state")
    func callbackError() throws {
        let request = try AuthorizationRequest(configuration: TestRegistration.configuration(), state: "s1")
        let callback = try #require(URL(
            string: "msauth.com.synderys.biscotti://auth?error=access_denied&error_description=AADSTS65004%3a+User+declined+to+consent.&state=other"
        ))
        let denied = GraphAuthError.authorizationDenied(
            code: "access_denied", description: "AADSTS65004: User declined to consent."
        )
        #expect(throws: denied) {
            try request.authorizationCode(from: callback)
        }
        #expect(denied.userMessage == "Microsoft sign-in didn't complete: AADSTS65004: User declined to consent.")
    }

    @Test("the code is form-decoded: %2B is a plus, + is a space")
    func callbackFormDecoding() throws {
        let request = try AuthorizationRequest(configuration: TestRegistration.configuration(), state: "s1")
        let callback = try #require(URL(string: "msauth.com.synderys.biscotti://auth?code=a%2Bb%2Fc&state=s1"))
        #expect(try request.authorizationCode(from: callback) == "a+b/c")
    }
}

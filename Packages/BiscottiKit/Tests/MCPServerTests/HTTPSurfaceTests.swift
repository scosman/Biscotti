import Foundation
import Testing
@testable import MCPServer

/// The HTTP surface every MCP client (and every hostile probe) sees:
/// method routing, path routing, Origin enforcement, and body limits.
/// Byte-level cases go through the raw-socket client because URLSession
/// cannot set `Origin` or suppress `Host`.
@Suite("MCP HTTP surface")
struct HTTPSurfaceTests {
    @Test("GET /mcp is 405 with Allow: POST")
    func getMethodNotAllowed() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            let response = try await RawHTTPClient.send(
                port: fixture.port,
                request: .init(method: "GET")
            )
            #expect(response.status == 405)
            #expect(response.headers["allow"] == "POST")
        }
    }

    @Test("POST to a foreign path is 404")
    func foreignPathNotFound() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            let response = try await RawHTTPClient.send(
                port: fixture.port,
                request: .init(path: "/other", headers: jsonHeaders())
            )
            #expect(response.status == 404)
        }
    }

    @Test("Body over 1 MB is 413")
    func oversizedBodyRejected() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            let oversized = Data(repeating: 0x61, count: MCPServerConfiguration.maxBodyBytes + 1)
            let response = try await RawHTTPClient.send(
                port: fixture.port,
                request: .init(
                    headers: jsonHeaders(),
                    body: oversized,
                    stopSendingOnResponse: true
                )
            )
            #expect(response.status == 413)
        }
    }

    @Test("Malformed JSON body is 400")
    func malformedJSONRejected() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            let response = try await RawHTTPClient.send(
                port: fixture.port,
                request: .init(headers: jsonHeaders(), body: Data("this is not json".utf8))
            )
            #expect(response.status == 400)
        }
    }

    @Test("JSON-RPC notification is 202 with empty body")
    func notificationAccepted() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
            let response = try await RawHTTPClient.send(
                port: fixture.port,
                request: .init(headers: jsonHeaders(), body: notification)
            )
            #expect(response.status == 202)
            #expect(response.body.isEmpty)
        }
    }

    @Test("Foreign Origin is 403")
    func foreignOriginForbidden() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            let initialize = initializeBody()
            let response = try await RawHTTPClient.send(
                port: fixture.port,
                request: .init(
                    headers: jsonHeaders() + [("Origin", "http://evil.example")],
                    body: initialize
                )
            )
            #expect(response.status == 403)
        }
    }

    @Test("Absent Origin and Host matching the bound port are allowed")
    func noOriginAndLocalHostAllowed() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            // The raw client sends Host: 127.0.0.1:<port> and no Origin; a
            // valid initialize request must go through end to end.
            let response = try await RawHTTPClient.send(
                port: fixture.port,
                request: .init(headers: jsonHeaders(), body: initializeBody())
            )
            #expect(response.status == 200)
            #expect(response.headers["content-type"]?.hasPrefix("application/json") == true)
        }
    }

    @Test("Origin naming a foreign port is 403")
    func foreignPortOriginForbidden() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            let response = try await RawHTTPClient.send(
                port: fixture.port,
                request: .init(
                    headers: jsonHeaders() + [("Origin", "http://127.0.0.1:9999")],
                    body: initializeBody()
                )
            )
            #expect(response.status == 403)
        }
    }
}

private func jsonHeaders() -> [(String, String)] {
    [("Content-Type", "application/json"), ("Accept", "application/json")]
}

private func initializeBody() -> Data {
    Data(
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"raw-test","version":"0"}}}"#
            .utf8
    )
}

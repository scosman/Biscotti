import Foundation
import Testing
@testable import MCPServer

/// The protocol surface a real MCP client uses, driven with `URLSession`
/// over the real listener: initialize handshake, then the tool catalog.
@Suite("MCP JSON-RPC round trip")
struct MCPRoundTripTests {
    static let expectedToolNames = [
        "biscotti_query_meetings",
        "biscotti_get_meeting",
        "biscotti_get_transcript"
    ]

    @Test("initialize then tools/list")
    func initializeAndListTools() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            let initialize = try await JSONRPCClient.post(
                port: fixture.port,
                method: "initialize",
                params: [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [:] as [String: Any],
                    "clientInfo": ["name": "MCPServerTests", "version": "0"]
                ]
            )
            #expect(initialize.status == 200)

            guard let result = initialize.body["result"] as? [String: Any] else {
                Issue.record("initialize response missing result: \(initialize.body)")
                return
            }
            let serverInfo = result["serverInfo"] as? [String: Any]
            #expect(serverInfo?["name"] as? String == "Biscotti")
            #expect(result["protocolVersion"] as? String == "2025-11-25")
            let capabilities = result["capabilities"] as? [String: Any]
            #expect(capabilities?["tools"] != nil)

            let listTools = try await JSONRPCClient.post(port: fixture.port, method: "tools/list")
            #expect(listTools.status == 200)
            let toolsResult = listTools.body["result"] as? [String: Any]
            let tools = toolsResult?["tools"] as? [[String: Any]] ?? []
            let names = tools.compactMap { $0["name"] as? String }
            #expect(names.sorted() == Self.expectedToolNames.sorted())
            for tool in tools {
                #expect((tool["description"] as? String)?.isEmpty == false)
                #expect((tool["inputSchema"] as? [String: Any])?.isEmpty == false)
                #expect((tool["outputSchema"] as? [String: Any])?.isEmpty == false)
            }
        }
    }

    @Test("tools/list works without prior initialize (stateless, no sessions)")
    func toolsListWithoutInitialize() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            let response = try await JSONRPCClient.post(port: fixture.port, method: "tools/list")
            #expect(response.status == 200)
            let result = response.body["result"] as? [String: Any]
            let tools = result?["tools"] as? [[String: Any]]
            #expect(tools?.count == Self.expectedToolNames.count)
        }
    }

    /// Regression: a shared `MCP.Server` latches `initialized` after the
    /// first handshake, so every later client got -32600 "Server is already
    /// initialized". Stateless HTTP must serve each client independently
    /// (functional spec §3, §9).
    @Test("sequential independent clients can each initialize, then tools still work")
    func sequentialClientsEachInitialize() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            // Client A handshakes over URLSession (which may pool both
            // requests onto one keep-alive connection — the fix must be
            // per-request, not per-connection).
            let first = try await Self.handshake(port: fixture.port, client: "client-a", id: 11)
            Self.assertHandshake(first, clientID: 11)

            // Client B — a second logical client against the same running
            // listener — must get its own handshake result. This used to be
            // the -32600 "already initialized" failure.
            let second = try await Self.handshake(port: fixture.port, client: "client-b", id: 22)
            Self.assertHandshake(second, clientID: 22)

            // Client C on its own socket (the raw client always closes) —
            // the distinct-TCP leg.
            let third = try await Self.rawHandshake(port: fixture.port, id: 33)
            #expect(third.status == 200)
            #expect(third.body.range(of: Data("\"serverInfo\"".utf8)) != nil)

            // After the later handshakes, the surface still serves tools.
            let listTools = try await JSONRPCClient.post(
                port: fixture.port,
                method: "tools/list",
                id: 44
            )
            #expect(listTools.status == 200)
            #expect(listTools.body["error"] == nil)
            let toolsResult = listTools.body["result"] as? [String: Any]
            let tools = toolsResult?["tools"] as? [[String: Any]] ?? []
            let names = tools.compactMap { $0["name"] as? String }
            #expect(names.sorted() == Self.expectedToolNames.sorted())

            let call = try await JSONRPCClient.post(
                port: fixture.port,
                method: "tools/call",
                params: [
                    "name": "biscotti_query_meetings",
                    "arguments": ["after": "2000-01-01"] as [String: Any]
                ],
                id: 55
            )
            #expect(call.status == 200)
            #expect(call.body["error"] == nil)
            #expect((call.body["result"] as? [String: Any])?["structuredContent"] != nil)
        }
    }

    /// Functional spec §9: "two clients connected at once". Two requests in
    /// flight at the same time — using the **same JSON-RPC id**, which a
    /// shared transport keyed waiters by and would drop one request forever —
    /// must each get their own result (independent per-request transports
    /// have independent waiter tables).
    @Test("concurrent requests with the same JSON-RPC id both complete")
    func concurrentSameIDRequestsBothComplete() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            async let handshake = Self.handshake(
                port: fixture.port,
                client: "concurrent-a",
                id: 7
            )
            async let listTools = JSONRPCClient.post(
                port: fixture.port,
                method: "tools/list",
                id: 7
            )

            let handshakeResponse = try await handshake
            Self.assertHandshake(handshakeResponse, clientID: 7)
            let toolsResponse = try await listTools
            #expect(toolsResponse.status == 200)
            #expect(toolsResponse.body["error"] == nil)
            #expect(toolsResponse.body["id"] as? Int == 7)
            let tools = (toolsResponse.body["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            #expect(tools?.count == Self.expectedToolNames.count)
        }
    }

    // MARK: - Client handshake helpers

    private static func handshake(
        port: Int,
        client: String,
        id: Int
    ) async throws -> (status: Int, body: [String: Any]) {
        try await JSONRPCClient.post(
            port: port,
            method: "initialize",
            params: [
                "protocolVersion": "2025-11-25",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": client, "version": "0"]
            ],
            id: id
        )
    }

    private static func assertHandshake(
        _ response: (status: Int, body: [String: Any]),
        clientID: Int
    ) {
        #expect(response.status == 200)
        #expect(response.body["error"] == nil)
        #expect((response.body["result"] as? [String: Any])?["serverInfo"] != nil)
        #expect(response.body["id"] as? Int == clientID)
    }

    private static func rawHandshake(port: Int, id: Int) async throws -> RawHTTPResponse {
        let body = Data(
            #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"raw-client","version":"0"}}}"#
                .utf8
        )
        return try await RawHTTPClient.send(
            port: port,
            request: .init(
                headers: [
                    ("Content-Type", "application/json"),
                    ("Accept", "application/json")
                ],
                body: body
            )
        )
    }
}

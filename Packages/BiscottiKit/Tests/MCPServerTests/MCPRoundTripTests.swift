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
}

import Foundation
import MCP
import Testing
@testable import MCPServer

/// The hand-rolled resource limits from functional spec §7: the
/// concurrent-connection cap and idle-connection eviction.
@Suite("MCP connection limits")
struct ConnectionLimitTests {
    @Test("connection past the cap is closed without a response")
    func connectionOverCapClosed() async throws {
        try await MCPServerFixture.withRunningServer { fixture in
            // Hold every slot open with silent connections…
            var held: [RawHTTPClient.HeldConnection] = []
            defer { held.forEach { $0.close() } }
            for _ in 0 ..< MCPServerConfiguration.maxConcurrentConnections {
                try await held.append(RawHTTPClient.connect(port: fixture.port))
            }

            // …then wait out the accept backlog so all 16 have counted
            // server-side before the probe connects. The next connection
            // must be closed by the limiter the moment it becomes active —
            // closed with no response bytes.
            try await Task.sleep(for: .milliseconds(250))
            let wire = try await RawHTTPClient.awaitServerClose(port: fixture.port)
            #expect(wire.isEmpty)
        }
    }

    @Test("idle connection is closed after the timeout")
    func idleConnectionEvicted() async throws {
        // A direct listener with a short injected timeout: through the
        // controller the timeout is fixed at the production 120 s. The
        // handle closure is never invoked — the client never speaks.
        let listener = HTTPListener { _ in
            MCP.HTTPResponse.error(statusCode: 500, .internalError("unused"))
        }
        let port = try await listener.start(
            host: MCPServerConfiguration.host,
            port: 0,
            idleTimeout: .milliseconds(300)
        )

        // A connected-but-silent client must be closed by the idle timer
        // (with nothing sent first), not left open forever — otherwise
        // awaitServerClose throws when its receive timeout expires.
        let wire = try await RawHTTPClient.awaitServerClose(port: port)
        #expect(wire.isEmpty)

        await listener.shutdown()
    }
}

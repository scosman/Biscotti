import BiscottiTestSupport
import DataStore
import Foundation
import MCPServer
import Testing
@testable import AppCore

#if canImport(Darwin)
    import Darwin
#endif

/// Polls a condition on the MainActor until it holds (2 s budget), so tests
/// can observe the async notification-observer path without fixed sleeps.
private func pollUntil(
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0 ..< 40 {
        try await Task.sleep(for: .milliseconds(50))
        if await condition() { return }
    }
}

/// AppCore ownership of the MCP server: start-on-launch gated by the
/// persisted setting, and the live start/stop path through the
/// `.mcpServerEnabledDidChange` observer.
///
/// These are the only tests that exercise AppCore's public `start()` on the
/// production port (8516); they are sequenced within a single test function
/// so parallel test execution can never contend for the port. When a foreign
/// process holds 8516 (typically the real Biscotti app running with MCP on),
/// that test disables itself — it cannot bind the fixed port and nothing is
/// wrong with the code. CI runners always have the port free, so the test
/// runs there.
@Suite("AppCore -- MCP server wiring")
struct MCPServerWiringTests {
    @Test("server does not start on launch when the setting is off")
    @MainActor
    func serverNotStartedWhenDisabled() async throws {
        let fix = try makeCoreFixture(testName: "MCPOff")
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
            $0.mcpServerEnabled = false
        }

        await fix.core.onLaunch()

        #expect(fix.core.mcpServer.state == .stopped)
    }

    @Test(
        "server starts on launch when enabled; the setting-change observer flips it live",
        .disabled(
            if: MCPServerWiringTests.defaultPortHeldByAnotherProcess,
            "port 8516 is held by another process (e.g. the real Biscotti app running with MCP on)"
        )
    )
    @MainActor
    func serverStartsWhenEnabledAndObserverFlips() async throws {
        let fix = try makeCoreFixture(testName: "MCPOn")
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
            $0.mcpServerEnabled = true
        }

        await fix.core.onLaunch()

        #expect(
            fix.core.mcpServer.state == .running(MCPServerConfiguration.endpointURL)
        )

        // Flip off through the real path: persist, then post the
        // notification SettingsUI posts. The observer applies it async.
        try await fix.store.updateSettings { $0.mcpServerEnabled = false }
        NotificationCenter.default.post(
            name: .mcpServerEnabledDidChange, object: nil
        )
        try await pollUntil { fix.core.mcpServer.state == .stopped }
        #expect(fix.core.mcpServer.state == .stopped)

        // Flip back on — the same listener path must rebind the fixed port.
        try await fix.store.updateSettings { $0.mcpServerEnabled = true }
        NotificationCenter.default.post(
            name: .mcpServerEnabledDidChange, object: nil
        )
        try await pollUntil {
            fix.core.mcpServer.state == .running(MCPServerConfiguration.endpointURL)
        }
        #expect(
            fix.core.mcpServer.state == .running(MCPServerConfiguration.endpointURL)
        )

        // Release the port and the listener's event-loop thread — the
        // fixture's cleanup only deletes files, and the listener has no
        // deinit path (see HTTPListener.shutdown).
        await fix.core.mcpServer.stop()
    }

    /// Whether a foreign process is listening on the fixed production port.
    /// Probes with `SO_REUSEADDR` (matching the listener's own socket
    /// options), so TIME_WAIT leftovers don't count — only a live listener
    /// does.
    private static var defaultPortHeldByAnotherProcess: Bool {
        let probeFD = socket(AF_INET, SOCK_STREAM, 0)
        guard probeFD >= 0 else { return false }
        defer { close(probeFD) }

        var reuse: Int32 = 1
        setsockopt(
            probeFD, SOL_SOCKET, SO_REUSEADDR,
            &reuse, socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(MCPServerConfiguration.port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(MCPServerConfiguration.host))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(
                    probeFD, sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) != 0
            }
        }
    }
}

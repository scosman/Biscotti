import BiscottiTestSupport
import Foundation
import MCPServer
import Testing
@testable import AppCore

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

/// The endpoint shape every running state must have: loopback host, `/mcp`
/// path, and a real port (the fixture's controller binds an ephemeral one).
@MainActor
private func isRunningAtLoopbackEndpoint(_ state: MCPServerState) -> Bool {
    if case let .running(url) = state {
        return url.host == "127.0.0.1" && url.path == "/mcp" && url.port != nil
    }
    return false
}

/// AppCore ownership of the MCP server: start-on-launch gated by the
/// persisted setting, and the live start/stop path through the
/// `.mcpServerEnabledDidChange` observer.
///
/// The fixture injects an ephemeral-port controller (production keeps the
/// fixed 8516): tests must never bind the production port, which the real
/// Biscotti app dogfoods.
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

    @Test("server starts on launch when enabled; the setting-change observer flips it live")
    @MainActor
    func serverStartsWhenEnabledAndObserverFlips() async throws {
        let fix = try makeCoreFixture(testName: "MCPOn")
        defer { fix.cleanup() }

        try await fix.store.updateSettings {
            $0.onboardingComplete = true
            $0.mcpServerEnabled = true
        }

        await fix.core.onLaunch()

        #expect(isRunningAtLoopbackEndpoint(fix.core.mcpServer.state))

        // Flip off through the real path: persist, then post the
        // notification SettingsUI posts. The observer applies it async.
        try await fix.store.updateSettings { $0.mcpServerEnabled = false }
        NotificationCenter.default.post(
            name: .mcpServerEnabledDidChange, object: nil
        )
        try await pollUntil { fix.core.mcpServer.state == .stopped }
        #expect(fix.core.mcpServer.state == .stopped)

        // Flip back on — the same listener path must rebind.
        try await fix.store.updateSettings { $0.mcpServerEnabled = true }
        NotificationCenter.default.post(
            name: .mcpServerEnabledDidChange, object: nil
        )
        try await pollUntil {
            isRunningAtLoopbackEndpoint(fix.core.mcpServer.state)
        }
        #expect(isRunningAtLoopbackEndpoint(fix.core.mcpServer.state))
    }
}

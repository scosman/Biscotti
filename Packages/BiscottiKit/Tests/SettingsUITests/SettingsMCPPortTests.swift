import AppCore
import BiscottiTestSupport
import Foundation
import Testing
@testable import DataStore
@testable import MCPServer
@testable import SettingsUI

// MARK: - MCP port field

/// The Settings port field. Each test that saves a port gets its own
/// `UserDefaults` suite, and every bind is an ephemeral port, never the
/// production 8516.
@Suite("SettingsViewModel -- MCP port")
@MainActor
struct SettingsMCPPortTests {
    /// Runs `body` with an empty suite and removes the suite afterwards.
    private func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let name = "SettingsMCPPortTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    @Test("mcpServerPort forwards the controller's port")
    func portForwardsController() throws {
        let fix = try makeCoreFixture(mcpServerPort: 54320)
        defer { fix.cleanup() }
        #expect(SettingsViewModel(core: fix.core).mcpServerPort == 54320)
    }

    @Test("setMCPServerPort persists and hands a stopped server the port")
    func setPortPersists() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        try await withDefaults { defaults in
            let viewModel = SettingsViewModel(core: fix.core)
            viewModel.mcpPortDefaults = defaults

            #expect(await viewModel.setMCPServerPort(54321))
            #expect(viewModel.mcpServerPort == 54321)
            #expect(defaults.integer(forKey: MCPServerConfiguration.portDefaultsKey) == 54321)
            #expect(fix.core.mcpServer.port == 54321)
            #expect(fix.core.mcpServer.state == .stopped)
        }
    }

    @Test("setMCPServerPort rejects ports out of range", arguments: [0, 80, 1023, 65536])
    func setPortRejectsOutOfRange(port: Int) async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        try await withDefaults { defaults in
            let viewModel = SettingsViewModel(core: fix.core)
            viewModel.mcpPortDefaults = defaults
            let serverPort = fix.core.mcpServer.port

            #expect(await viewModel.setMCPServerPort(port) == false)
            #expect(viewModel.mcpServerPort == serverPort)
            #expect(defaults.object(forKey: MCPServerConfiguration.portDefaultsKey) == nil)
            #expect(fix.core.mcpServer.port == serverPort)
        }
    }

    @Test("a new port recovers a port-in-use failure")
    func newPortRecoversFailure() async throws {
        let holder = try MCPServerController(store: DataStore(storage: .inMemory), port: 0)
        await holder.start()
        guard case let .running(url) = holder.state, let heldPort = url.port else {
            Issue.record("holder did not start: \(holder.state)")
            return
        }

        let fix = try makeCoreFixture(mcpServerPort: heldPort)
        defer { fix.cleanup() }
        try await withDefaults { defaults in
            let viewModel = SettingsViewModel(core: fix.core)
            viewModel.mcpPortDefaults = defaults
            await fix.core.mcpServer.start()
            #expect(viewModel.mcpServerState == .failed(.portInUse(port: heldPort)))

            // A port that was just bound and released is very likely free.
            let probe = try MCPServerController(store: DataStore(storage: .inMemory), port: 0)
            await probe.start()
            guard case let .running(probeURL) = probe.state, let target = probeURL.port else {
                Issue.record("probe did not start: \(probe.state)")
                return
            }
            await probe.stop()

            await viewModel.setMCPServerPort(target)
            #expect(viewModel.mcpServerState == .running(MCPServerConfiguration.endpointURL(port: target)))

            // AppCore is process-lifetime by design — treat its controller
            // as never deinited; tests stop it explicitly.
            await fix.core.mcpServer.stop()
        }
        await holder.stop()
    }

    @Test(
        "port text parsing",
        arguments: [
            ("8517", 8517), (" 8517 ", 8517), ("1024", 1024), ("65535", 65535),
            ("", nil), ("80", nil), ("65536", nil), ("+8517", nil), ("-1", nil),
            ("85a7", nil), ("8 517", nil), ("٨٥١٧", nil)
        ] as [(String, Int?)]
    )
    func parsesPortText(text: String, expected: Int?) {
        #expect(SettingsViewModel.mcpPort(fromText: text) == expected)
    }
}

import AppCore
import BiscottiTestSupport
import Foundation
import Testing
@testable import DataStore
@testable import MCPServer
@testable import SettingsUI

// MARK: - MCP settings row

@Suite("SettingsViewModel -- MCP server")
@MainActor
struct SettingsMCPTests {
    @Test("mcpServerEnabled defaults to false")
    func mcpEnabledDefault() throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)
        #expect(viewModel.mcpServerEnabled == false)
    }

    @Test("load reads mcpServerEnabled from store")
    func mcpEnabledLoadedFromStore() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }

        try await fix.store.updateSettings { $0.mcpServerEnabled = true }

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()
        #expect(viewModel.mcpServerEnabled == true)
    }

    @Test("setMCPServerEnabled persists and posts notification")
    func setMCPEnabledPersistsAndPosts() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }

        let viewModel = SettingsViewModel(core: fix.core)

        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: .mcpServerEnabledDidChange,
            object: nil,
            queue: .main
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(token) }

        await viewModel.setMCPServerEnabled(true)
        #expect(viewModel.mcpServerEnabled == true)
        #expect(received)

        let settings = try await fix.store.settings()
        #expect(settings.mcpServerEnabled == true)
    }

    @Test("mcpServerState forwards the controller's live state")
    func mcpStateForwardsController() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)

        #expect(viewModel.mcpServerState == .stopped)

        // Drive a real transition on the controller AppCore owns — the
        // internal ephemeral-port seam, so this never contends for 8516 —
        // and assert it is visible *through the forwarding property*.
        await fix.core.mcpServer.start(port: 0)
        guard case .running = viewModel.mcpServerState else {
            Issue.record(
                "expected .running through mcpServerState, got \(viewModel.mcpServerState)"
            )
            await fix.core.mcpServer.stop()
            return
        }

        await fix.core.mcpServer.stop()
        #expect(viewModel.mcpServerState == .stopped)
    }
}

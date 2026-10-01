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
        // The fixture's controller is configured for an ephemeral port, so
        // driving the public start() never contends for the production
        // 8516 — and the transition is still visible through the
        // forwarding property, which is what this test pins.
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)

        #expect(viewModel.mcpServerState == .stopped)

        await fix.core.mcpServer.start()
        guard case .running = viewModel.mcpServerState else {
            Issue.record(
                "expected .running through mcpServerState, got \(viewModel.mcpServerState)"
            )
            // AppCore is process-lifetime by design — treat its controller
            // as never deinited; tests stop it explicitly.
            await fix.core.mcpServer.stop()
            return
        }

        // Behavior-asserting stop: the forwarding property must expose the
        // transition back to .stopped. AppCore is process-lifetime by
        // design — treat its controller as never deinited; tests stop it
        // explicitly.
        await fix.core.mcpServer.stop()
        #expect(viewModel.mcpServerState == .stopped)
    }

    @Test("bind conflict surfaces .failed with the user message copy")
    func failedStateRendersUserMessage() async throws {
        // Hold an ephemeral port with a second controller, then make the
        // AppCore-owned controller collide with it (same seeding as
        // MCPServerControllerTests, injected through the fixture's port
        // parameter so nothing here touches the production 8516).
        let holderStore = try DataStore(storage: .inMemory)
        let holder = MCPServerController(store: holderStore, port: 0)
        await holder.start()
        guard case let .running(url) = holder.state, let heldPort = url.port else {
            Issue.record("holder did not start: \(holder.state)")
            return
        }

        let fix = try makeCoreFixture(mcpServerPort: heldPort)
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)

        await fix.core.mcpServer.start()
        guard case let .failed(error) = viewModel.mcpServerState else {
            Issue.record(
                "expected .failed through mcpServerState, got \(viewModel.mcpServerState)"
            )
            await holder.stop()
            // If the bind unexpectedly succeeded the server is running, and
            // AppCore is process-lifetime by design — stop explicitly.
            await fix.core.mcpServer.stop()
            return
        }
        #expect(error == .portInUse(port: heldPort))
        #expect(
            error.userMessage
                == "Couldn't start: port \(heldPort) is already in use by another app."
        )

        await holder.stop()
        await fix.core.mcpServer.stop()
        #expect(viewModel.mcpServerState == .stopped)
    }

    @Test("Retry re-attempts the bind and recovers")
    func retryRecoversAfterFailure() async throws {
        // Seed .failed on an ephemeral port the fixture's controller is
        // configured for — retryMCPServer() re-attempts exactly that
        // port, so the recovery below is the real Retry path.
        let holderStore = try DataStore(storage: .inMemory)
        let holder = MCPServerController(store: holderStore, port: 0)
        await holder.start()
        guard case let .running(url) = holder.state, let heldPort = url.port else {
            Issue.record("holder did not start: \(holder.state)")
            return
        }

        let fix = try makeCoreFixture(mcpServerPort: heldPort)
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)

        await fix.core.mcpServer.start()
        guard case let .failed(error) = viewModel.mcpServerState else {
            Issue.record(
                "expected .failed through mcpServerState, got \(viewModel.mcpServerState)"
            )
            await holder.stop()
            // If the bind unexpectedly succeeded the server is running, and
            // AppCore is process-lifetime by design — stop explicitly.
            await fix.core.mcpServer.stop()
            return
        }
        #expect(error == .portInUse(port: heldPort))

        // Free the port, then Retry: the view model must drive the
        // controller from .failed back to .running on the same endpoint.
        await holder.stop()
        await viewModel.retryMCPServer()
        guard case let .running(reboundURL) = viewModel.mcpServerState else {
            Issue.record(
                "expected .running after retry, got \(viewModel.mcpServerState)"
            )
            return
        }
        #expect(reboundURL.port == heldPort)
        #expect(reboundURL.host == "127.0.0.1")
        #expect(reboundURL.path == "/mcp")

        // AppCore is process-lifetime by design — treat its controller
        // as never deinited; tests stop it explicitly.
        await fix.core.mcpServer.stop()
    }
}

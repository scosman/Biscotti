import DataStore
import Foundation
import Testing
@testable import MCPServer

/// `setPort`: the Settings port field moving the server live.
///
/// Like `MCPServerControllerTests`, every bind here is an ephemeral port
/// or one another in-test controller just held, never the production 8516.
@MainActor
@Suite("MCPServerController port change")
struct MCPServerControllerPortTests {
    @Test("setPort on a stopped server records the port without binding")
    func stoppedRecordsPort() async throws {
        let controller = try makeController()
        await controller.setPort(54321)
        #expect(controller.port == 54321)
        #expect(controller.state == .stopped)
    }

    @Test("setPort to the current port leaves a running server alone")
    func samePortIsNoOp() async throws {
        let controller = try makeController()
        await controller.start()
        guard case let .running(url) = controller.state else {
            Issue.record("expected .running, got \(controller.state)")
            return
        }

        await controller.setPort(controller.port)
        #expect(controller.state == .running(url))
        await controller.stop()
    }

    @Test("setPort moves a running server and releases the old port")
    func runningMovesToNewPort() async throws {
        let target = try await freedPort()
        let controller = try makeController()
        await controller.start()
        guard case let .running(url) = controller.state, let oldPort = url.port else {
            Issue.record("expected .running with a port, got \(controller.state)")
            return
        }

        await controller.setPort(target)
        guard case let .running(movedURL) = controller.state else {
            Issue.record("expected .running after setPort, got \(controller.state)")
            await controller.stop()
            return
        }
        #expect(movedURL.port == target)
        #expect(controller.port == target)
        let listTools = try await JSONRPCClient.post(port: target, method: "tools/list")
        #expect(listTools.status == 200)

        // The old listener is gone: its port binds again.
        let rebind = try makeController(port: oldPort)
        await rebind.start()
        #expect(rebind.state == .running(MCPServerConfiguration.endpointURL(port: oldPort)))
        await rebind.stop()
        await controller.stop()
    }

    @Test("setPort recovers a server that failed with port in use")
    func failedRecoversOnNewPort() async throws {
        let holder = try makeController()
        await holder.start()
        guard case let .running(url) = holder.state, let heldPort = url.port else {
            Issue.record("holder did not start: \(holder.state)")
            return
        }
        let contender = try makeController(port: heldPort)
        await contender.start()
        #expect(contender.state == .failed(.portInUse(port: heldPort)))

        let target = try await freedPort()
        await contender.setPort(target)
        #expect(contender.state == .running(MCPServerConfiguration.endpointURL(port: target)))

        await holder.stop()
        await contender.stop()
    }

    private func makeController(port: Int = 0) throws -> MCPServerController {
        let store = try DataStore(storage: .inMemory)
        return MCPServerController(store: store, port: port)
    }

    /// A port that was just bound and released, so it is very likely free
    /// (the same technique as the rebind tests).
    private func freedPort() async throws -> Int {
        let probe = try makeController()
        await probe.start()
        let port = try #require(runningPort(probe), "probe did not start: \(probe.state)")
        await probe.stop()
        return port
    }

    private func runningPort(_ controller: MCPServerController) -> Int? {
        if case let .running(url) = controller.state { return url.port }
        return nil
    }
}

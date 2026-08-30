import DataStore
import Foundation
import Testing
@testable import MCPServer

/// Controller lifecycle: idempotence, restart after stop (the port really
/// is released), the bind-conflict path, and rapid on/off/on serialization.
@MainActor
@Suite("MCPServerController lifecycle")
struct MCPServerControllerTests {
    @Test("start twice is a no-op")
    func doubleStartIsNoOp() async throws {
        let controller = try makeController()
        await controller.start(port: 0)
        guard case let .running(url) = controller.state else {
            Issue.record("expected .running, got \(controller.state)")
            return
        }

        // The second start must not rebind or fail — even though it targets
        // the fixed production port.
        await controller.start()

        guard case let .running(urlAfter) = controller.state else {
            Issue.record("expected .running after second start, got \(controller.state)")
            return
        }
        #expect(urlAfter == url)
        await controller.stop()
    }

    @Test("stop twice is a no-op")
    func doubleStopIsNoOp() async throws {
        let controller = try makeController()
        await controller.start(port: 0)
        await controller.stop()
        #expect(controller.state == .stopped)
        await controller.stop()
        #expect(controller.state == .stopped)
    }

    @Test("start → stop → start rebinds the same port")
    func restartRebindsSamePort() async throws {
        let controller = try makeController()
        await controller.start(port: 0)
        guard case let .running(url) = controller.state, let firstPort = url.port else {
            Issue.record("expected .running with a port, got \(controller.state)")
            return
        }

        await controller.stop()
        #expect(controller.state == .stopped)

        // Binding the exact port just released proves shutdown actually
        // returned it to the OS.
        await controller.start(port: firstPort)
        guard case let .running(urlAfter) = controller.state else {
            Issue.record("expected .running after restart, got \(controller.state)")
            return
        }
        #expect(urlAfter.port == firstPort)
        await controller.stop()
    }

    @Test("bind conflict surfaces .failed(.portInUse)")
    func portInUseFails() async throws {
        // Hold a port with a first server…
        let holder = try makeController()
        await holder.start(port: 0)
        guard case let .running(url) = holder.state, let heldPort = url.port else {
            Issue.record("holder did not start: \(holder.state)")
            return
        }

        // …then try to bind it again.
        let contender = try makeController()
        await contender.start(port: heldPort)
        #expect(contender.state == .failed(.portInUse(port: heldPort)))

        await holder.stop()
        await contender.stop()
        #expect(contender.state == .stopped)
    }

    @Test("applyEnabled(false) from .running reaches .stopped")
    func applyEnabledFalseStops() async throws {
        let controller = try makeController()
        await controller.start(port: 0)
        #expect(isRunning(controller))

        await controller.applyEnabled(false)
        #expect(controller.state == .stopped)
    }

    @Test("rapid on/off/on serializes to a consistent state")
    func rapidTogglingFinalStateWins() async throws {
        let controller = try makeController()

        // Fire the sequence without awaiting between calls. Whichever order
        // the calls enqueue in, the work queue must serialize them so no
        // listener is orphaned and the state matches reality.
        async let start1: Void = controller.start(port: 0)
        async let stop1: Void = controller.stop()
        async let start2: Void = controller.start(port: 0)
        await start1
        await stop1
        await start2

        switch controller.state {
        case let .running(url):
            // The surviving server must actually serve requests.
            guard let port = url.port else {
                Issue.record("running without a port")
                return
            }
            let listTools = try await JSONRPCClient.post(port: port, method: "tools/list")
            #expect(listTools.status == 200)
        case .stopped:
            break
        case .starting, .failed:
            Issue.record("inconsistent final state: \(controller.state)")
        }

        await controller.stop()
        #expect(controller.state == .stopped)
    }

    private func makeController() throws -> MCPServerController {
        let store = try DataStore(storage: .inMemory)
        return MCPServerController(store: store)
    }

    private func isRunning(_ controller: MCPServerController) -> Bool {
        if case .running = controller.state { return true }
        return false
    }
}

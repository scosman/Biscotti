import DataStore
import Foundation
import Testing
@testable import MCPServer

/// Controller lifecycle: idempotence, restart after stop (the port really
/// is released), the bind-conflict path, and rapid on/off/on serialization.
///
/// Every controller here binds an ephemeral port (0) or a port held by
/// another in-test controller — tests must never touch the production
/// port 8516, which the real app dogfoods.
@MainActor
@Suite("MCPServerController lifecycle")
struct MCPServerControllerTests {
    @Test("start twice is a no-op")
    func doubleStartIsNoOp() async throws {
        let controller = try makeController()
        await controller.start()
        guard case let .running(url) = controller.state else {
            Issue.record("expected .running, got \(controller.state)")
            return
        }

        // The second start must not rebind or fail.
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
        await controller.start()
        await controller.stop()
        #expect(controller.state == .stopped)
        await controller.stop()
        #expect(controller.state == .stopped)
    }

    @Test("stop releases the port for an immediate rebind")
    func stopReleasesPortForRebind() async throws {
        let controller = try makeController()
        await controller.start()
        guard case let .running(url) = controller.state, let firstPort = url.port else {
            Issue.record("expected .running with a port, got \(controller.state)")
            return
        }

        await controller.stop()
        #expect(controller.state == .stopped)

        // Binding the exact port just released proves shutdown actually
        // returned it to the OS.
        let rebind = try makeController(port: firstPort)
        await rebind.start()
        guard case let .running(urlAfter) = rebind.state else {
            Issue.record("expected .running after rebind, got \(rebind.state)")
            return
        }
        #expect(urlAfter.port == firstPort)
        await rebind.stop()
    }

    @Test("dropping a running controller releases the port (deinit safety net)")
    func deallocWhileRunningReleasesPort() async throws {
        // Bind an ephemeral port, then drop the only strong reference
        // without calling stop(): deinit must release the port (and the
        // listener's event-loop thread) so the same port can be rebound.
        var controller: MCPServerController? = try makeController()
        await controller?.start()
        guard case let .running(url)? = controller?.state, let heldPort = url.port else {
            Issue.record("controller did not start: \(String(describing: controller?.state))")
            return
        }
        controller = nil

        // The safety net is fire-and-forget, so the release lands
        // asynchronously: retry the exact port until it binds (2 s budget).
        let rebind = try makeController(port: heldPort)
        var rebound = false
        for _ in 0 ..< 40 {
            await rebind.start()
            if case .running = rebind.state {
                rebound = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(rebound)
        await rebind.stop()
    }

    @Test("bind conflict surfaces .failed(.portInUse)")
    func portInUseFails() async throws {
        // Hold a port with a first server…
        let holder = try makeController()
        await holder.start()
        guard case let .running(url) = holder.state, let heldPort = url.port else {
            Issue.record("holder did not start: \(holder.state)")
            return
        }

        // …then try to bind it again.
        let contender = try makeController(port: heldPort)
        await contender.start()
        #expect(contender.state == .failed(.portInUse(port: heldPort)))

        await holder.stop()
        await contender.stop()
        #expect(contender.state == .stopped)
    }

    @Test("applyEnabled(false) from .running reaches .stopped")
    func applyEnabledFalseStops() async throws {
        let controller = try makeController()
        await controller.start()
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
        async let start1: Void = controller.start()
        async let stop1: Void = controller.stop()
        async let start2: Void = controller.start()
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

    private func makeController(port: Int = 0) throws -> MCPServerController {
        let store = try DataStore(storage: .inMemory)
        return MCPServerController(store: store, port: port)
    }

    private func isRunning(_ controller: MCPServerController) -> Bool {
        if case .running = controller.state { return true }
        return false
    }
}

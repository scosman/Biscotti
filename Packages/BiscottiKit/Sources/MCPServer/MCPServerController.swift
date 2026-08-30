import DataStore
import Foundation
import MCP
import NIOConcurrencyHelpers
import NIOCore
import Observation

/// Owns the MCP server lifecycle: the `MCP.Server`, its
/// `StatelessHTTPServerTransport`, and the ``HTTPListener``. All three are
/// created inside `start()` and released in `stop()` — a stopped controller
/// holds one enum and a `DataStore` reference, nothing else. That is the
/// "zero overhead when off" contract (functional spec §1).
///
/// `@MainActor` because its only observer is SwiftUI; all blocking work is
/// awaited on other executors (NIO's event loops, the `DataStore` actor).
@MainActor @Observable
public final class MCPServerController {
    public private(set) var state: MCPServerState = .stopped

    private let store: DataStore
    /// Server version reported in `initialize`; from the app bundle when
    /// present (tests and SPM contexts get "0.0.0").
    private let serverVersion: String
    /// Serializes start/stop/applyEnabled: every call awaits the previous
    /// queued work first, so a rapid on/off/on sequence cannot leave an
    /// orphan listener. Final state wins.
    private var work: Task<Void, Never>?

    // Created in start(), released in stop(). Main-actor confined; the
    // underlying objects do their own synchronization.
    private var server: MCP.Server?
    private var transport: MCP.StatelessHTTPServerTransport?
    private var listener: HTTPListener?
    /// The box the listener's request closure reads; it is what lets the
    /// listener bind *before* the transport exists (see performStart).
    private var transportBox = NIOLockedValueBox<MCP.StatelessHTTPServerTransport?>(nil)

    public init(store: DataStore) {
        self.store = store
        serverVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Starts the server. Idempotent: a no-op when already running or
    /// starting; a fresh attempt after `.failed` (the Retry path).
    public func start() async {
        await start(port: MCPServerConfiguration.port)
    }

    /// Port-parameterized entry point for tests, which bind an ephemeral
    /// port (0) to stay parallel-safe.
    func start(port: Int) async {
        await enqueue { [self] in
            await performStart(port: port)
        }.value
    }

    /// Stops the listener and closes open connections. Idempotent.
    public func stop() async {
        await enqueue { [self] in
            await performStop()
        }.value
    }

    /// Reconciles the server with the user's intent (Settings toggle).
    public func applyEnabled(_ enabled: Bool) async {
        if enabled {
            await start()
        } else {
            await stop()
        }
    }

    // MARK: - Lifecycle

    private func performStart(port: Int) async {
        switch state {
        case .running, .starting:
            return
        case .stopped, .failed:
            break
        }

        state = .starting
        mcpServerLog.info("Starting MCP server on \(MCPServerConfiguration.host):\(port)")

        // Bind first: the transport's OriginValidator must be pinned to the
        // port we actually own (8516 in production, the ephemeral port in
        // tests) or it would 421 every request whose Host header names
        // another port.
        let listener = HTTPListener { [transportBox] request in
            guard let transport = transportBox.withLockedValue({ $0 }) else {
                return MCP.HTTPResponse.error(
                    statusCode: 503,
                    .internalError("Server is starting")
                )
            }
            return await transport.handleRequest(request)
        }
        self.listener = listener

        let boundPort: Int
        do {
            boundPort = try await listener.start(host: MCPServerConfiguration.host, port: port)
        } catch {
            // The listener tore itself down inside `start`; drop the dead
            // reference so `self.listener != nil` implies something is bound.
            self.listener = nil
            let startError =
                error as? MCPServerStartError ?? .bindFailed(error.localizedDescription)
            mcpServerLog.error("MCP server failed to start: \(startError.userMessage, privacy: .public)")
            state = .failed(startError)
            return
        }

        let server = await makeServer()
        let transport = makeTransport(boundPort: boundPort)

        do {
            try await server.start(transport: transport)
        } catch {
            mcpServerLog.error(
                "MCP server failed to start: \(error.localizedDescription, privacy: .public)"
            )
            await listener.shutdown()
            self.listener = nil
            state = .failed(.bindFailed(error.localizedDescription))
            return
        }

        self.server = server
        self.transport = transport
        transportBox.withLockedValue { $0 = transport }

        let endpoint = URL(string: "http://\(MCPServerConfiguration.host):\(boundPort)\(MCPServerConfiguration.path)")
        state = .running(endpoint ?? MCPServerConfiguration.endpointURL)
        mcpServerLog.info("MCP server running on port \(boundPort)")
    }

    private func makeServer() async -> MCP.Server {
        let server = MCP.Server(
            name: "Biscotti",
            version: serverVersion,
            instructions: Self.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        // Phase 2 replaces the empty catalog with MeetingToolCatalog and
        // adds the CallTool handler.
        await server.withMethodHandler(MCP.ListTools.self) { _ in
            MCP.ListTools.Result(tools: [])
        }
        return server
    }

    /// Explicit validation pipeline rather than the transport's defaults, so
    /// the Origin check is pinned to the bound port.
    private func makeTransport(boundPort: Int) -> MCP.StatelessHTTPServerTransport {
        MCP.StatelessHTTPServerTransport(validationPipeline: MCP.StandardValidationPipeline(validators: [
            MCP.OriginValidator.localhost(port: boundPort),
            MCP.AcceptHeaderValidator(mode: .jsonOnly),
            MCP.ContentTypeValidator(),
            MCP.ProtocolVersionValidator()
        ]))
    }

    private func performStop() async {
        guard state != .stopped else { return }

        if let listener {
            await listener.shutdown()
            self.listener = nil
        }
        if let server {
            await server.stop()
            self.server = nil
        }
        if let transport {
            await transport.disconnect()
            self.transport = nil
        }
        transportBox.withLockedValue { $0 = nil }

        state = .stopped
        mcpServerLog.info("MCP server stopped")
    }

    private static let instructions = """
    Biscotti is a private, local meeting recorder on this Mac. This server exposes \
    the user's recorded meetings — titles, notes, summaries, and transcripts — \
    as read-only tools.
    """

    // MARK: - Work queue

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = work
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        work = task
        return task
    }
}

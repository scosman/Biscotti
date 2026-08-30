import DataStore
import Foundation
import MCP
import NIOConcurrencyHelpers
import NIOCore
import Observation

/// The request handler the listener routes to: one MCP round trip.
private typealias MCPRequestHandler = @Sendable (MCP.HTTPRequest) async -> MCP.HTTPResponse

/// Owns the MCP server lifecycle: the ``HTTPListener`` and the request
/// handler it routes to. Both are created inside `start()` and released in
/// `stop()` — a stopped controller holds one enum and a `DataStore`
/// reference, nothing else. That is the "zero overhead when off" contract
/// (functional spec §1).
///
/// The handler is stateless in the strongest sense: every request gets its
/// own `MCP.Server` + `StatelessHTTPServerTransport` pair, built on arrival
/// and torn down after the response (see ``makeRequestHandler``). Nothing
/// is allocated per request until a request arrives, and nothing
/// per-request outlives its response.
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

    /// Created in start(), released in stop(). Main-actor confined; the
    /// underlying objects do their own synchronization.
    private var listener: HTTPListener?
    /// The box the listener's request closure reads; it is what lets the
    /// listener bind *before* the request handler exists (see performStart).
    private var handlerBox = NIOLockedValueBox<MCPRequestHandler?>(nil)

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

        // Bind first: the per-request transports' OriginValidator must be
        // pinned to the port we actually own (8516 in production, the
        // ephemeral port in tests) or it would 421 every request whose
        // Host header names another port.
        let listener = HTTPListener { [handlerBox] request in
            guard let handle = handlerBox.withLockedValue({ $0 }) else {
                return MCP.HTTPResponse.error(
                    statusCode: 503,
                    .internalError("Server is starting")
                )
            }
            return await handle(request)
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

        let handler = Self.makeRequestHandler(store: store, version: serverVersion, boundPort: boundPort)
        handlerBox.withLockedValue { $0 = handler }

        let endpoint = URL(string: "http://\(MCPServerConfiguration.host):\(boundPort)\(MCPServerConfiguration.path)")
        state = .running(endpoint ?? MCPServerConfiguration.endpointURL)
        mcpServerLog.info("MCP server running on port \(boundPort)")
    }

    /// One request's worth of MCP machinery (functional spec §3: stateless,
    /// so every client must be able to initialize independently).
    ///
    /// The SDK `Server` latches `isInitialized` after its first `initialize`
    /// and rejects every later one **on the same instance** — a server
    /// shared across requests would let exactly one client handshake per
    /// app launch (the second got -32600 "Server is already initialized").
    /// The SDK's own conformance server builds a fresh transport + server
    /// per session (`HTTPApp.createSessionAndHandle`); without sessions,
    /// "per session" becomes "per request". The pair is torn down after the
    /// response, so no JSON-RPC state survives a request and clients can
    /// never interfere with each other.
    ///
    /// The server keeps the SDK's default (non-strict) configuration, which
    /// serves `tools/list`/`tools/call` without a prior `initialize` on the
    /// instance — the stateless no-session-gate behavior the round-trip
    /// tests pin.
    ///
    /// Requests the validators reject (405/403/400) still build the pair
    /// first; that cost is negligible on loopback and matches the SDK's own
    /// pattern.
    private nonisolated static func makeRequestHandler(
        store: DataStore,
        version: String,
        boundPort: Int
    ) -> MCPRequestHandler {
        { request in
            let transport = makeTransport(boundPort: boundPort)
            let server = await makeConfiguredServer(store: store, version: version)
            do {
                try await server.start(transport: transport)
            } catch {
                mcpServerLog.error(
                    "Per-request MCP server failed to start: \(error.localizedDescription, privacy: .public)"
                )
                return MCP.HTTPResponse.error(
                    statusCode: 500,
                    .internalError("Failed to start MCP server")
                )
            }

            let response = await transport.handleRequest(request)

            // Cancels the server's read loop and disconnects the transport:
            // the pair exists only between arrival and response.
            await server.stop()
            return response
        }
    }

    /// The `MCP.Server` every request starts from: Biscotti's identity,
    /// tools-only capabilities, and the three read-only tool handlers.
    /// Static and nonisolated so per-request construction (and with it the
    /// tool provider factory) never hops to the main actor.
    private nonisolated static func makeConfiguredServer(
        store: DataStore,
        version: String
    ) async -> MCP.Server {
        let server = MCP.Server(
            name: "Biscotti",
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        let provider = MeetingToolProvider(store: store)
        await server.withMethodHandler(MCP.ListTools.self) { _ in
            MCP.ListTools.Result(tools: MeetingToolCatalog.all)
        }
        await server.withMethodHandler(MCP.CallTool.self) { params in
            try await provider.call(name: params.name, arguments: params.arguments)
        }
        return server
    }

    /// Explicit validation pipeline rather than the transport's defaults, so
    /// the Origin check is pinned to the bound port.
    private nonisolated static func makeTransport(boundPort: Int) -> MCP.StatelessHTTPServerTransport {
        MCP.StatelessHTTPServerTransport(validationPipeline: MCP.StandardValidationPipeline(validators: [
            MCP.OriginValidator.localhost(port: boundPort),
            MCP.AcceptHeaderValidator(mode: .jsonOnly),
            MCP.ContentTypeValidator(),
            MCP.ProtocolVersionValidator()
        ]))
    }

    private func performStop() async {
        guard state != .stopped else { return }

        // New requests 503 from here on; requests already in flight keep
        // their own per-request pair alive until they finish.
        handlerBox.withLockedValue { $0 = nil }
        if let listener {
            await listener.shutdown()
            self.listener = nil
        }

        state = .stopped
        mcpServerLog.info("MCP server stopped")
    }

    private nonisolated static let instructions = """
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

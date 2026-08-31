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
/// (functional spec §1). A controller dropped while running does not leak:
/// `deinit` fires the listener shutdown as a safety net.
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
    /// The port every start attempts. Production keeps the fixed default
    /// (8516); tests inject 0 for an ephemeral port — they must never bind
    /// the production port, which the real app dogfoods.
    private let port: Int
    /// Server version reported in `initialize`; from the app bundle when
    /// present (tests and SPM contexts get "0.0.0").
    private let serverVersion: String
    /// Serialized start/stop/applyEnabled: every call awaits the previous
    /// queued work first, so a rapid on/off/on sequence cannot leave an
    /// orphan listener. Final state wins. Operations capture `self` weakly:
    /// a queued task must never be the reference that keeps the controller
    /// alive, or `deinit` (the leak safety net) could not run.
    private var work: Task<Void, Never>?

    /// The live listener, created in `performStart` and taken by
    /// `performStop`. A locked box rather than a plain stored property so
    /// the nonisolated `deinit` can reach it: `deinit` may only touch
    /// immutable, `Sendable` storage.
    private let listenerBox = NIOLockedValueBox<HTTPListener?>(nil)
    /// The box the listener's request closure reads; it is what lets the
    /// listener bind *before* the request handler exists (see performStart).
    private let handlerBox = NIOLockedValueBox<MCPRequestHandler?>(nil)

    public init(store: DataStore, port: Int = MCPServerConfiguration.port) {
        self.store = store
        self.port = port
        serverVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// The leak safety net: a controller dropped while running releases its
    /// listener (port + event-loop thread) here. `stop()` stays the graceful
    /// path — awaited, with the `.stopped` transition; this runs only when
    /// an owner failed to call it.
    deinit {
        // Like a graceful stop, stop serving first: requests arriving in
        // the teardown window get a 503 instead of meeting content from a
        // controller whose owner is gone.
        handlerBox.withLockedValue { $0 = nil }
        let listener = listenerBox.withLockedValue { box -> HTTPListener? in
            let listener = box
            box = nil
            return listener
        }
        guard let listener else { return }
        // `deinit` cannot await; fire-and-forget the same *listener*
        // shutdown `stop()` awaits. The task holds only the listener,
        // never this controller.
        Task { await listener.shutdown() }
    }

    /// Starts the server. Idempotent: a no-op when already running or
    /// starting; a fresh attempt after `.failed` (the Retry path).
    public func start() async {
        await enqueue { [weak self, port] in
            await self?.performStart(port: port)
        }.value
    }

    /// Stops the listener and closes open connections. Idempotent. The
    /// graceful path: awaited, with the state transition to `.stopped`.
    /// This is the primary teardown path: owners call it for orderly
    /// shutdown (AppCore does whenever the user disables the server — it
    /// must, because AppCore is process-lifetime and its controller is
    /// never dropped). `deinit` is only the safety net for a controller
    /// dropped while running: a short-lived owner, or a test controller
    /// created directly.
    public func stop() async {
        await enqueue { [weak self] in
            await self?.performStop()
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
                    .internalError("Server is not available")
                )
            }
            return await handle(request)
        }
        listenerBox.withLockedValue { $0 = listener }

        let boundPort: Int
        do {
            boundPort = try await listener.start(host: MCPServerConfiguration.host, port: port)
        } catch {
            // The listener tore itself down inside `start`; drop the dead
            // reference so a non-nil box implies something is bound.
            listenerBox.withLockedValue { $0 = nil }
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
        let listener = listenerBox.withLockedValue { box -> HTTPListener? in
            let listener = box
            box = nil
            return listener
        }
        if let listener {
            await listener.shutdown()
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

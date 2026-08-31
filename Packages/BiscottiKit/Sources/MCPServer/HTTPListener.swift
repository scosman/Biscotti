import Foundation
import MCP
import NIOConcurrencyHelpers
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

/// Owns the NIO accept loop for the MCP server: one event-loop thread, a
/// small connection cap, a 1 MB body cap, and idle-connection eviction.
///
/// `start` returns the **bound** port so callers can bind port 0 and learn
/// the ephemeral port (tests), while production pins
/// `MCPServerConfiguration.port`. `shutdown` is fully awaited — once it
/// returns, the port is released, which is what makes an immediate
/// stop→start cycle safe.
actor HTTPListener {
    private let handle: @Sendable (MCP.HTTPRequest) async -> MCP.HTTPResponse
    private let activeConnections = NIOLockedValueBox(0)
    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?

    /// - Parameter handle: Called off the event loop for every request that
    ///   survives the path check; its result is written back onto the loop.
    init(handle: @Sendable @escaping (MCP.HTTPRequest) async -> MCP.HTTPResponse) {
        self.handle = handle
    }

    /// Binds `host:port` and starts serving. Returns the bound port
    /// (differs from `port` when binding 0).
    ///
    /// - Parameter idleTimeout: How long a connection may stay silent
    ///   before it is closed (tests inject a short one).
    /// - Throws: ``MCPServerStartError/portInUse`` when the port is taken,
    ///   ``MCPServerStartError/bindFailed`` for any other bind failure.
    func start(
        host: String,
        port: Int,
        idleTimeout: Duration = .seconds(MCPServerConfiguration.idleTimeoutSeconds)
    ) async throws -> Int {
        guard serverChannel == nil else { throw MCPServerStartError.bindFailed("Listener already started") }

        // One thread is ample for a single local client and keeps the idle
        // footprint small (functional spec §7).
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let activeConnections = activeConnections
        let handle = handle
        let maxConcurrentConnections = MCPServerConfiguration.maxConcurrentConnections

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // The aggregation the architecture §4.1 sketch assigned to
                // `NIOHTTPServerRequestAggregator` (whole requests + the 413
                // body cap) and the idle eviction assigned to
                // `IdleStateHandler` both live in `HTTPChannelHandler`
                // instead: those NIO types have their `Sendable` conformances
                // marked unavailable, so they cannot be installed from
                // Swift 6 strict-concurrency code.
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandlers([
                        ConnectionLimiter(
                            activeConnections: activeConnections,
                            maxConnections: maxConcurrentConnections
                        ),
                        HTTPChannelHandler(
                            handle: handle,
                            idleTimeout: idleTimeout
                        )
                    ])
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            let channel = try await bootstrap.bind(host: host, port: port).get()
            guard let boundPort = channel.localAddress?.port else {
                try? await channel.close()
                try? await group.shutdownGracefully()
                self.group = nil
                throw MCPServerStartError.bindFailed("Listener bound without a port")
            }
            serverChannel = channel
            return boundPort
        } catch {
            try? await group.shutdownGracefully()
            self.group = nil
            throw Self.mapBindError(error, port: port)
        }
    }

    /// Closes the server channel, then waits for the event-loop group (which
    /// also closes any still-open child connections). After this returns the
    /// port is free.
    func shutdown() async {
        if let channel = serverChannel {
            try? await channel.close()
            serverChannel = nil
        }
        if let group {
            try? await group.shutdownGracefully()
            self.group = nil
        }
    }

    /// `EADDRINUSE` → `.portInUse`; everything else → `.bindFailed` with a
    /// display-safe message.
    private static func mapBindError(_ error: Error, port: Int) -> MCPServerStartError {
        if let ioError = error as? IOError, ioError.errnoCode == EADDRINUSE {
            return .portInUse(port: port)
        }
        return .bindFailed(error.localizedDescription)
    }
}

/// Counts live child connections and closes new ones past the cap
/// (functional spec §7). The limiter sits at the tail of the child
/// pipeline (it is added after `configureHTTPServerPipeline`), but its
/// `channelActive` runs before the channel reads any bytes, so an
/// over-cap connection is closed before a request can be parsed.
private final class ConnectionLimiter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let activeConnections: NIOLockedValueBox<Int>
    private let maxConnections: Int
    private var counted = false

    init(activeConnections: NIOLockedValueBox<Int>, maxConnections: Int) {
        self.activeConnections = activeConnections
        self.maxConnections = maxConnections
    }

    func channelActive(context: ChannelHandlerContext) {
        counted = true
        let limit = maxConnections
        let count = activeConnections.withLockedValue { counter in
            counter += 1
            return counter
        }
        if count > limit {
            mcpServerLog.debug("Connection over cap (\(count) > \(limit)); closing")
            context.close(promise: nil)
        }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if counted {
            activeConnections.withLockedValue { $0 -= 1 }
            counted = false
        }
        context.fireChannelInactive()
    }
}

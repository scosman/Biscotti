import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1

/// Bridges NIO HTTP/1.1 to the SDK's framework-agnostic `MCP.HTTPRequest` /
/// `MCP.HTTPResponse` types. One instance per connection; all real work —
/// validation, JSON-RPC decoding, tool dispatch — happens inside the
/// `MCP.StatelessHTTPServerTransport` the handler closure routes to.
///
/// The handler also aggregates request bodies and enforces the limits
/// itself (1 MB cap → 413, 120 s idle eviction) rather than installing
/// NIO's `NIOHTTPServerRequestAggregator` / `IdleStateHandler`: both of
/// those have their `Sendable` conformances marked `@available(*,
/// unavailable)` in swift-nio, so they cannot be added to a pipeline from
/// Swift 6 strict-concurrency code. This mirrors what the MCP SDK's own
/// conformance server does in its NIO adapter.
///
/// The handler is touched only from its channel's event loop, except by the
/// per-request `Task` that awaits the transport off-loop; writes always hop
/// back onto the channel's event loop.
final class HTTPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let handle: @Sendable (MCP.HTTPRequest) async -> MCP.HTTPResponse
    private let idleTimeout: Duration

    private struct RequestState {
        var head: HTTPRequestHead
        var body: ByteBuffer?
    }

    private var requestState: RequestState?
    private var idleCloseTask: Task<Void, Never>?
    init(
        handle: @Sendable @escaping (MCP.HTTPRequest) async -> MCP.HTTPResponse,
        idleTimeout: Duration
    ) {
        self.handle = handle
        self.idleTimeout = idleTimeout
    }

    func channelActive(context: ChannelHandlerContext) {
        armIdleTimer(channel: context.channel)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        armIdleTimer(channel: context.channel)
        let part = unwrapInboundIn(data)

        switch part {
        case let .head(head):
            requestState = RequestState(head: head, body: nil)

        case var .body(buffer):
            guard var state = requestState else { return }
            if state.body != nil {
                state.body?.writeBuffer(&buffer)
            } else {
                state.body = buffer
            }
            if let body = state.body, body.readableBytes > MCPServerConfiguration.maxBodyBytes {
                requestState = nil
                writeSimpleResponse(
                    status: .payloadTooLarge,
                    contentType: "application/json",
                    body: Data(#"{"error":"payload too large"}"#.utf8),
                    close: true,
                    context: context
                )
            } else {
                requestState = state
            }

        case .end:
            guard let state = requestState else { return }
            requestState = nil
            dispatch(state, context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelIdleTimer()
        context.fireChannelInactive()
    }

    func handlerRemoved(context _: ChannelHandlerContext) {
        cancelIdleTimer()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // A broken or hostile client must never take the process down: log,
        // drop this connection, keep serving.
        mcpServerLog.error(
            "Channel error, closing connection: \(error.localizedDescription, privacy: .public)"
        )
        context.close(promise: nil)
    }

    // MARK: - Dispatch

    private func dispatch(_ state: RequestState, context: ChannelHandlerContext) {
        // NIO's HTTP pipeline does not honor `Connection: close` for us —
        // when the client asked to hang up, we close after our response.
        let closeAfterResponse = !state.head.isKeepAlive

        // Reject by path first (functional spec §3): anything that is not
        // `/mcp` — ignoring any query string — is a plain 404 and never
        // reaches the transport.
        guard Self.path(of: state.head.uri) == MCPServerConfiguration.path else {
            writeSimpleResponse(
                status: .notFound,
                contentType: "application/json",
                body: Data(#"{"error":"not found"}"#.utf8),
                close: closeAfterResponse,
                context: context
            )
            return
        }

        // Capture the loop and channel while still on the event loop: the
        // Task below leaves it to await the transport, and both the write
        // hop and the buffer allocator must target this channel's loop.
        // (`EventLoop` and `Channel` are Sendable; the context is not.)
        let loop = context.eventLoop
        let channel = context.channel

        let request = Self.makeHTTPRequest(from: state)
        Task {
            let response = await self.handle(request)
            self.write(response, closeAfterWrite: closeAfterResponse, loop: loop, channel: channel)
        }
    }

    // MARK: - NIO → MCP

    private static func path(of uri: String) -> String {
        uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
    }

    private static func makeHTTPRequest(from state: RequestState) -> MCP.HTTPRequest {
        // Combine duplicate header values per RFC 7230; names are copied
        // verbatim because `MCP.HTTPRequest.header(_:)` does its own
        // case-insensitive lookup.
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = "\(existing), \(value)"
            } else {
                headers[name] = value
            }
        }

        let body: Data? = if let buffer = state.body, let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) {
            Data(bytes)
        } else {
            nil
        }

        return MCP.HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path(of: state.head.uri)
        )
    }

    // MARK: - MCP → NIO

    /// Maps an `MCP.HTTPResponse` onto the wire. `Content-Length` is always
    /// set so NIO's pipeline handler can honor keep-alive correctly.
    private func write(
        _ response: MCP.HTTPResponse,
        closeAfterWrite: Bool,
        loop: EventLoop,
        channel: Channel
    ) {
        // `.stream` is unreachable in stateless mode; if it ever happens we
        // degrade to a 500 rather than crash or hang the channel.
        guard case .stream = response else {
            writeRouted(response, closeAfterWrite: closeAfterWrite, loop: loop, channel: channel)
            return
        }
        mcpServerLog.error("Unexpected streaming response in stateless mode; returning 500")
        writeRouted(
            MCP.HTTPResponse.error(
                statusCode: 500,
                .internalError("Streaming responses are not supported")
            ),
            closeAfterWrite: true,
            loop: loop,
            channel: channel
        )
    }

    private func writeRouted(
        _ response: MCP.HTTPResponse,
        closeAfterWrite: Bool,
        loop: EventLoop,
        channel: Channel
    ) {
        let body = response.bodyData
        var headers = Self.responseHeaders(for: response, bodyLength: body?.count ?? 0)
        if closeAfterWrite {
            headers.replaceOrAdd(name: "Connection", value: "close")
        }
        let head = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.statusCode),
            headers: headers
        )

        loop.execute {
            channel.write(self.wrapOutboundOut(.head(head)), promise: nil)
            if let body {
                var buffer = channel.allocator.buffer(capacity: body.count)
                buffer.writeBytes(body)
                channel.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            channel.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            if closeAfterWrite {
                channel.close(promise: nil)
            }
        }
    }

    private static func responseHeaders(
        for response: MCP.HTTPResponse,
        bodyLength: Int
    ) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }
        headers.add(name: "Content-Length", value: "\(bodyLength)")
        return headers
    }

    /// Writes a self-contained response that never touches the transport
    /// (the 404 and 413 paths).
    private func writeSimpleResponse(
        status: HTTPResponseStatus,
        contentType: String,
        body: Data,
        close: Bool,
        context: ChannelHandlerContext
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(body.count)")
        if close {
            headers.add(name: "Connection", value: "close")
        }
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)

        nonisolated(unsafe) let channelContext = context
        channelContext.eventLoop.execute {
            channelContext.write(self.wrapOutboundOut(.head(head)), promise: nil)
            var buffer = channelContext.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channelContext.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            channelContext.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            if close {
                channelContext.close(promise: nil)
            }
        }
    }

    // MARK: - Idle eviction

    /// Closes the connection after `idleTimeout` without traffic. Idle
    /// connections hold no state worth keeping (stateless transport), so
    /// dropping the socket is always safe.
    private func armIdleTimer(channel: Channel) {
        cancelIdleTimer()
        idleCloseTask = Task { [idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            channel.close(promise: nil)
        }
    }

    private func cancelIdleTimer() {
        idleCloseTask?.cancel()
        idleCloseTask = nil
    }
}

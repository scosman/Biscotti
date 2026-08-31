import DataStore
import Foundation
@testable import MCPServer

#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Server fixture

/// Starts a real controller on an ephemeral port for one test and guarantees
/// shutdown afterwards, so parallel tests never share (or leak) listeners.
@MainActor
struct MCPServerFixture {
    let controller: MCPServerController
    let port: Int

    static func withRunningServer(
        _ body: (MCPServerFixture) async throws -> Void
    ) async throws {
        try await withRunningServer(store: DataStore(storage: .inMemory), body)
    }

    /// Same, with a caller-seeded store — for end-to-end tool tests that need
    /// meetings in the database before the server starts.
    static func withRunningServer(
        store: DataStore,
        _ body: (MCPServerFixture) async throws -> Void
    ) async throws {
        let controller = MCPServerController(store: store, port: 0)
        await controller.start()

        guard case let .running(url) = controller.state, let port = url.port else {
            let state = controller.state
            await controller.stop()
            throw MCPFixtureError.failedToStart(state)
        }
        let fixture = MCPServerFixture(controller: controller, port: port)

        do {
            try await body(fixture)
        } catch {
            await controller.stop()
            throw error
        }
        await controller.stop()
    }

    enum MCPFixtureError: Error, CustomStringConvertible {
        case failedToStart(MCPServerState)

        var description: String {
            switch self {
            case let .failedToStart(state):
                "MCP server fixture failed to start: \(state)"
            }
        }
    }
}

// MARK: - Raw HTTP client

/// A minimal blocking HTTP/1.1 client over POSIX sockets, run on a detached
/// task. `URLSession` cannot set `Origin` or omit `Host`, so the
/// header-control cases need byte-level control.
struct RawHTTPResponse: Equatable {
    let status: Int
    /// Header names lowercased.
    let headers: [String: String]
    let body: Data
}

enum RawHTTPClient {
    struct Request {
        var method = "POST"
        var path = "/mcp"
        var headers: [(String, String)] = []
        var body: Data?
        /// For oversized-body tests: stop sending once response bytes are
        /// already readable, so the client never races a server-side close.
        var stopSendingOnResponse = false
    }

    static func send(port: Int, request: Request) async throws -> RawHTTPResponse {
        let task = Task.detached(priority: .userInitiated) {
            try perform(port: port, request: request)
        }
        return try await task.value
    }

    /// A connected socket that sends nothing, holding one server
    /// connection open (connection-cap test).
    final class HeldConnection {
        fileprivate let socketFD: Int32

        fileprivate init(socketFD: Int32) {
            self.socketFD = socketFD
        }

        func close() {
            Darwin.close(socketFD)
        }
    }

    /// Connects and holds the connection open without sending anything.
    static func connect(port: Int) async throws -> HeldConnection {
        let task = Task.detached(priority: .userInitiated) {
            try openSocket(to: port)
        }
        return try await HeldConnection(socketFD: task.value)
    }

    /// Connects, sends nothing, and waits for the server to close the
    /// connection. Returns the bytes received before the close — empty
    /// when the server closes an over-cap or idle connection without
    /// responding. Throws `ClientError.serverDidNotClose` when the
    /// connection is still open after the receive timeout.
    static func awaitServerClose(port: Int) async throws -> Data {
        let task = Task.detached(priority: .userInitiated) {
            try awaitClose(port: port)
        }
        return try await task.value
    }

    private static func awaitClose(port: Int) throws -> Data {
        let socketFD = try openSocket(to: port)
        defer { close(socketFD) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let received = recv(socketFD, &buffer, buffer.count, 0)
            if received == 0 { return data }
            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw ClientError.serverDidNotClose
                }
                throw ClientError.receiveFailed(errno)
            }
            data.append(contentsOf: buffer[0 ..< received])
        }
    }

    private static func perform(port: Int, request: Request) throws -> RawHTTPResponse {
        let socketFD = try openSocket(to: port)
        defer { close(socketFD) }

        var head = "\(request.method) \(request.path) HTTP/1.1\r\n"
        head += "Host: 127.0.0.1:\(port)\r\n"
        for (name, value) in request.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(request.body?.count ?? 0)\r\n"
        head += "Connection: close\r\n\r\n"

        try sendAll(socketFD, Data(head.utf8))
        if let body = request.body {
            try sendBody(socketFD, body: body, stopOnResponse: request.stopSendingOnResponse)
        }

        let wire = try readToEOF(socketFD)
        return try parse(wire)
    }

    /// Creates a connected TCP socket to the server with a 10 s receive
    /// timeout. Shared by the request path and the connection probes.
    private static func openSocket(to port: Int) throws -> Int32 {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ClientError.socketCreationFailed }

        var noSigPipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(socketFD)
            throw ClientError.connectFailed(errno)
        }

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return socketFD
    }

    private static func sendAll(_ socketFD: Int32, _ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            while offset < data.count {
                let sent = Darwin.send(socketFD, base + offset, data.count - offset, 0)
                if sent <= 0 { throw ClientError.sendFailed(errno) }
                offset += sent
            }
        }
    }

    private static func sendBody(_ socketFD: Int32, body: Data, stopOnResponse: Bool) throws {
        // 64 KiB chunks keep the oversized-body test from tripping over the
        // server's mid-body close: it stops as soon as the response lands.
        var offset = 0
        let chunkSize = 65536
        while offset < body.count {
            if stopOnResponse, hasReadableBytes(socketFD) { return }
            let end = min(offset + chunkSize, body.count)
            let chunk = body.subdata(in: offset ..< end)
            let sent = chunk.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return Darwin.send(socketFD, base, chunk.count, 0)
            }
            if sent <= 0 { return } // Server closed early (413 path): response is inbound.
            offset += sent
        }
    }

    private static func hasReadableBytes(_ socketFD: Int32) -> Bool {
        var probe: UInt8 = 0
        return recv(socketFD, &probe, 1, MSG_PEEK | MSG_DONTWAIT) > 0
    }

    private static func readToEOF(_ socketFD: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let received = recv(socketFD, &buffer, buffer.count, 0)
            if received <= 0 { break }
            data.append(contentsOf: buffer[0 ..< received])
        }
        return data
    }

    private static func parse(_ wire: Data) throws -> RawHTTPResponse {
        guard let headerRange = wire.range(of: Data("\r\n\r\n".utf8)) else {
            throw ClientError.unparseableResponse
        }
        guard let headerBlock = String(bytes: wire[..<headerRange.lowerBound], encoding: .utf8) else {
            throw ClientError.unparseableResponse
        }
        let body = Data(wire[headerRange.upperBound...])

        let lines = headerBlock.split(separator: "\r\n")
        guard let statusLine = lines.first else { throw ClientError.unparseableResponse }

        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw ClientError.unparseableResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return RawHTTPResponse(status: status, headers: headers, body: body)
    }

    enum ClientError: Error {
        case socketCreationFailed
        case connectFailed(Int32)
        case sendFailed(Int32)
        case receiveFailed(Int32)
        case serverDidNotClose
        case unparseableResponse
    }
}

// MARK: - JSON-RPC over URLSession

enum JSONRPCClient {
    static func post(
        port: Int,
        path: String = MCPServerConfiguration.path,
        method: String,
        params: [String: Any]? = nil,
        id: Int? = 1
    ) async throws -> (status: Int, body: [String: Any]) {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params { payload["params"] = params }
        if let id { payload["id"] = id }

        let url = URL(string: "http://127.0.0.1:\(port)\(path)") ?? MCPServerConfiguration.endpointURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, body)
    }
}

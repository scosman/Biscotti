import Foundation
import LocalLLM
import os.log

private let hostLog = Logger(
    subsystem: "net.scosman.biscotti",
    category: "LLMXPCHost"
)

// MARK: - Sendable box

/// Wraps a non-`Sendable` value so it can cross into a `@Sendable` closure.
/// Used here for the NSXPC remote-object proxy, which is thread-safe at runtime
/// but not statically `Sendable`.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

// MARK: - Connection holder (actor storing the in-process LLMConnection)

/// Stores the loaded `LLMConnection` and the current generation `Task` so
/// `cancel()` can reach it. Actor isolation serializes access.
private actor ConnectionHolder {
    private var connection: LLMConnection?
    private var currentTask: Task<Void, Never>?

    var conn: LLMConnection? {
        connection
    }

    func set(_ conn: LLMConnection) {
        connection = conn
    }

    /// Creates a new `Task` from the given operation and stores it in
    /// `currentTask` atomically within a single actor-isolated call.
    /// This avoids the self-referential capture that `nonisolated(unsafe) var task`
    /// required, which Swift 6 rejects as non-Sendable.
    func runTracked(_ operation: @Sendable @escaping () async -> Void) {
        let task = Task { await operation() }
        currentTask = task
    }

    func cancelCurrent() {
        currentTask?.cancel()
        currentTask = nil
    }

    func closeAndShutdown() async {
        currentTask?.cancel()
        currentTask = nil
        await connection?.close()
        connection = nil
        LocalLLMRuntime.shutdown()
    }
}

// MARK: - Exported object

/// The exported object vended to XPC clients. Bridges the `@objc`
/// reply-handler protocol to an in-process `LLMConnection`.
///
/// Thread-safety: mutable state is held in the `ConnectionHolder` actor.
/// All access goes through `await`, so `@unchecked Sendable` is safe.
final class LLMXPCService: NSObject, LLMServiceProtocol, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    fileprivate let holder = ConnectionHolder()

    init(connection: NSXPCConnection?) {
        self.connection = connection
        super.init()
    }

    func load(
        requestData: Data,
        reply: @escaping @Sendable (Error?) -> Void
    ) {
        let request: LLMLoadRequest
        do {
            request = try JSONDecoder().decode(LLMLoadRequest.self, from: requestData)
        } catch {
            reply(error)
            return
        }

        let holder = holder
        Task {
            do {
                let modelURL = URL(fileURLWithPath: request.modelPath)
                let conn = try await LLMService.openConnection(
                    model: modelURL,
                    backend: .inProcess,
                    config: request.config
                )
                await holder.set(conn)
                reply(nil)
            } catch {
                reply(LLMNSErrorBridge.nsError(from: error))
            }
        }
    }

    func generate(
        requestData: Data,
        reply: @escaping @Sendable (Data?, Error?) -> Void
    ) {
        let request: LLMGenerateRequest
        do {
            request = try JSONDecoder().decode(LLMGenerateRequest.self, from: requestData)
        } catch {
            reply(nil, error)
            return
        }

        let holder = holder
        Task {
            do {
                guard let conn = await holder.conn else {
                    reply(nil, LLMNSErrorBridge.nsError(
                        from: LLMServiceError.serviceUnavailable("No model loaded")
                    ))
                    return
                }
                let result = try await conn.generate(
                    prompt: request.prompt,
                    system: request.system,
                    options: request.options
                )
                let data = try JSONEncoder().encode(result)
                reply(data, nil)
            } catch {
                reply(nil, LLMNSErrorBridge.nsError(from: error))
            }
        }
    }

    func generateStreaming(
        requestData: Data,
        reply: @escaping @Sendable (Error?) -> Void
    ) {
        let request: LLMGenerateRequest
        do {
            request = try JSONDecoder().decode(LLMGenerateRequest.self, from: requestData)
        } catch {
            reply(error)
            return
        }

        let reporterBox = UncheckedSendableBox(
            connection?.remoteObjectProxy as? LLMEventReporting
        )
        let holder = holder

        // Atomically create and store the generation task inside the actor,
        // so cancel() always sees the in-flight task. The operation closure
        // captures only Sendable values (actor ref, UncheckedSendableBox,
        // @Sendable reply, Codable request), avoiding the non-Sendable
        // self-referential capture that Swift 6 rejects.
        Task {
            await holder.runTracked {
                do {
                    guard let conn = await holder.conn else {
                        reply(LLMNSErrorBridge.nsError(
                            from: LLMServiceError.serviceUnavailable("No model loaded")
                        ))
                        return
                    }

                    let stream = await conn.generateStreaming(
                        prompt: request.prompt,
                        system: request.system,
                        options: request.options
                    )

                    for try await event in stream {
                        switch event {
                        case let .token(piece):
                            reporterBox.value?.reportToken(piece)
                        case let .reasoningToken(piece):
                            reporterBox.value?.reportReasoningToken(piece)
                        case let .done(result):
                            do {
                                let data = try JSONEncoder().encode(result)
                                reporterBox.value?.reportDone(resultData: data)
                            } catch {
                                // Encoding the result failed — send a terminal error
                                // so the client's stream doesn't hang.
                                let encodeError = LLMServiceError.protocolError(
                                    "Failed to encode GenerationResult: \(error.localizedDescription)"
                                )
                                reporterBox.value?.reportError(
                                    errorData: (try? JSONEncoder().encode(
                                        LLMErrorPayload.from(encodeError)
                                    )) ?? Data()
                                )
                                reply(LLMNSErrorBridge.nsError(from: encodeError))
                                return
                            }
                        }
                    }
                    reply(nil)
                } catch let streamError {
                    let payload = LLMErrorPayload.from(streamError)
                    do {
                        let data = try JSONEncoder().encode(payload)
                        reporterBox.value?.reportError(errorData: data)
                    } catch {
                        // Error-payload encoding itself failed — send the original
                        // stream error via the reply so the client surfaces something.
                        reply(LLMNSErrorBridge.nsError(from: streamError))
                        return
                    }
                    reply(nil)
                }
            }
        }
    }

    func cancel(reply: @escaping @Sendable () -> Void) {
        let holder = holder
        Task {
            await holder.cancelCurrent()
            reply()
        }
    }

    func healthCheck(reply: @escaping @Sendable (Bool) -> Void) {
        reply(true)
    }
}

// MARK: - NSError bridge

/// Wraps errors as `NSError` with an embedded `LLMErrorPayload` in `userInfo`
/// so the client can decode them back to typed `LLMServiceError`.
private enum LLMNSErrorBridge {
    static let errorDomain = "net.scosman.biscotti.LocalLLM"

    static func nsError(from error: any Error) -> NSError {
        let payload = LLMErrorPayload.from(error)
        let payloadData = (try? JSONEncoder().encode(payload)) ?? Data()
        return NSError(
            domain: errorDomain,
            code: 1,
            userInfo: [
                "payload": payloadData,
                NSLocalizedDescriptionKey: error.localizedDescription
            ]
        )
    }
}

// MARK: - Active connection tracking

/// Thread-safe counter of active XPC connections. When the count drops to
/// zero the process exits, releasing multi-GB model memory immediately
/// instead of waiting for `NSXPCListener.service()`'s idle-exit heuristic
/// (which never fires while Metal run-loop sources are alive).
private final class ConnectionCounter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    /// Decrements the counter and returns `true` when it reaches zero.
    func decrementAndCheckZero() -> Bool {
        lock.lock()
        count -= 1
        let isZero = count == 0
        lock.unlock()
        return isZero
    }
}

private let connectionCounter = ConnectionCounter()

/// Holds a reference to the most recent connection's service object for
/// best-effort ordered teardown (close LLMConnection, then backend_free)
/// when the last connection invalidates. Only one service is tracked; if
/// multiple connections exist and the non-last invalidates, its holder
/// won't get an explicit close. This is intentional — `_exit(0)` fires
/// immediately after the teardown attempt and reclaims everything; the
/// ordered path just tries to avoid the ggml Metal assertion on the
/// happy path.
private let lastService = OSAllocatedUnfairLock<LLMXPCService?>(initialState: nil)

// MARK: - Listener delegate

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        connectionCounter.increment()
        hostLog.info("Accepted new XPC connection pid=\(pid)")

        connection.exportedInterface = NSXPCInterface(
            with: LLMServiceProtocol.self
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: LLMEventReporting.self
        )

        let service = LLMXPCService(connection: connection)
        connection.exportedObject = service
        lastService.withLock { $0 = service }

        connection.interruptionHandler = {
            hostLog.info("Service-side connection interrupted pid=\(pid)")
        }

        connection.invalidationHandler = {
            hostLog.info("Service-side connection invalidated pid=\(pid)")
            if connectionCounter.decrementAndCheckZero() {
                hostLog.info(
                    "XPC host exiting pid=\(pid) (no active connections)"
                )
                // Ordered teardown: close the LLMConnection (frees the
                // llama.cpp context/model) then shut down the backend
                // (llama_backend_free). Use a bounded wait so _exit fires
                // even if the async close stalls.
                let sema = DispatchSemaphore(value: 0)
                Task {
                    if let svc = lastService.withLock({ $0 }) {
                        await svc.holder.closeAndShutdown()
                    }
                    sema.signal()
                }
                // Bounded wait: 2 seconds for ordered teardown, then _exit
                // regardless. _exit(0) skips C++ static destructors, avoiding
                // the ggml Metal rsets assertion (same rationale as
                // BiscottiTranscriber).
                _ = sema.wait(timeout: .now() + 2.0)
                _exit(0) // swiftlint:disable:this fatal_error_message
            }
        }

        connection.resume()
        return true
    }
}

// MARK: - Entry point

hostLog.info(
    "XPC host process started pid=\(ProcessInfo.processInfo.processIdentifier)"
)

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

hostLog.info("Listener resumed pid=\(ProcessInfo.processInfo.processIdentifier)")

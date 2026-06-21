import Foundation
import os

/// NSXPC client adapter: bridges the `@objc` `LLMServiceProtocol` (XPC proxy)
/// to the async Swift `ServiceBackend` seam.
///
/// Owns the `NSXPCConnection` lifecycle. The `LLMEventReceiver` handles the
/// reverse proxy channel for streaming. Error mapping decodes
/// `LLMErrorPayload` from the service's `NSError` `userInfo` and falls back
/// to XPC connection codes (4097 interrupted, 4099 invalid).
final class XPCBackend: ServiceBackend, @unchecked Sendable {
    /// NSError domain used for `LLMErrorPayload`-wrapped errors across XPC.
    static let errorDomain = "net.scosman.biscotti.LocalLLM"

    private static let log = Logger(
        subsystem: "net.scosman.biscotti",
        category: "XPCBackend"
    )

    private let serviceName: String
    private let modelURL: URL
    private let config: EngineConfig

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var eventReceiver = LLMEventReceiver()
    private var didShutdown = false
    private var interrupted = false

    init(serviceName: String, model: URL, config: EngineConfig) {
        self.serviceName = serviceName
        modelURL = model
        self.config = config
    }

    // MARK: - ServiceBackend

    func start() async throws {
        let conn = NSXPCConnection(serviceName: serviceName)

        conn.remoteObjectInterface = NSXPCInterface(
            with: LLMServiceProtocol.self
        )
        conn.exportedInterface = NSXPCInterface(
            with: LLMEventReporting.self
        )
        conn.exportedObject = eventReceiver

        conn.interruptionHandler = { [weak self] in
            Self.log.warning("XPC service interrupted (crash/jetsam)")
            guard let self else { return }
            lock.withLock { self.interrupted = true }
        }
        conn.invalidationHandler = { [weak self] in
            _ = self // prevent future drift if self-referencing code is added
            Self.log.info("XPC connection invalidated")
        }

        conn.resume()
        lock.withLock { connection = conn }

        let loadRequest = LLMLoadRequest(
            modelPath: modelURL.path,
            config: config
        )
        let requestData = try XPCCodingHelpers.encode(
            loadRequest, label: "LLMLoadRequest"
        )

        guard let proxy = conn.remoteObjectProxy as? any LLMServiceProtocol else {
            throw LLMServiceError.serviceUnavailable(
                "Failed to obtain XPC proxy for \(serviceName)"
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.load(requestData: requestData) { error in
                if let error {
                    continuation.resume(
                        throwing: XPCErrorMapper.map(error)
                    )
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func countTokens(
        system: String?, user: String,
        applyChatTemplate: Bool, thinking: ThinkingMode
    ) async throws -> Int {
        let proxy = try requireProxy()
        let request = LLMCountTokensRequest(
            user: user, system: system,
            applyChatTemplate: applyChatTemplate, thinking: thinking
        )
        let requestData = try XPCCodingHelpers.encode(
            request, label: "LLMCountTokensRequest"
        )

        return try await withCheckedThrowingContinuation { continuation in
            proxy.countTokens(requestData: requestData) { count, error in
                if let error {
                    continuation.resume(
                        throwing: XPCErrorMapper.map(error)
                    )
                    return
                }
                continuation.resume(returning: Int(count))
            }
        }
    }

    func reconfigure(contextSize: Int) async throws {
        let proxy = try requireProxy()

        // Int -> Int32 narrowing for the @objc wire. Context sizes are always
        // well under Int32.max (~2B), but guard against programmer error.
        guard let size32 = Int32(exactly: contextSize) else {
            throw LLMServiceError.protocolError(
                "Context size \(contextSize) overflows Int32"
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.reconfigure(contextSize: size32) { error in
                if let error {
                    continuation.resume(
                        throwing: XPCErrorMapper.map(error)
                    )
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func generate(
        id _: UInt64,
        prompt: String,
        system: String?,
        options: GenerationOptions
    ) async throws -> GenerationResult {
        let proxy = try requireProxy()
        let request = LLMGenerateRequest(
            prompt: prompt, system: system, options: options
        )
        let requestData = try XPCCodingHelpers.encode(
            request, label: "LLMGenerateRequest"
        )

        return try await withCheckedThrowingContinuation { continuation in
            proxy.generate(requestData: requestData) { data, error in
                if let error {
                    continuation.resume(
                        throwing: XPCErrorMapper.map(error)
                    )
                    return
                }
                guard let data else {
                    continuation.resume(
                        throwing: LLMServiceError.protocolError(
                            "XPC service returned nil data without an error"
                        )
                    )
                    return
                }
                do {
                    let result = try JSONDecoder().decode(
                        GenerationResult.self, from: data
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(
                        throwing: LLMServiceError.protocolError(
                            "Failed to decode GenerationResult: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    func generateStreaming(
        id _: UInt64,
        prompt: String,
        system: String?,
        options: GenerationOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let request = LLMGenerateRequest(
            prompt: prompt, system: system, options: options
        )

        let requestData: Data
        do {
            requestData = try XPCCodingHelpers.encode(
                request, label: "LLMGenerateRequest"
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let proxy: any LLMServiceProtocol
        do {
            proxy = try requireProxy()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let receiver = eventReceiver

        return AsyncThrowingStream { continuation in
            XPCStreamingRelay.installHandlers(
                on: receiver, continuation: continuation
            )

            // The XPC proxy is not Sendable, but it is thread-safe (NSXPC
            // proxies dispatch to the connection's queue). Wrap it so the
            // @Sendable onTermination closure can reach it.
            nonisolated(unsafe) let sendableProxy = proxy

            // Install onTermination BEFORE the proxy call so that a consumer
            // cancellation arriving between the proxy call and this assignment
            // still sends cancel to the service.
            continuation.onTermination = { @Sendable reason in
                receiver.clearHandlers()
                if case .cancelled = reason {
                    sendableProxy.cancel {}
                }
            }

            // NOTE: The reply handler below may race with `onDone`/`onError`
            // handlers installed by `XPCStreamingRelay`. If the service has
            // already delivered a terminal event (reportDone/reportError) and
            // the continuation is finished there, the reply handler's
            // `continuation.finish(throwing:)` becomes a second finish.
            // This is safe: `AsyncThrowingStream.Continuation.finish` is
            // idempotent — the second call is a no-op. Similarly,
            // `clearHandlers()` is idempotent (just nil-sets closures under
            // a lock). Do NOT "fix" this by adding a terminal flag — the
            // idempotency guarantee is the correct contract here.
            proxy.generateStreaming(requestData: requestData) { error in
                if let error {
                    continuation.finish(
                        throwing: XPCErrorMapper.map(error)
                    )
                    receiver.clearHandlers()
                }
            }
        }
    }

    func cancel(id _: UInt64) async {
        guard let proxy = proxyOrNil() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proxy.cancel {
                continuation.resume()
            }
        }
    }

    func shutdown() async {
        let conn: NSXPCConnection? = lock.withLock {
            guard !didShutdown else { return nil }
            didShutdown = true
            let current = connection
            connection = nil
            return current
        }
        conn?.invalidate()
    }

    /// Does not set `didShutdown`: this is the last-resort deinit backstop —
    /// `shutdown()` won't meaningfully run after deinit, and `invalidate()` is idempotent.
    nonisolated func forceKill() {
        let conn: NSXPCConnection? = lock.withLock {
            let current = connection
            connection = nil
            return current
        }
        conn?.invalidate()
    }

    // MARK: - Private

    private func requireProxy() throws -> any LLMServiceProtocol {
        if lock.withLock({ interrupted }) {
            throw LLMServiceError.serviceInterrupted
        }
        guard let proxy = proxyOrNil() else {
            throw LLMServiceError.serviceUnavailable(
                "XPC connection to \(serviceName) is not available"
            )
        }
        return proxy
    }

    private func proxyOrNil() -> (any LLMServiceProtocol)? {
        lock.withLock { connection }?.remoteObjectProxy
            as? any LLMServiceProtocol
    }
}

// MARK: - XPC Streaming Relay

/// Installs `LLMEventReceiver` handlers that bridge streaming callbacks
/// into an `AsyncThrowingStream` continuation. Extracted to keep the
/// `generateStreaming` body within lint limits.
private enum XPCStreamingRelay {
    static func installHandlers(
        on receiver: LLMEventReceiver,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        receiver.setHandlers(
            onToken: { piece in
                continuation.yield(.token(piece))
            },
            onReasoningToken: { piece in
                continuation.yield(.reasoningToken(piece))
            },
            onDone: { resultData in
                do {
                    let result = try JSONDecoder().decode(
                        GenerationResult.self, from: resultData
                    )
                    continuation.yield(.done(result))
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: LLMServiceError.protocolError(
                            "Failed to decode streaming GenerationResult: "
                                + "\(error.localizedDescription)"
                        )
                    )
                }
                receiver.clearHandlers()
            },
            onError: { errorData in
                let clientError: any Error = if let payload = try? JSONDecoder()
                    .decode(LLMErrorPayload.self, from: errorData)
                {
                    payload.toClientError()
                } else {
                    LLMServiceError.protocolError(
                        "Failed to decode error payload from service"
                    )
                }
                continuation.finish(throwing: clientError)
                receiver.clearHandlers()
            }
        )
    }
}

// MARK: - XPC Error Mapper

/// Maps XPC-layer errors to `LLMServiceError`.
///
/// 1. Check for an embedded `LLMErrorPayload` in the NSError's `userInfo`.
/// 2. Check for known `NSCocoaErrorDomain` XPC connection codes.
/// 3. Fall back to `serviceUnavailable` for unknown errors.
private enum XPCErrorMapper {
    static func map(_ error: any Error) -> any Error {
        let nsError = error as NSError

        if nsError.domain == XPCBackend.errorDomain,
           let payloadData = nsError.userInfo["payload"] as? Data,
           let payload = try? JSONDecoder().decode(
               LLMErrorPayload.self, from: payloadData
           )
        {
            return payload.toClientError()
        }

        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case 4097: // NSXPCConnectionInterrupted
                return LLMServiceError.serviceInterrupted
            case 4099: // NSXPCConnectionInvalid
                return LLMServiceError.serviceUnavailable(
                    "XPC connection invalid"
                )
            default:
                break
            }
        }

        return LLMServiceError.serviceUnavailable(
            error.localizedDescription
        )
    }
}

// MARK: - XPC Coding Helpers

/// JSON encoding helpers for XPC request DTOs.
private enum XPCCodingHelpers {
    static func encode(
        _ value: some Encodable, label: String
    ) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw LLMServiceError.protocolError(
                "Failed to encode \(label): \(error.localizedDescription)"
            )
        }
    }
}

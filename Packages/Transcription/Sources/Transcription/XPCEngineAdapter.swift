import Foundation

/// Adapts the `@objc` `TranscriberServiceProtocol` (XPC proxy) to the async
/// Swift `TranscriptionEngine` seam.
///
/// Decodes `Data` replies back to `TranscriptResult`, and maps XPC-specific
/// failures to `TranscriptionError.workerInterrupted` / `.workerUnavailable`.
///
/// The adapter does NOT own the `NSXPCConnection` lifecycle -- it receives
/// a proxy provider closure (the testable seam). The `Transcriber` actor
/// owns the connection and sets the `interruptionHandler`.
///
/// **Interruption handling** is the `Transcriber` actor's responsibility.
/// The adapter does not check or gate on the interrupted flag; it only
/// maps XPC-level errors (connection codes) to the appropriate
/// `TranscriptionError` cases. The `Transcriber` checks the flag before
/// forwarding calls to the adapter and clears it after raising
/// `workerInterrupted`.
final class XPCEngineAdapter: TranscriptionEngine, @unchecked Sendable {
    /// Returns the current XPC proxy, or nil if unavailable. Its messages call
    /// the given error handler when the connection fails, so every call below
    /// ends with its reply or an error, never waits forever.
    typealias ProxyProvider = @Sendable (_ errorHandler: @escaping @Sendable (any Error) -> Void) -> (any TranscriberServiceProtocol)?

    private let proxyProvider: ProxyProvider

    init(proxyProvider: @escaping ProxyProvider) {
        self.proxyProvider = proxyProvider
    }

    // MARK: - TranscriptionEngine

    func ensureModelsDownloaded(
        status _: @escaping @Sendable (String) -> Void
    ) async throws {
        // Status is NOT delivered through this call's reply handler — a
        // one-shot reply cannot stream intermediate updates. Instead the worker
        // pushes status back over the reverse `TranscriberStatusReporting`
        // channel, which the `Transcriber` actor wires to the caller's closure
        // before invoking this method. Here we only await completion.
        try await call { proxy, reply in
            proxy.ensureModelsDownloaded { error in
                reply.resume(with: error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    func processAudio(
        micPath: String,
        systemPath: String,
        customVocabulary: [String]
    ) async throws -> TranscriptResult {
        try await processAudio(micPath: micPath, systemPath: systemPath, customVocabulary: customVocabulary, sendingFrom: nil)
    }

    /// Sends the request on the caller's actor before suspending, so a message
    /// that actor sends after this call starts, such as `cancelActiveWork`,
    /// reaches the worker after it.
    func processAudio(
        micPath: String,
        systemPath: String,
        customVocabulary: [String],
        sendingFrom isolation: isolated (any Actor)?
    ) async throws -> TranscriptResult {
        let request = XPCProcessRequest(
            micPath: micPath,
            systemPath: systemPath,
            customVocabulary: customVocabulary
        )
        let requestData = try encodeRequest(request)

        return try await call(isolation: isolation) { proxy, reply in
            proxy.processAudio(requestData: requestData) { data, error in
                reply.resume(with: Self.decodeResult(data: data, error: error))
            }
        }
    }

    func unloadModels() async {
        try? await call { proxy, reply in
            proxy.unloadModels { reply.resume(returning: ()) }
        }
    }

    func modelsPresent() async -> Bool {
        // The XPC adapter delegates to the static disk check on
        // InProcessTranscriptionEngine. Model files live at a shared
        // filesystem path (ModelStorage), so the client process can
        // check without involving the XPC worker.
        //
        // Note: this resolves the *current* method's model repo/name
        // via MethodResolver. If a future transcription method ships
        // with a different model name, the method would need to be
        // plumbed in (the Transcriber actor already stores its method
        // and could pass it through).
        let settings = MethodResolver.resolve(.current)
        return InProcessTranscriptionEngine.whisperKitModelsPresent(
            repo: settings.sttModelRepo,
            model: settings.sttModel
        ) && InProcessTranscriptionEngine.speakerKitModelsPresent()
    }

    func status() async -> ModelStatus {
        // The XPC adapter cannot directly query the worker's status machine.
        // Status is managed by the Transcriber actor that wraps this adapter.
        .ready
    }

    // MARK: - Private

    /// Sends one message and waits for its reply or for the connection's error,
    /// whichever comes first. Errors come back mapped to `TranscriptionError`.
    private func call<Value: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ send: (any TranscriberServiceProtocol, ReplyOnce<Value>) -> Void
    ) async throws -> Value {
        do {
            return try await withCheckedThrowingContinuation(isolation: isolation) { continuation in
                let reply = ReplyOnce(continuation)
                guard let proxy = proxyProvider({ reply.resume(throwing: $0) }) else {
                    reply.resume(throwing: TranscriptionError.workerUnavailable)
                    return
                }
                send(proxy, reply)
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    private static func decodeResult(data: Data?, error: (any Error)?) -> Result<TranscriptResult, any Error> {
        if let error {
            return .failure(error)
        }
        guard let data else {
            return .failure(TranscriptionError.transcriptionFailed("XPC service returned nil data without an error"))
        }
        do {
            return try .success(JSONDecoder().decode(TranscriptResult.self, from: data))
        } catch {
            return .failure(TranscriptionError.transcriptionFailed(
                "Failed to decode TranscriptResult from XPC: \(error.localizedDescription)"
            ))
        }
    }

    private func encodeRequest(_ request: XPCProcessRequest) throws -> Data {
        do {
            return try JSONEncoder().encode(request)
        } catch {
            throw TranscriptionError.invalidInput(
                "Failed to encode XPCProcessRequest: \(error.localizedDescription)"
            )
        }
    }

    /// Map XPC-layer errors to `TranscriptionError`.
    ///
    /// A `TranscriptionError` the worker threw arrives bridged and keeps its
    /// case (see `TranscriptionError+XPC.swift`). Only specific
    /// `NSCocoaErrorDomain` codes produced by NSXPCConnection are treated as
    /// connection-level failures:
    /// - 4097 (`NSXPCConnectionInterrupted`): the worker was interrupted (crash/jetsam).
    /// - 4099 (`NSXPCConnectionInvalid`): the connection is no longer valid.
    /// Other `NSCocoaErrorDomain` errors (e.g. decoding failures) fall through to
    /// `transcriptionFailed` so they are not misreported as retriable interruptions.
    static func mapError(_ error: Error) -> TranscriptionError {
        if let transcriptionError = error as? TranscriptionError {
            return transcriptionError
        }
        let nsError = error as NSError
        if let bridged = TranscriptionError(bridged: nsError) {
            return bridged
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case 4097: // NSXPCConnectionInterrupted
                return .workerInterrupted
            case 4099: // NSXPCConnectionInvalid
                return .workerUnavailable
            default:
                break
            }
        }
        return .transcriptionFailed(error.localizedDescription)
    }
}

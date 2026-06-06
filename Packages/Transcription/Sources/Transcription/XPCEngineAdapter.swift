import Foundation

/// Adapts the `@objc` `TranscriberServiceProtocol` (XPC proxy) to the async
/// Swift `TranscriptionEngine` seam.
///
/// Encodes `ProcessorConfig` as JSON for transport, decodes `Data` replies
/// back to `TranscriptResult`, and maps XPC-specific failures to
/// `TranscriptionError.workerInterrupted` / `.workerUnavailable`.
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
    private let proxyProvider: @Sendable () -> (any TranscriberServiceProtocol)?
    let config: ProcessorConfig

    /// - Parameters:
    ///   - proxyProvider: Returns the current XPC proxy, or nil if unavailable.
    ///   - config: The `ProcessorConfig` this adapter was built with. Used for
    ///     `ensureModelsDownloaded` to ensure the correct model variant is
    ///     downloaded (e.g. ramAware quantized on 8GB machines).
    init(
        proxyProvider: @escaping @Sendable () -> (any TranscriberServiceProtocol)?,
        config: ProcessorConfig
    ) {
        self.proxyProvider = proxyProvider
        self.config = config
    }

    // MARK: - TranscriptionEngine

    func ensureModelsDownloaded(
        progress _: @Sendable (Double) -> Void
    ) async throws {
        let proxy = try requireProxy()
        let configData = try encodeConfig(config)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.ensureModelsDownloaded(configData: configData) { error in
                if let error {
                    continuation.resume(throwing: self.mapError(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func processAudio(
        micPath: String?,
        systemPath: String?,
        mergedPath: String?,
        config: ProcessorConfig,
        customVocabulary: [String]
    ) async throws -> TranscriptResult {
        let proxy = try requireProxy()
        let request = XPCProcessRequest(
            micPath: micPath,
            systemPath: systemPath,
            mergedPath: mergedPath,
            config: config,
            customVocabulary: customVocabulary
        )
        let requestData = try encodeRequest(request)

        return try await withCheckedThrowingContinuation { continuation in
            proxy.processAudio(
                requestData: requestData
            ) { data, error in
                if let error {
                    continuation.resume(throwing: self.mapError(error))
                    return
                }
                guard let data else {
                    continuation.resume(
                        throwing: TranscriptionError.transcriptionFailed(
                            "XPC service returned nil data without an error"
                        )
                    )
                    return
                }
                do {
                    let result = try JSONDecoder().decode(TranscriptResult.self, from: data)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(
                        throwing: TranscriptionError.transcriptionFailed(
                            "Failed to decode TranscriptResult from XPC: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    func unloadModels() async {
        guard let proxy = proxyProvider() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proxy.unloadModels {
                continuation.resume()
            }
        }
    }

    func status() async -> ModelStatus {
        // The XPC adapter cannot directly query the worker's status machine.
        // Status is managed by the Transcriber actor that wraps this adapter.
        .ready
    }

    // MARK: - Private

    private func requireProxy() throws -> any TranscriberServiceProtocol {
        guard let proxy = proxyProvider() else {
            throw TranscriptionError.workerUnavailable
        }
        return proxy
    }

    private func encodeConfig(_ config: ProcessorConfig) throws -> Data {
        do {
            return try JSONEncoder().encode(config)
        } catch {
            throw TranscriptionError.invalidInput(
                "Failed to encode ProcessorConfig: \(error.localizedDescription)"
            )
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
    /// Only specific `NSCocoaErrorDomain` codes produced by NSXPCConnection are
    /// treated as connection-level failures:
    /// - 4097 (`NSXPCConnectionInterrupted`): the worker was interrupted (crash/jetsam).
    /// - 4099 (`NSXPCConnectionInvalid`): the connection is no longer valid.
    /// Other `NSCocoaErrorDomain` errors (e.g. decoding failures) fall through to
    /// `transcriptionFailed` so they are not misreported as retriable interruptions.
    private func mapError(_ error: Error) -> TranscriptionError {
        if let transcriptionError = error as? TranscriptionError {
            return transcriptionError
        }
        let nsError = error as NSError
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

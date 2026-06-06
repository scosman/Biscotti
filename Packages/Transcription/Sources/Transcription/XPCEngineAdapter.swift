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
    private let proxyProvider: @Sendable () -> (any TranscriberServiceProtocol)?

    /// - Parameter proxyProvider: Returns the current XPC proxy, or nil if unavailable.
    init(
        proxyProvider: @escaping @Sendable () -> (any TranscriberServiceProtocol)?
    ) {
        self.proxyProvider = proxyProvider
    }

    // MARK: - TranscriptionEngine

    func ensureModelsDownloaded(
        progress _: @Sendable (Double) -> Void
    ) async throws {
        let proxy = try requireProxy()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.ensureModelsDownloaded { error in
                if let error {
                    continuation.resume(throwing: self.mapError(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func processAudio(
        micPath: String,
        systemPath: String,
        customVocabulary: [String]
    ) async throws -> TranscriptResult {
        let proxy = try requireProxy()
        let request = XPCProcessRequest(
            micPath: micPath,
            systemPath: systemPath,
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

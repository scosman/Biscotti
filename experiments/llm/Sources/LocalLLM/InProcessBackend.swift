import Foundation

/// Runs an `InferenceEngine` in the caller's process (no child, no IPC).
///
/// Used for fast unit tests (with `MockEngine`) and as an in-process fallback.
/// The `id` parameter on generate/cancel is ignored -- serialization is handled
/// by `LLMConnection`'s semaphore, so at most one request is in-flight.
final class InProcessBackend: ServiceBackend, @unchecked Sendable {
    private var engine: any InferenceEngine
    private let lock = NSLock()
    /// Cancellation closure for the current in-flight streaming task.
    private var cancelCurrent: (@Sendable () -> Void)?

    /// Deferred model loading: when set, `start()` constructs the real LLMEngine.
    private let deferredModel: URL?
    private let deferredConfig: EngineConfig?

    init(engine: any InferenceEngine) {
        self.engine = engine
        deferredModel = nil
        deferredConfig = nil
    }

    /// Deferred-load initializer: the real `LLMEngine` is constructed at `start()`.
    ///
    /// Used by the CLI's `--backend in-process` path where the model URL and config
    /// are known at construction time but the expensive model load should happen
    /// inside `start()` (after the connection is opened).
    init(model: URL, config: EngineConfig) {
        // Placeholder engine; replaced at start() time
        engine = PlaceholderEngine()
        deferredModel = model
        deferredConfig = config
    }

    func start() async throws {
        if let model = deferredModel, let config = deferredConfig {
            engine = try await LLMEngine(modelPath: model, config: config)
        }
        // Otherwise: engine is already constructed (model loaded at init time for
        // real LLMEngine, or no-op for MockEngine). Nothing to do.
    }

    func generate(
        id _: UInt64, prompt: String, system: String?,
        options: GenerationOptions
    ) async throws -> GenerationResult {
        try await engine.generate(prompt: prompt, system: system, options: options)
    }

    func generateStreaming(
        id _: UInt64, prompt: String, system: String?,
        options: GenerationOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        // Wrap in a stream whose producer task we can cancel.
        AsyncThrowingStream { continuation in
            let task = Task { [engine] in
                let innerStream = await engine.generateStreaming(
                    prompt: prompt, system: system, options: options
                )
                do {
                    for try await event in innerStream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // The build closure runs synchronously; task is created but its
            // body hasn't reached its first suspension point yet, so
            // cancelCurrent is set before any async engine work begins.
            lock.withLock { cancelCurrent = { task.cancel() } }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func cancel(id _: UInt64) async {
        lock.withLock { cancelCurrent }?()
    }

    func shutdown() async {
        lock.withLock { cancelCurrent }?()
        await engine.unload()
    }

    nonisolated func forceKill() {
        // No-op in-process: no child to kill.
    }
}

// MARK: - Placeholder engine (used before deferred start)

/// Minimal engine that throws if used before start() replaces it with the real one.
/// Only exists to satisfy the non-optional `engine` property at init time.
private final class PlaceholderEngine: InferenceEngine, @unchecked Sendable {
    func generate(prompt _: String, system _: String?, options _: GenerationOptions) async throws -> GenerationResult {
        throw LLMServiceError.serviceUnavailable("Engine not loaded (start() not called)")
    }

    func generateStreaming(prompt _: String, system _: String?, options _: GenerationOptions) async -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMServiceError.serviceUnavailable("Engine not loaded")) }
    }

    func unload() async {}
}

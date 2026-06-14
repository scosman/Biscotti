import Foundation

/// Runs an `InferenceEngine` in the caller's process (no child, no IPC).
///
/// Used for fast unit tests (with `MockEngine`) and as an in-process fallback.
/// The `id` parameter on generate/cancel is ignored -- serialization is handled
/// by `LLMConnection`'s semaphore, so at most one request is in-flight.
final class InProcessBackend: ServiceBackend, @unchecked Sendable {
    private let engine: any InferenceEngine
    private let lock = NSLock()
    /// Cancellation closure for the current in-flight streaming task.
    private var cancelCurrent: (@Sendable () -> Void)?

    init(engine: any InferenceEngine) {
        self.engine = engine
    }

    func start() async throws {
        // Engine is already constructed (model loaded at init time for real
        // LLMEngine, or no-op for MockEngine). Nothing to do.
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

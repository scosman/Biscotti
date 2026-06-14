import Foundation
import os

/// A connection to a running LLM service session.
///
/// Each connection loads the model once (at open) and serves any number of
/// sequential generation requests through an internal serial queue. Closing the
/// connection releases all resources (and, for out-of-process backends, terminates
/// the child and reclaims its memory).
///
/// Prefer the scoped `LLMService.withConnection` form, which guarantees close on
/// every exit path. Use the explicit `LLMService.openConnection` / `close()` form
/// only for connections that outlive a single scope (e.g. a long-lived SwiftUI
/// view model).
public actor LLMConnection {
    // MARK: - State

    /// The lifecycle state of a connection.
    public enum State: Sendable, Equatable {
        case opening
        case ready
        case generating
        case closed
        case failed(LLMServiceError)

        // Equatable: failed cases compare by their LLMServiceError Equatable.
    }

    /// Current lifecycle state. Minimal UI signal -- the streaming `StreamEvent`
    /// flow is the primary UI driver; this just lets a view show
    /// "starting model.../ready/working.../closed".
    public private(set) var state: State = .opening

    // MARK: - Internals

    private let backend: any ServiceBackend
    private let semaphore = AsyncSemaphore(value: 1)
    private var nextID: UInt64 = 1
    private var didClose = false
    private static let logger = Logger(
        subsystem: "net.scosman.biscotti", category: "LLMConnection"
    )

    // MARK: - Init (internal; clients use LLMService.openConnection / withConnection)

    init(backend: any ServiceBackend) {
        self.backend = backend
    }

    /// Called by `LLMService` after construction to start the backend and
    /// transition to `.ready`. Errors are thrown to the caller (connection
    /// transitions to `.failed`).
    func start() async throws {
        do {
            try await backend.start()
            state = .ready
        } catch {
            let serviceError = mapToServiceError(error)
            state = .failed(serviceError)
            throw serviceError
        }
    }

    // MARK: - Generation (buffered)

    /// Run a single-turn generation and return the full result.
    ///
    /// Requests are serialized: concurrent calls queue in submission order behind
    /// the internal semaphore. Throws `LLMServiceError.connectionClosed` if the
    /// connection is closed or failed.
    public func generate(
        prompt: String,
        system: String? = nil,
        options: GenerationOptions = .default
    ) async throws -> GenerationResult {
        try guardReady()

        await semaphore.wait()
        defer { semaphore.signal() }

        // Re-check after acquiring the semaphore (close may have raced).
        try guardReady()

        let id = nextID
        nextID += 1
        state = .generating

        do {
            let result = try await backend.generate(
                id: id, prompt: prompt, system: system, options: options
            )
            restoreReadyIfOpen()
            return result
        } catch is CancellationError {
            restoreReadyIfOpen()
            throw LLMServiceError.cancelled
        } catch let error as LLMServiceError {
            handleServiceError(error)
            throw error
        } catch {
            restoreReadyIfOpen()
            throw error
        }
    }

    // MARK: - Generation (streaming)

    /// Run a streaming generation, yielding tokens as they arrive.
    ///
    /// Returns immediately with an `AsyncThrowingStream`. The stream acquires the
    /// serial queue on first iteration and holds it until the stream completes
    /// (`.done`), errors, or is cancelled. A consumer that stops iterating cancels
    /// the underlying request and frees the queue for the next caller.
    ///
    /// Uses the `unfolding:` factory so the element-producing closure runs in the
    /// consumer's task context. This means `withTaskCancellationHandler` fires
    /// immediately when the consumer's task is cancelled, sending the cancel frame
    /// to the child process even if iteration is suspended waiting for the next
    /// event.
    ///
    /// Throws `LLMServiceError.connectionClosed` (via the stream) if the connection
    /// is closed or failed.
    public func generateStreaming(
        prompt: String,
        system: String? = nil,
        options: GenerationOptions = .default
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        // Capture state check before returning the stream. If already closed/failed,
        // the stream immediately errors.
        if let error = closedOrFailedError() {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        // Capture actor-isolated references outside the nonisolated closure
        // to avoid repeated actor hops in the hot path.
        let backend = self.backend
        let sem = self.semaphore

        // Shared mutable state for the unfolding closure. The closure is called
        // repeatedly by the consumer's for-await loop; we need state to survive
        // between calls (semaphore acquired, id allocated, backend iterator).
        let holder = StreamHolder()

        return AsyncThrowingStream<StreamEvent, Error>(unfolding: { [weak self] () async throws -> StreamEvent? in
            // First call: acquire semaphore, validate, allocate id, start backend.
            if !holder.started {
                holder.started = true

                await sem.wait()

                if let error = await self?.closedOrFailedError() {
                    sem.signal()
                    throw error
                }
                guard let self else {
                    sem.signal()
                    throw LLMServiceError.connectionClosed
                }

                let id = await self.allocateID()
                holder.id = id
                await self.setState(.generating)

                let backendStream = backend.generateStreaming(
                    id: id, prompt: prompt, system: system, options: options
                )
                holder.iterator = backendStream.makeAsyncIterator()
            }

            guard let id = holder.id else {
                throw LLMServiceError.connectionClosed
            }

            // Pull the next event from the backend stream. Use
            // withTaskCancellationHandler so a consumer-side task.cancel()
            // immediately sends the cancel frame to the child, even if
            // iterator.next() is suspended waiting for the next event.
            let event: StreamEvent?
            do {
                event = try await withTaskCancellationHandler {
                    try await holder.iterator?.next()
                } onCancel: {
                    // Fire-and-forget: send cancel to the child process.
                    // The child will stop its work and send back a
                    // .requestError(.cancelled), which unblocks next().
                    Task {
                        await backend.cancel(id: id)
                    }
                }
            } catch is CancellationError {
                await backend.cancel(id: id)
                if let self { await self.restoreReadyIfOpen() }
                sem.signal()
                holder.cleanup()
                throw LLMServiceError.cancelled
            } catch let error as LLMServiceError {
                if let self { await self.handleServiceError(error) }
                sem.signal()
                holder.cleanup()
                throw error
            } catch {
                if let self { await self.restoreReadyIfOpen() }
                sem.signal()
                holder.cleanup()
                throw error
            }

            // nil means the backend stream ended (normal completion)
            guard let event else {
                if let self { await self.restoreReadyIfOpen() }
                sem.signal()
                holder.cleanup()
                return nil
            }

            return event
        })
    }

    // MARK: - Close

    /// Close the connection and release all resources. Idempotent.
    ///
    /// Cancels any in-flight request, shuts down the backend, and transitions
    /// to `.closed`. After close, all generation calls throw `.connectionClosed`.
    public func close() async {
        guard !didClose else { return }
        didClose = true
        await backend.shutdown()
        state = .closed
    }

    // MARK: - Deinit backstop

    deinit {
        if !didClose {
            Self.logger.warning("LLMConnection deallocated without close() — forcing kill")
            backend.forceKill()
        }
    }

    // MARK: - Internal helpers

    private func setState(_ newState: State) {
        state = newState
    }

    /// Allocate the next request ID. Must be called inside the semaphore.
    private func allocateID() -> UInt64 {
        let id = nextID
        nextID += 1
        return id
    }

    /// Restore state to `.ready` only if close() hasn't been called.
    ///
    /// Due to actor reentrancy, a generation task's completion handler can run
    /// after `close()` has set `state = .closed`. Without this guard, the
    /// handler would overwrite `.closed` back to `.ready`, breaking the
    /// invariant. This helper prevents that race.
    private func restoreReadyIfOpen() {
        if !didClose {
            state = .ready
        }
    }

    /// Throws if the connection is not in a usable state.
    private func guardReady() throws {
        if let error = closedOrFailedError() {
            throw error
        }
    }

    /// Returns an error if the connection is closed or failed; nil if usable.
    private func closedOrFailedError() -> LLMServiceError? {
        switch state {
        case .closed:
            return .connectionClosed
        case let .failed(error):
            return error
        case .opening, .ready, .generating:
            return nil
        }
    }

    /// Map an arbitrary error from backend start to an `LLMServiceError`.
    private func mapToServiceError(_ error: any Error) -> LLMServiceError {
        if let serviceError = error as? LLMServiceError {
            return serviceError
        }
        if let llmError = error as? LocalLLMError {
            return .loadFailed(llmError)
        }
        return .serviceUnavailable(String(describing: error))
    }

    /// Handle a service-level error by marking the connection failed or
    /// restoring ready (guarded against close-race).
    private func handleServiceError(_ error: LLMServiceError) {
        switch error {
        case .serviceInterrupted, .protocolError:
            // Fatal transport errors mark the connection failed -- but only
            // if close() hasn't already set the terminal state.
            if !didClose {
                state = .failed(error)
            }
        case .cancelled, .connectionClosed, .serviceUnavailable, .loadFailed:
            // Per-request or lifecycle errors don't mark the connection failed.
            restoreReadyIfOpen()
        }
    }
}

// MARK: - StreamHolder (mutable state for unfolding closure)

/// Holds mutable state across repeated calls to the `unfolding:` closure in
/// `generateStreaming`. Each call to the closure pulls the next event from the
/// backend stream; the holder keeps the iterator and metadata alive between calls.
///
/// Marked `@unchecked Sendable` because it is only accessed from one task at a
/// time (the consumer's `for try await` loop -- `unfolding:` closures are never
/// called concurrently).
private final class StreamHolder: @unchecked Sendable {
    var started = false
    var id: UInt64?
    var iterator: AsyncThrowingStream<StreamEvent, Error>.AsyncIterator?

    func cleanup() {
        iterator = nil
        id = nil
    }
}

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

        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: LLMServiceError.connectionClosed)
                    return
                }

                await self.semaphore.wait()

                // Re-check after acquiring
                if let error = await self.closedOrFailedError() {
                    self.semaphore.signal()
                    continuation.finish(throwing: error)
                    return
                }

                let id = await self.allocateID()
                await self.setState(.generating)

                let backendStream = self.backend.generateStreaming(
                    id: id, prompt: prompt, system: system, options: options
                )

                do {
                    for try await event in backendStream {
                        if Task.isCancelled {
                            await self.backend.cancel(id: id)
                            await self.restoreReadyIfOpen()
                            self.semaphore.signal()
                            continuation.finish(throwing: LLMServiceError.cancelled)
                            return
                        }
                        continuation.yield(event)
                    }
                    await self.restoreReadyIfOpen()
                    self.semaphore.signal()
                    continuation.finish()
                } catch is CancellationError {
                    await self.backend.cancel(id: id)
                    await self.restoreReadyIfOpen()
                    self.semaphore.signal()
                    continuation.finish(throwing: LLMServiceError.cancelled)
                } catch let error as LLMServiceError {
                    await self.handleServiceError(error)
                    self.semaphore.signal()
                    continuation.finish(throwing: error)
                } catch {
                    await self.restoreReadyIfOpen()
                    self.semaphore.signal()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
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

---
status: complete
---

# Phase 2: Connection + In-Process Backend

## Overview

Build the connection layer and in-process backend that let clients open an LLM session,
send generation requests (buffered and streaming), and close the session -- all without
spawning a child process. This phase introduces the `ServiceBackend` / `InferenceEngine`
seams, the `MockEngine` (canned tokens, scriptable errors), `InProcessBackend`,
`AsyncSemaphore`, the `LLMConnection` actor (state machine, serial queue, id counter),
and the `LLMService` entry points (`withConnection` / `openConnection`). Tests run
entirely in-process with `MockEngine`, so no model or binary is needed.

## Steps

1. **Create `Sources/LocalLLM/InferenceEngine.swift`** -- the engine seam protocol:
   ```swift
   protocol InferenceEngine: Sendable {
       func generate(prompt: String, system: String?,
                     options: GenerationOptions) async throws -> GenerationResult
       func generateStreaming(prompt: String, system: String?,
                              options: GenerationOptions)
           async -> AsyncThrowingStream<StreamEvent, Error>
       func unload() async
   }
   ```
   Add `InferenceEngine` conformance to `LLMEngine` (methods already match).

2. **Create `Sources/LocalLLM/MockEngine.swift`** -- a model-free test double:
   - Configurable: list of tokens to emit, optional `GenerationResult` to return,
     optional error to throw, optional delay per token.
   - Supports both buffered and streaming paths.
   - Scriptable: tests set `.tokensToEmit`, `.resultToReturn`, `.errorToThrow`.

3. **Create `Sources/LocalLLM/ServiceBackend.swift`** -- the backend seam protocol:
   ```swift
   protocol ServiceBackend: Sendable {
       func start() async throws
       func generate(id: UInt64, prompt: String, system: String?,
                     options: GenerationOptions) async throws -> GenerationResult
       func generateStreaming(id: UInt64, prompt: String, system: String?,
                              options: GenerationOptions)
           -> AsyncThrowingStream<StreamEvent, Error>
       func cancel(id: UInt64) async
       func shutdown() async
       nonisolated func forceKill()
   }
   ```

4. **Create `Sources/LocalLLM/InProcessBackend.swift`** -- wraps any `InferenceEngine`:
   - `start()` is a no-op (engine was created at init time with model already loaded).
   - `generate`/`generateStreaming` delegate to the engine, ignoring the `id`.
   - `cancel` cancels the current generation Task.
   - `shutdown` calls `engine.unload()`.
   - `forceKill` is a no-op.

5. **Create `Sources/LocalLLM/AsyncSemaphore.swift`** -- `AsyncSemaphore(value: 1)`:
   - FIFO waiter queue of `CheckedContinuation`s.
   - `@unchecked Sendable` with `NSLock` (style of existing `InterruptedFlag`).
   - `wait()` async, `signal()` sync.

6. **Create `Sources/LocalLLM/LLMConnection.swift`** -- the connection actor:
   - `State` enum: `.opening`, `.ready`, `.generating`, `.closed`, `.failed(LLMServiceError)`.
   - `state` property (read-only public).
   - Private `AsyncSemaphore(1)` for serial queue.
   - Private atomic `UInt64` id counter.
   - `generate(prompt:system:options:)` -- await semaphore, guard ready, set generating,
     call backend, restore ready, signal semaphore. Return result.
   - `generateStreaming(prompt:system:options:)` -- return `AsyncThrowingStream` whose
     producer task awaits semaphore, relays backend stream, signals on terminal event.
     `onTermination` cancels the producer task.
   - `close()` -- idempotent. Cancel in-flight, call `backend.shutdown()`, set `.closed`.
   - `deinit` -- calls `backend.forceKill()` if not closed, logs warning.

7. **Create `Sources/LocalLLM/LLMService.swift`** -- the public entry points:
   ```swift
   public enum LLMService {
       public enum Backend: Sendable { ... }
       public static func withConnection<T: Sendable>(...) async throws -> T
       public static func openConnection(...) async throws -> LLMConnection
   }
   ```
   `withConnection` opens, runs body, always closes (return + throw + cancellation).
   `openConnection` creates backend, starts it, transitions to `.ready`, returns connection.

8. **Write tests in `Tests/LocalLLMTests/ConnectionTests.swift`**:
   - open -> ready state
   - buffered generate returns correct result
   - streaming relay yields tokens then done
   - serial ordering: two overlapping generates complete in order
   - reuse-after-close -> connectionClosed
   - idempotent close
   - withConnection closes on success
   - withConnection closes on throw
   - cancellation releases the semaphore
   - mock error -> correct LocalLLMError surfaces

## Tests

- `testOpenReady`: open connection with MockEngine, verify state == .ready
- `testBufferedGenerate`: generate returns MockEngine's canned result
- `testStreamingRelay`: generateStreaming yields mock tokens then .done
- `testSerialOrdering`: two concurrent generates complete in submission order
- `testReuseAfterClose`: generate after close() throws connectionClosed
- `testIdempotentClose`: close() twice without error, state stays closed
- `testWithConnectionClosesOnSuccess`: withConnection body returns, verify closed
- `testWithConnectionClosesOnThrow`: withConnection body throws, verify closed
- `testCancellationReleasesSemaphore`: cancel a generate, verify next one proceeds
- `testMockErrorSurfaces`: MockEngine throws LocalLLMError, verify it surfaces

---
status: complete
---

# Phase 3: Out-of-Process Transport

## Overview

Build the complete out-of-process transport layer: a service executable (`localllm-service`)
that speaks the framed-JSON wire protocol over stdin/stdout pipes, and a `RemoteBackend`
that spawns/manages/reclaims it. This phase delivers the core value proposition -- full
memory reclamation by process exit. The `ServiceLoop` (service side) and `RemoteBackend`
(client side) slot into the `ServiceBackend` seam Phase 2 created. Tests spawn a real
`--fake` child process to exercise the full transport path in CI without a model.

## Steps

1. **`Package.swift`**: Add executable target `llm-service` (product `localllm-service`)
   depending on `LocalLLM`. Create `Sources/Service/main.swift` with argv parsing
   (`--model`, `--config` JSON, `--fake`) that delegates to `ServiceLoop.run()`. (arch S2)

2. **`Sources/LocalLLM/ServiceLoop.swift`** -- the service-side event loop:
   - `init(inputHandle:, outputHandle:, engine: InferenceEngine?, fake: Bool)`.
   - `run()` async: rescue-and-gag stdout (dup real stdout to private frameOut fd, redirect
     fd 1 to /dev/null); send `.ready`; enter reader loop decoding `ServiceRequest` frames
     from stdin.
   - For `--fake` mode: no engine needed; instant `.ready`; canned token emission for
     `generate`; magic prompts `__CRASH__` (exit(1)) and `__SLEEP__` (long cancellable
     sleep).
   - Reader runs concurrently with a single serial worker task for generation.
   - `.cancel(id)` cancels the current worker task.
   - `.shutdown` / stdin EOF -> ordered teardown -> `_exit(0)`.
   - Unit-testable: accepts `FileHandle` parameters so tests can use in-memory pipes.

3. **`Sources/LocalLLM/RemoteBackend.swift`** -- the client-side `ServiceBackend`:
   - Binary resolution: explicit URL > `LOCALLLM_SERVICE_PATH` env > sibling of running
     binary (CLI case) > sibling of bundle URL (xctest case). Not found ->
     `LLMServiceError.serviceUnavailable`.
   - `start()`: spawn `Process` with pipes; verbosity-gated stderr; read first event
     (`.ready` or `.loadError`).
   - Reader task: concurrent loop decoding `ServiceEvent` frames; routes events via
     continuations keyed by request id.
   - Writer: `NSLock`-guarded write so cancel/shutdown can't interleave with request frames.
   - `generate`/`generateStreaming`: write request frame, await result via continuation/stream.
   - `cancel(id)`: send `.cancel` frame.
   - `shutdown()`: close/kill sequence (send `.shutdown` + close stdin + grace timeout +
     SIGTERM + SIGKILL). Idempotent via `didShutdown` flag.
   - `forceKill()`: nonisolated, lock-guarded `kill(pid, SIGKILL)` deinit backstop via
     `TransportHandle`.
   - EOF/crash detection: unexpected EOF -> `serviceInterrupted`, fail in-flight requests.

4. **Wire `RemoteBackend` into `LLMService.createBackend`**: the `.outOfProcess` case
   now creates a `RemoteBackend` instead of throwing "not yet implemented".

5. **`Tests/LocalLLMTests/TransportTests.swift`** -- spawn real `--fake` child:
   - Helper to resolve `localllm-service` binary or `XCTSkip`.
   - `testOpenReady`: spawn fake service, verify connection reaches `.ready`.
   - `testFakeGenerate`: buffered generate returns canned result.
   - `testFakeStream`: streaming yields canned tokens then `.done`.
   - `testCancelMidStream`: `__SLEEP__` prompt, cancel mid-stream, verify queue freed
     for next request.
   - `testCrashServiceInterrupted`: `__CRASH__` prompt -> `serviceInterrupted` +
     `state == .failed`.
   - `testCloseReclaims`: after `close()`, verify the child pid is gone
     (`kill(pid, 0)` -> ESRCH).
   - `testDeinitBackstop`: drop connection without `close()`, verify child is killed.

## Tests

- `testOpenReady`: spawn `--fake` service via `RemoteBackend`, verify `state == .ready`
- `testFakeGenerate`: buffered generate returns the fake service's canned result
- `testFakeStream`: streaming yields canned tokens then `.done(GenerationResult)`
- `testCancelMidStream`: send `__SLEEP__` prompt, cancel the stream, verify next generate
  succeeds (semaphore released)
- `testCrashServiceInterrupted`: send `__CRASH__` prompt, verify `serviceInterrupted`
  error and `state == .failed`
- `testCloseReclaims`: close the connection, verify child pid is gone via `kill(pid,0)`
  returning ESRCH
- `testDeinitBackstop`: drop a connection without closing, verify the child process is
  killed within a grace window

---
status: complete
---

# Architecture: LLM XPC Service Interface

Scope: `experiments/llm` only. Builds on the existing `LocalLLM` library (`LLMEngine`,
`GenerationOptions`, `GenerationResult`, `StreamEvent`, `EngineConfig`, `LocalLLMRuntime`,
`LocalLLMError`) and mirrors the repo's proven out-of-process pattern in
`Packages/Transcription` + `XPCServices/BiscottiTranscriber` (engine seam, connection
actor owns lifecycle, worker `_exit`s to reclaim memory). Transport here is a **spawned
child process + framed JSON over pipes** (not `NSXPCConnection`) so the whole thing runs
from `swift run` and `swift test` with no app bundle — see functional spec §1, §10.

## 1. Process topology

```
┌──────────────────────── client process (app / CLI / test) ─────────────────────────┐
│  LLMService.withConnection { conn in … }                                            │
│        │ opens                                                                        │
│        ▼                                                                              │
│  LLMConnection (actor)                                                               │
│    • state machine (opening→ready→generating→closed/failed)                          │
│    • AsyncSemaphore(1)  ← serial queue: one request at a time                         │
│    • request-id counter                                                               │
│    • delegates to a backend ───────────────┐                                         │
│                                            ▼                                          │
│                         ┌──────────────────────────────────┐                         │
│                         │  any ServiceBackend               │                         │
│                         ├───────────────┬──────────────────┤                         │
│                         │ InProcess     │ Remote (default) │                          │
│                         │ (LLMEngine /  │  Process + pipes  │                         │
│                         │  MockEngine)  │  + reader task    │                         │
│                         └───────────────┴────────┬─────────┘                         │
└──────────────────────────────────────────────────┼───────────────────────────────────┘
                                  stdin (req frames) │ stdout (event frames)   stderr=logs
                                                     ▼
                       ┌──────────────── service process (localllm-service) ───────────┐
                       │  ServiceLoop                                                   │
                       │   • argv: --model, --ctx-size/--config, [--fake]               │
                       │   • reader task decodes ServiceRequest frames                  │
                       │   • single worker runs LLMEngine (real) or canned (--fake)     │
                       │   • emits ServiceEvent frames (ready/token/done/error/fatal)   │
                       │   • stdin EOF or .shutdown → ordered teardown → _exit(0)        │
                       └────────────────────────────────────────────────────────────────┘
```

One service process per open out-of-process connection. No pooling, no sharing (§ out of
scope). Closing the connection terminates the service; the OS reclaims 100% of its memory.

## 2. Target / module layout (`experiments/llm/Package.swift`)

| Target | Kind | Product | Depends on | Holds |
|---|---|---|---|---|
| `LocalLLM` | library | `LocalLLM` | LlamaSwift | **existing engine** + **new**: client API (`LLMService`, `LLMConnection`), backends, `ServiceBackend` seam, wire protocol types + codec, `ServiceLoop`, `LLMServiceError`, `InferenceEngine` seam |
| `llm-service` | **new** executable | `localllm-service` | LocalLLM | tiny `main.swift` → parses argv → `ServiceLoop.run()` |
| `llm-cli` | executable | `localllm` | LocalLLM, ArgumentParser | `run` reworked over `LLMService`; `download` unchanged |
| `LocalLLMTests` | test | — | LocalLLM | new lifecycle/codec/transport tests |

Rationale for putting the client API **and** `ServiceLoop` in `LocalLLM` (not a separate
module): the wire types and `ServiceLoop` are shared by both sides; the service executable
is a 5-line `main` so all testable logic lives in the library and runs under `swift test`.

**`swift test` build-order gotcha (must-handle):** `swift test` builds the test target and
its dependencies only; `localllm-service` is *not* a dependency of the test target, so a
bare `swift test` will **not** build it, and the fake-spawn tests would find no binary. The
agent/CI flow already runs **`build_llm` (swift build, builds all products) before
`test_llm`**, so the binary exists in `.build/<triple>/debug/` at test time. The transport
tests additionally **resolve-or-skip**: if the binary isn't found they `XCTSkip` with
"run build_llm first" rather than failing spuriously. (See §13.)

## 3. Public client API (final surface)

All types `Sendable`; everything `async`. Reuses existing `GenerationOptions` /
`GenerationResult` / `StreamEvent` / `EngineConfig` verbatim.

```swift
public enum LLMService {
    public enum Backend: Sendable {
        case outOfProcess(serviceBinary: URL? = nil)   // default; nil → auto-resolve (§7.1)
        case inProcess                                  // real LLMEngine, no child
    }

    /// Scoped, leak-proof form (headline). Opens, runs body, ALWAYS closes on exit
    /// (return / throw / cancellation). Returns body's value.
    public static func withConnection<T: Sendable>(
        model: URL,
        backend: Backend = .outOfProcess(),
        config: EngineConfig = .default,
        _ body: (LLMConnection) async throws -> T
    ) async throws -> T

    /// Explicit form (advanced / long-lived SwiftUI). Caller MUST `await close()`.
    /// Spawns + loads + awaits ready before returning.
    public static func openConnection(
        model: URL,
        backend: Backend = .outOfProcess(),
        config: EngineConfig = .default
    ) async throws -> LLMConnection
}

public actor LLMConnection {
    public enum State: Sendable, Equatable {
        case opening, ready, generating, closed
        case failed(LLMServiceError)
    }
    public var state: State { get }                     // minimal UI signal (§ functional 3.5)

    public func generate(
        prompt: String, system: String? = nil, options: GenerationOptions = .default
    ) async throws -> GenerationResult

    public func generateStreaming(
        prompt: String, system: String? = nil, options: GenerationOptions = .default
    ) -> AsyncThrowingStream<StreamEvent, Error>

    public func close() async                            // idempotent; reclaims service
    // deinit: nonisolated best-effort SIGKILL backstop if not closed (§7.4)
}
```

`withConnection` body (guaranteed close on every path, incl. cancellation — `close()` is a
fresh await that still runs after a `CancellationError`):

```swift
let conn = try await openConnection(model: model, backend: backend, config: config)
do { let r = try await body(conn); await conn.close(); return r }
catch { await conn.close(); throw error }
```

### `LLMServiceError`

```swift
public enum LLMServiceError: Error, LocalizedError, Sendable, Equatable {
    case serviceUnavailable(String)   // binary not found / spawn failed (at open)
    case loadFailed(LocalLLMError)    // model load failed in the service (at open)
    case serviceInterrupted           // crash / unexpected exit mid-session — RETRIABLE
    case connectionClosed             // used after close() / in failed state
    case protocolError(String)        // frame decode / unexpected message
    case cancelled                    // request cancelled via Task cancellation
}
```

Generation-level failures keep their existing `LocalLLMError` cases (overflow, decode,
tokenization, …), reconstructed faithfully on the client side (§10).

## 4. Engine seam & backends

A single seam lets the connection be backend-agnostic and lets unit tests run with no model.

```swift
// Satisfied by the real engine, a mock, and the remote proxy.
protocol ServiceBackend: Sendable {
    func start() async throws                              // load (in-proc) / spawn+ready (remote)
    func generate(id: UInt64, prompt: String, system: String?,
                  options: GenerationOptions) async throws -> GenerationResult
    func generateStreaming(id: UInt64, prompt: String, system: String?,
                           options: GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error>
    func cancel(id: UInt64) async                          // best-effort
    func shutdown() async                                  // close/kill + reclaim
    nonisolated func forceKill()                           // deinit backstop (no-op in-proc)
}
```

- **`InProcessBackend`** wraps an `InferenceEngine` (the real `LLMEngine`, or a mock):
  ```swift
  protocol InferenceEngine: Sendable {
      func generate(prompt: String, system: String?, options: GenerationOptions) async throws -> GenerationResult
      func generateStreaming(prompt: String, system: String?, options: GenerationOptions)
          async -> AsyncThrowingStream<StreamEvent, Error>
      func unload() async
  }
  ```
  `LLMEngine` gains an `InferenceEngine` conformance (its methods already match;
  `start()` constructs the `LLMEngine(modelPath:config:)`, surfacing load errors).
  `cancel(id:)` cancels the current generation `Task`. `shutdown()` calls `unload()`.
  Unit tests inject `MockEngine` (canned tokens/results, scriptable errors) so no model is
  needed.

- **`RemoteBackend`** owns the child `Process` + pipes + reader task and translates the
  `ServiceBackend` calls into wire frames (§6, §7). This is the default.

The **serial queue, state machine, and id allocation live in `LLMConnection`** (above the
backend), so semantics are identical for both backends and the wire stays simple
(concurrency 1).

## 5. Serial queue (one request at a time)

`LLMConnection` is an actor, but `await` inside an actor method allows reentrancy, so a
naive implementation would interleave requests. Serialization is explicit via a small
`AsyncSemaphore(value: 1)` (FIFO waiter queue of `CheckedContinuation`s; `@unchecked
Sendable` with an `NSLock`, in the style of the existing `InterruptedFlag`).

- `generate`: `await sema.wait()` → guard `ready` → `id = next()` → `state=.generating` →
  `defer { state=.ready; sema.signal() }` → `try await backend.generate(id, …)`.
- `generateStreaming`: returns an `AsyncThrowingStream` whose producing `Task` does
  `await sema.wait()` first, relays backend stream events to the consumer, and
  `sema.signal()`s on the terminal event (`.done`/error/cancel). `continuation.onTermination`
  → `task.cancel()` so a consumer that stops iterating cancels the request (which sends
  `.cancel` to the service) and frees the queue. The semaphore is thus held for the full
  duration of a streamed response.

Result: concurrent `generate`/stream calls on one connection run strictly in submission
order; a stream blocks later requests until it completes or is cancelled.

## 6. Wire protocol

### 6.1 Framing
`FrameCodec`: each frame = **4-byte big-endian `UInt32` length** + that many bytes of
JSON. Reads use a *read-exactly-N* loop over the pipe (handles partial reads/coalesced
frames). A length over a sanity cap (e.g. 64 MB) → `protocolError`. EOF mid-frame → the
peer died (→ `serviceInterrupted` on the client; clean exit on the service).

### 6.2 Messages (Codable enums)

```swift
enum ServiceRequest: Codable {
    case generate(id: UInt64, prompt: String, system: String?, options: GenerationOptions, streaming: Bool)
    case cancel(id: UInt64)
    case shutdown
}

enum ServiceEvent: Codable {
    case ready                                  // model loaded, accepting requests
    case loadError(WireError)                   // load failed → service will exit
    case token(id: UInt64, piece: String)
    case reasoningToken(id: UInt64, piece: String)
    case done(id: UInt64, result: GenerationResult)
    case requestError(id: UInt64, error: WireError)   // per-request failure; connection stays healthy
    case fatal(WireError)                       // service-level unrecoverable; connection fails
}
```

Model path + `EngineConfig` are passed at **spawn** (argv/JSON), not as a message, so the
service can load before emitting `ready`.

### 6.3 Codable additions to existing types
Add `Codable` to: `GenerationOptions`, `EngineConfig`, `GenerationResult`, `FinishReason`,
`ThinkingMode` (all synthesizable — simple structs/enums). `StreamEvent` need **not** be
Codable (the wire uses `ServiceEvent`). Golden round-trip tests lock these (§13).

### 6.4 `WireError` (error transport)
A `Codable` mirror of the error space, mapped 1:1 to/from `LocalLLMError` +
service-level cases:

```swift
enum WireError: Codable, Equatable {
    case modelFileNotFound(path: String)
    case modelLoadFailed(String)
    case contextCreationFailed(String)
    case tokenizationFailed(String)
    case contextOverflow(promptTokens: Int, contextSize: Int)
    case generationFailed(String)
    case decodeFailed(code: Int32)
    case cancelled
    case downloadFailed(url: String, underlying: String)
    case service(String)        // generic service-side failure
}
```
`WireError.from(_ error:)` on the service maps any `LocalLLMError` (and falls back to
`.service(message)`); `WireError.toClientError()` reconstructs the matching `LocalLLMError`
(or `LLMServiceError` for `.service`). `.cancelled` → `LLMServiceError.cancelled`.

## 7. Out-of-process transport (`RemoteBackend`)

### 7.1 Locating & spawning the service binary
Resolution order (first that exists):
1. explicit `serviceBinary:` URL on the backend;
2. `LOCALLLM_SERVICE_PATH` env var;
3. **sibling of the running binary** — try both
   `Bundle.main.executableURL!.deletingLastPathComponent()` (CLI case) and
   `Bundle.main.bundleURL.deletingLastPathComponent()` (xctest case → `.build/<triple>/debug/`),
   appending `localllm-service`.
Not found → `LLMServiceError.serviceUnavailable`.

Spawn via `Foundation.Process`:
- `executableURL` = resolved binary; `arguments` = `["--model", model.path, "--config",
  <EngineConfig as JSON>]` (+ `"--fake"` in tests).
- `standardInput` = `requestPipe` (client → service requests; nothing else writes the
  child's stdin, so it's inherently clean);
- `standardOutput` = `responsePipe` — its write end is **rescued** by the service and used
  as the private frame channel (see below);
- `standardError` = **verbosity-gated** (`RemoteBackend` takes a `verbose: Bool`): default
  → `/dev/null` (suppresses the residual backend noise the user sees); `verbose` → inherited
  so logs are one flag away. The CLI wires this to its existing `--verbose` flag; either way
  stderr noise is **harmless** to the protocol (frames are on the rescued fd).

**Frame-channel integrity is structural, not disciplinary.** We do *not* rely on silencing
llama.cpp/ggml/Metal (which leak past the `*_log_set` no-op callbacks at the C level). The
service's **first action, before any model load or logging**, rescues the real stdout and
gags fd 1:
```c
int frameOut = dup(STDOUT_FILENO);                 // private copy of the pipe to the parent
int z = open("/dev/null", O_WRONLY);
dup2(z, STDOUT_FILENO); close(z);                  // fd 1 → /dev/null
fcntl(frameOut, F_SETFD, FD_CLOEXEC);
```
Frames are then written **only** to `frameOut` (an unbuffered `FileHandle(fileDescriptor:
frameOut, closeOnDealloc: false)`), which the C libraries have no handle to. Any
`printf`/`fprintf(stdout)` from the backend goes to `/dev/null`; `fprintf(stderr,…)` goes
to the log channel. Frame integrity no longer depends on gagging anything. Logger
silencing (`LocalLLMRuntime.verbose=false`) is kept purely to tidy the stderr logs — it is
not load-bearing.
> Alternative considered: a dedicated control FD (socketpair on fd 3) via `posix_spawn`,
> taking frames fully off the std streams. Rejected for the experiment — same guarantee as
> rescue-and-gag but loses `Foundation.Process` (`terminationHandler`, etc.) for manual
> `posix_spawn`/`waitpid`. Revisit at Project-10 productionization if useful.

### 7.2 Reader / writer
- **Reader task** (detached): loops `FrameCodec.readFrame(responsePipe)` → decode
  `ServiceEvent` → route into the connection:
  - `ready`/`loadError` → resolve the `open()` continuation;
  - `token`/`reasoningToken`/`done`/`requestError` → drive the in-flight request's stream
    continuation or buffered continuation (keyed by `id`);
  - `fatal` → fail the connection (`.serviceInterrupted` / mapped).
  - EOF / read error while a request is in flight or before an expected `shutdown` →
    treat as crash → `serviceInterrupted`, fail in-flight, mark connection `failed`.
- **Writes** (`generate`/`cancel`/`shutdown` frames) go through a single `NSLock`-guarded
  write so a `cancel` issued from a stream-termination handler can't interleave bytes with
  a request frame. (Requests themselves are already serialized by the semaphore;
  `cancel`/`shutdown` are the only concurrent writers.)

### 7.3 Close / kill sequence (`shutdown()`)
1. mark `expectedExit = true`;
2. best-effort send `.shutdown` frame, then **close the request pipe** (stdin EOF — the
   service's primary exit trigger);
3. `await` process exit with a short grace timeout (e.g. 2 s) via `terminationHandler`
   bridged to a continuation;
4. if still running → `process.terminate()` (SIGTERM); after another short grace →
   `kill(pid, SIGKILL)`;
5. reader task ends on pipe EOF; release any waiters with `serviceInterrupted` only if
   `expectedExit == false`.
Idempotent (guarded by a `didShutdown` flag).

### 7.4 deinit backstop
`RemoteBackend` keeps a `nonisolated`, lock-guarded `TransportHandle { pid, isRunning }`.
`LLMConnection.deinit` (nonisolated) calls `backend.forceKill()` → if still running,
`kill(pid, SIGKILL)` synchronously + `os_log` a warning. Guarantees a dropped connection
can't strand an 8 GB process. (In-process backend `forceKill()` is a no-op.)

## 8. Service process (`ServiceLoop`, `llm-service` `main`)

`main.swift`: parse argv (`--model`, `--config` JSON, `--fake`) → `await
ServiceLoop(...).run()`. All logic in `ServiceLoop` (library, unit-testable over in-memory
pipes).

Flow:
0. **Rescue-and-gag stdout** (very first, before any load/log): `dup` the real stdout to a
   private `frameOut` fd, repoint fd 1 → `/dev/null` (§7.1). All frames go to `frameOut`;
   requests are read from `STDIN_FILENO`.
1. **Load.** Real: `LLMEngine(modelPath:config:)`; on throw → send `loadError(WireError)`
   → ordered exit. Fake: skip; canned generator. Then send `ready`.
2. **Reader task** decodes `ServiceRequest` frames from stdin:
   - `.generate` → hand to the **single worker** (serial; engine is single-context). The
     worker runs `generate`/`generateStreaming`; streaming relays each piece as a
     `token`/`reasoningToken` frame, then `done`; on `LocalLLMError` → `requestError`.
   - `.cancel(id)` → cancel the current worker `Task` (engine honors `Task.isCancelled`).
   - `.shutdown` → break loop → teardown.
   - **stdin EOF** (parent died / pipe closed) → break loop → teardown (no-orphan
     guarantee).
3. **Teardown / exit** (reuses the CLI's proven sequence to avoid the ggml-metal `rsets`
   SIGABRT): `await engine.unload()` → `LocalLLMRuntime.shutdown()` → `fflush` →
   `_exit(0)`. Fake mode: just `_exit(0)`.

The reader runs concurrently with the worker so a `.cancel` arrives mid-generation. Client
serialization keeps ≤1 in-flight, so the worker is a single current `Task`.

`--fake` mode: `ready` immediately; for each `generate`, emit a few canned
`token`/`reasoningToken` frames then `done` (with a plausible `GenerationResult`). A magic
prompt (e.g. prefix `__CRASH__`) makes the fake service `exit(1)` mid-request to exercise
the crash path; `__SLEEP__` to exercise cancellation. This lets CI cover spawn → stream →
cancel → crash → reclaim **without the model** (§13).

## 9. Cancellation, end-to-end

1. Consumer stops iterating / cancels its `Task` → stream `onTermination` → producer
   `Task.cancel()`.
2. Producer sends `ServiceRequest.cancel(id)` and **releases the semaphore immediately**,
   finishing the client stream with `LLMServiceError.cancelled`.
3. Service cancels its worker `Task`; the engine's decode loop sees `Task.isCancelled` and
   throws `LocalLLMError.cancelled`; service sends `requestError(id, .cancelled)`.
4. A late `requestError`/`done` for an already-cancelled `id` is **ignored** by the reader
   (id no longer registered). Connection remains healthy for the next request.

## 10. Error handling strategy

| Failure | Wire | Client surface | Connection after |
|---|---|---|---|
| Binary missing / spawn fail | — | `LLMServiceError.serviceUnavailable` (at open) | never opened |
| Model load fail | `loadError` | `LLMServiceError.loadFailed(LocalLLMError)` (at open) | service exits |
| Prompt overflow / decode / tokenize | `requestError` | matching `LocalLLMError` | **healthy** (per-request) |
| Generation cancelled | `requestError(.cancelled)` | `LLMServiceError.cancelled` | healthy |
| Service crash / unexpected exit | EOF / `fatal` | `LLMServiceError.serviceInterrupted` (**retriable**) | `failed` |
| Frame decode / unexpected msg | — | `LLMServiceError.protocolError` | `failed` |
| Use after close / while failed | — | `LLMServiceError.connectionClosed` | unchanged |

**Recoverable vs fatal:** per-request `LocalLLMError`s leave the connection usable;
transport/lifecycle errors mark it `failed` and the caller opens a new connection (the
service auto-spawns fresh — exactly the Transcriber `workerInterrupted` retriable model).
**Logging:** `os.Logger` subsystem `net.scosman.biscotti`, categories `LLMConnection`
(client) and `LLMService` (service); backend (llama/ggml) noise stays silenced.

## 11. State machine (`LLMConnection.State`)

```
            open()                ready frame
   ∅ ──────────────► opening ───────────────► ready ◄──────────┐
                        │                       │  generate/     │ done/requestError
                        │ loadError/spawn fail  ▼  stream start  │
                        ▼                    generating ─────────┘
                     failed ◄──── interrupt/protocol ──── (any)
   ready/generating ── close() ──► closed   (idempotent)
```
`generate`/`generateStreaming` require `ready` (else `connectionClosed`/`failed` surfaces).
Only `ready→generating→ready` cycles during a session.

## 12. CLI changes (`llm-cli`)

- `RunCommand` is reimplemented over `LLMService.withConnection`:
  - default `--backend out-of-process` (also `in-process` for A/B-debug);
  - one-shot: open → single `generate`/`generateStreaming` → block closes (reclaim);
  - **all existing behavior preserved**: `--stream`, the always-on `=== thinking ===` /
    `=== response ===` sections, `--show-raw`, the stderr speed summary, sampling flags,
    `--thinking`, `--template`. Template selection that currently happens in the CLI moves
    behind the same `GenerationOptions`/system-prompt path the engine already supports, so
    output is unchanged.
  - The CLI's manual backend-teardown + `_exit` hack is **removed** — for out-of-process
    the child owns teardown; the parent CLI exits normally. (In-process `--backend` reuses
    `LocalLLMRuntime.shutdown()` as today.)
- `DownloadCommand` is **unchanged** (in-process file download; no service).

## 13. Testing strategy

**Always-on unit tests** (`test_llm`, no model, CI-gating):
- *Codec*: round-trip every `ServiceRequest`/`ServiceEvent`; partial-read reassembly;
  coalesced frames; oversized-length → `protocolError`; truncated/garbage → error.
- *Codable*: `GenerationOptions`/`EngineConfig`/`GenerationResult` round-trips.
- *WireError mapping*: every `LocalLLMError` → `WireError` → client error, both directions.
- *Connection (InProcess + MockEngine)*: open→ready; buffered `generate`; streaming relay;
  **serial ordering** (two overlapping `generate`s complete in order); reuse-after-close →
  `connectionClosed`; idempotent `close`; `withConnection` closes on **return and on
  throw**; cancellation releases the semaphore; mock error → correct `LocalLLMError`.
- *Real transport via `--fake` service (spawns a real child)*: open→ready; canned
  `generate`/stream; cancel mid-stream (`__SLEEP__`) stops + frees queue;
  `__CRASH__` → `serviceInterrupted` + `state==failed`; **`close()` reclaims** — assert the
  pid is gone (`kill(pid, 0)` → ESRCH) within the grace window; **deinit backstop** — drop
  a connection without `close()` and assert the child is killed. Each *resolves-or-skips*
  the binary (§2).

**AI/integration tests** (`LLM_RUN_AI=1`, human/Phase-4, real model): rewritten over
`LLMService` (default out-of-process). A **single shared connection** across the suite
(load-once/serve-many) like today's shared-engine suite. Re-cover: stack-works,
determinism, streaming/buffered parity through the new layer. Add: **reclamation** — after
`close()` the real service pid is gone. Optionally one `.inProcess` parity case.

Frameworks: Swift Testing (matching the existing suite); `Synchronization`/`NSLock` for the
sendable boxes.

## 14. Technical risks & decided tradeoffs

- **Frame channel vs. backend noise.** Backend logging (llama/ggml/Metal) leaks past the
  `*_log_set` callbacks at the C level and can't be fully silenced from Swift — so we do
  **not** depend on silencing for correctness. The service rescues the real stdout to a
  private fd and gags fd 1 → `/dev/null` (§7.1, §8 step 0), making frame integrity
  structural. Residual noise on stderr is harmless. Chosen over a dedicated `posix_spawn`
  control FD because it keeps `Foundation.Process` for the same guarantee.
- **`swift test` doesn't build the executable** → resolve-or-skip + build-first flow (§2).
- **rsets SIGABRT** on service exit is avoided by reusing the CLI's ordered
  `unload → LocalLLMRuntime.shutdown → _exit(0)` (§8); the `_exit` hack leaves the *client*
  and lives only in the *service* now.
- **Not real NSXPC.** Deliberate (functional §10). The `ServiceBackend` seam is the swap
  point: Project 10 replaces `RemoteBackend`'s `Process`+pipes with an `NSXPCConnection`
  adapter behind the **unchanged** `LLMService`/`LLMConnection` API.
- **Concurrency = 1** keeps the wire trivial and matches the single-context engine; ids are
  retained for robustness/future multiplexing.

## 15. Out of scope / future

Per functional §10: multi-turn state, real `.xpc`/NSXPC, service-side download, connection
pooling, full `AsyncStream<State>`, custom vocabulary. The NSXPC swap and productionization
land in Project 10 (Intelligence), reusing this API and `ServiceBackend` seam.

## 16. Build phasing (preview; detailed in implementation_plan.md)

Single coherent subsystem; suggested phases: **(1)** wire types + codec + Codable + WireError
(+ tests); **(2)** `ServiceBackend` seam, `InProcessBackend`/`MockEngine`, `LLMConnection`
(state + semaphore) + `LLMService.withConnection`/`openConnection` (+ in-proc tests);
**(3)** `llm-service` executable + `ServiceLoop` + `--fake` + `RemoteBackend` (spawn/pipes/
reader/close/backstop) (+ fake-spawn tests); **(4)** CLI rework + AI-test rewrite + README/
VALIDATION updates.
```

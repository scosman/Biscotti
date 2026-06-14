---
status: complete
---

# Functional Spec: LLM XPC Service Interface

## 1. Goal & motivation

Wrap the existing `LocalLLM` library in a **service interface** whose defining property
is **complete, prompt resource reclamation**: a long-running app can spin up an LLM,
do a burst of work, and then release *everything* — the multi-GB model, the Metal
device, all working memory — back to the OS, leaving near-zero long-term footprint.
Between bursts the app carries no LLM memory at all.

Three properties make this worth a dedicated layer:

1. **Memory is temporary.** The model lives in a **separate process**. When the client
   closes the connection, that process exits and the OS reclaims 100% of its memory.
   No "unload but the process lingers and re-fragments" — the process is *gone*.
2. **Crash isolation.** If inference crashes (llama.cpp/Metal/OOM-jetsam), it takes
   down only the service process, not the host app. The client sees a retriable error.
3. **Load-once / serve-many within a session.** Inside one open connection the model
   loads exactly once and serves any number of requests through an internal serial
   queue — never reloaded mid-session.

The client-facing API is designed so that **using it correctly is the path of least
resistance**: a scoped `withConnection { … }` block opens the service, runs a batch of
requests, and is *guaranteed* to close on exit. Forgetting to close a connection would
leave an 8 GB process resident, so the API steers hard toward the scoped form and adds a
deinit backstop for the rest.

This is an **experiment** (`experiments/llm` only). It proves the technique and leaves
reference code for Project 10 (Intelligence), where the transport will become a real
`.xpc` bundle inside the app — but the **client-facing API designed here is the durable
deliverable** and carries over unchanged.

## 2. Terminology

- **Connection** — the client-side handle to one running service session. Opening it
  starts a service and loads the model; closing it stops the service and reclaims memory.
- **Service process** — the separate child process that owns the `LLMEngine` and the
  model in memory. One per open out-of-process connection.
- **Backend** — *how* a connection runs its engine: `.outOfProcess` (spawns a child
  service process — the default, the real reclamation proof) or `.inProcess` (runs the
  engine in the caller's process — fast unit tests + a no-isolation fallback). Identical
  client API for both.
- **Request** — one independent single-turn generation (prompt → result). The engine
  clears its KV cache per request; there is **no multi-turn conversation state** carried
  on the connection (see §10).
- **Batch** — several requests issued against one open connection before it closes.

## 3. Client-facing API (the headline deliverable)

All public types are `Sendable` and the API is fully `async`/`await`, so a `@MainActor`
SwiftUI view model can drive it directly and publish results/tokens to the UI.

### 3.1 Scoped form — primary, strongly preferred

The "Swift version" of `with connection { … }` is a static scoped helper that opens a
connection, hands it to a closure, and closes it on **every** exit path (return, throw,
cancellation) via `defer`. It returns whatever the closure returns:

```swift
let summary = try await LLMService.withConnection(
    model: modelURL,                 // path to the GGUF
    backend: .outOfProcess,          // default
    config: .default                 // EngineConfig (context size, seed, …)
) { connection in
    // Model is loaded once here; reused for every call below.
    let s  = try await connection.generate(prompt: summarizePrompt)
    let ai = try await connection.generate(prompt: actionItemsPrompt)
    return s.text + "\n" + ai.text
}
// Service process is GUARANTEED gone here; memory reclaimed.
```

This is the form documentation leads with and examples use everywhere.

### 3.2 Connection handle — the two request methods

The closure receives an `LLMConnection` (an `actor`). It exposes exactly the two
generation shapes the user asked for, mirroring today's `LLMEngine`:

```swift
// Non-streaming: await the full result.
func generate(
    prompt: String,
    system: String? = nil,
    options: GenerationOptions = .default
) async throws -> GenerationResult

// Streaming: consume tokens as they arrive (drives live SwiftUI).
func generateStreaming(
    prompt: String,
    system: String? = nil,
    options: GenerationOptions = .default
) -> AsyncThrowingStream<StreamEvent, Error>
```

`GenerationOptions`, `GenerationResult`, and `StreamEvent` are the **existing** library
types, reused verbatim. Streaming yields the existing `.token` / `.reasoningToken` /
`.done(GenerationResult)` events, and the final `.done` result is byte-identical to the
buffered path (the engine already guarantees this; the service layer must preserve it
across the wire).

**Streaming inside the scoped block.** Both request shapes work inside `withConnection`;
a streamed request is consumed to completion within the block, which keeps the model
loaded for any further requests:

```swift
try await LLMService.withConnection(model: modelURL) { connection in
    for try await event in connection.generateStreaming(prompt: summarizePrompt) {
        switch event {
        case .token(let p):          await vm.append(p)          // live SwiftUI
        case .reasoningToken(let p): await vm.appendThinking(p)
        case .done(let r):           await vm.finish(r)
        }
    }
    let items = try await connection.generate(prompt: actionItemsPrompt)  // same loaded model
    await vm.setActionItems(items.text)
}
// service process gone here; memory reclaimed
```

**Lifetime rule (correctness):** because the connection closes on block exit, a stream
must be **fully consumed inside the block**. Returning the `AsyncThrowingStream` out of
the block and iterating it afterward throws `LLMServiceError.connectionClosed` (the
service is already torn down). A SwiftUI flow whose stream must outlive a single function
scope uses the explicit `openConnection` / `close()` form (§3.3) instead — hold the
connection on the view model, close it when the interaction ends.

### 3.3 Explicit lifecycle — secondary, for connections that outlive one scope

A SwiftUI flow sometimes needs a connection to live across several distinct user actions
(not one function scope). For that, an explicit form exists but is documented as the
advanced path:

```swift
let connection = try await LLMService.openConnection(model: modelURL)   // spawn + load
// … hold it on a view model, use across user actions …
await connection.close()                                                // reclaim now
```

Safety net: if an `LLMConnection` is deallocated without `close()` having been called,
its `deinit` tears the service process down anyway (best-effort backstop) and logs a
warning. The scoped form remains the recommended default precisely so this backstop is
rarely the thing that saves you.

### 3.4 Backend selection

`backend:` defaults to `.outOfProcess`. `.inProcess` runs the same engine in the
caller's process (no child, no reclamation-by-exit) — used by fast tests and as a
fallback when process isolation isn't available/wanted. Both satisfy the identical
`LLMConnection` contract, so callers (and the CLI) are backend-agnostic.

### 3.5 Connection state (for live UI)

`LLMConnection` exposes a lightweight, `Sendable` state value for UI binding:

```swift
enum State: Sendable { case opening, ready, generating, closed, failed(LLMServiceError) }
var state: State { get async }
```

Kept intentionally minimal — the streaming `StreamEvent` flow is the primary UI driver;
`state` just lets a view show "starting model…/ready/working…/closed". (A full
`AsyncStream<State>` is **out of scope** for the experiment; §10.)

## 4. Lifecycle & resource-reclamation contract

This section is the heart of the project; behavior here is non-negotiable.

1. **Open = spawn + load + await ready.** Opening a `.outOfProcess` connection spawns the
   service process, which loads the model immediately. `open`/`withConnection` does not
   return until the service reports **ready** (or an error). Model-load errors
   (missing/corrupt file, context-creation failure) surface at open. Load timing is
   preserved (reported via the first request's `GenerationResult.loadDuration`, as today).
2. **Serial queue.** A connection processes **one request at a time**, in submission
   order. Concurrent `generate` calls against the same connection are queued, not run in
   parallel (the model/context is single-threaded). A streaming request holds the queue
   until its stream completes or is cancelled.
3. **Never reloaded.** Within one open connection the model loads exactly once and is
   held until close. No mid-session unload/reload.
4. **Close = cancel + terminate + reclaim.** Closing cancels any in-flight request, then
   terminates the service process and waits for it to exit. After `close()`/block exit,
   the service's memory is fully released. Close is **idempotent** and safe to call
   multiple times.
5. **No orphans / parent-death safety.** The service process watches its control channel
   for EOF; if the parent (client) dies or the channel closes, the service **exits
   itself** so an 8 GB process is never orphaned. On its own exit path the service runs
   the existing ordered teardown (`LocalLLMRuntime.shutdown()` then hard-exit) to avoid
   the known ggml-metal `rsets` SIGABRT.
6. **Reuse after close is an error.** Calling `generate`/`generateStreaming` on a closed
   (or failed) connection throws `LLMServiceError.connectionClosed`.

## 5. Streaming contract

- `generateStreaming` yields `.token` / `.reasoningToken` events as the service produces
  them, then a terminal `.done(GenerationResult)`; the stream finishes after `.done`.
- **Cancellation propagates across the process boundary.** If the consuming `Task` is
  cancelled or the stream's consumer stops iterating, the connection sends a cancel
  message to the service, which stops its decode loop promptly (the engine already honors
  `Task.isCancelled`). A cancelled stream throws `LLMServiceError.cancelled` (or finishes,
  per the existing engine semantics) and frees the queue for the next request.
- **Buffered/streaming parity** holds end-to-end: the `.done` result over the wire equals
  what a `generate` call would return for the same inputs (modulo the existing
  whitespace-trim invariant the engine documents).

## 6. Wire protocol (functional level)

Detailed framing/encoding is an **architecture** concern; functionally:

- The client and service exchange **length-prefixed JSON frames** over a private pipe
  pair (client→service: requests; service→client: responses/events). The service's
  `stderr` remains a plain diagnostic/log channel (llama.cpp/ggml backend noise stays
  there, never on the protocol channel).
- **Client→service** message kinds: `generate(id, prompt, system, options, streaming)`,
  `cancel(id)`, `shutdown`.
- **Service→client** message kinds: `ready` (after load) / `loadError(error)`;
  `token(id, piece)`, `reasoningToken(id, piece)`, `done(id, result)`, `error(id, error)`
  for in-flight requests; `fatal(error)` for unrecoverable service-level failures.
- Model path + `EngineConfig` are passed to the service at spawn (argv/env), so it can
  load before the first request and emit `ready`.
- The frame **codec and message types are independently unit-testable** (round-trip
  encode/decode) without spawning anything.

## 7. Error handling & edge cases

A new `LLMServiceError` covers transport/lifecycle failures; generation failures reuse
`LocalLLMError`, mapped faithfully across the boundary.

| Situation | Behavior |
|---|---|
| Service binary can't be located/spawned | `LLMServiceError.serviceUnavailable` (with reason) at open |
| Model file missing / load fails | Existing `LocalLLMError.modelFileNotFound` / `.modelLoadFailed` surfaced at open |
| Service crashes mid-request (Metal/OOM/jetsam) | In-flight call throws `LLMServiceError.serviceInterrupted` (**retriable** — open a fresh connection); connection becomes `failed`. Host app unaffected. |
| Service exits unexpectedly between requests | Next request throws `.serviceInterrupted`; connection `failed` |
| Protocol decode error / unexpected frame | Connection invalidated → `.protocolError`; service torn down |
| `generate` after `close()` | `.connectionClosed` |
| Concurrent `generate` calls on one connection | Serialized by the queue (not an error) |
| `close()` with a request in flight | In-flight request cancelled, then teardown |
| Task cancellation during `generate`/stream | Propagated to service; surfaces as `.cancelled`; queue freed |
| Context overflow / decode failure | Existing `LocalLLMError.contextOverflow` / `.decodeFailed` surfaced for that request; connection stays usable |
| Connection deallocated without `close()` | `deinit` backstop tears down the service; warning logged |

**Recoverable vs fatal:** per-request generation errors (overflow, decode, cancel) leave
the connection healthy for subsequent requests. Transport/lifecycle failures
(interrupted, protocol error) mark the connection `failed`; the caller opens a new one.

## 8. CLI changes

The CLI uses the service interface, **one-shot** (per the chosen scope): each invocation
opens a connection, runs its single request, and closes — proving the
spawn → load → generate → reclaim cycle from the command line on every run.

- `localllm run …` is reimplemented over `LLMService.withConnection(.outOfProcess) { … }`.
  All existing flags/output (streaming vs buffered, `=== thinking ===` / `=== response ===`
  sections, speed summary on stderr, `--show-raw`) are preserved.
- A `--backend out-of-process|in-process` flag (**default `out-of-process`**) lets a
  developer A/B the two backends and debug without a child process.
- `localllm download …` is **unchanged** and stays fully in-process: it only fetches a
  file (no model memory), so it needs no service. The service assumes the model already
  exists on disk.
- The service binary ships as its own executable product (e.g. `localllm-service`) in the
  same package; `localllm` locates and spawns it.

## 9. Testing strategy

- **Always-on unit tests** (no model, run in CI via `test_llm`): cover the connection
  semantics directly —
  - frame codec round-trips;
  - lifecycle (open→ready→close, idempotent close, deinit backstop, reuse-after-close);
  - serial-queue ordering and streaming relay;
  - error mapping (interrupted/protocol/closed/cancelled);
  - the scoped `withConnection` guarantee (closes on return **and** on throw).
  These run against the `.inProcess` backend with a **mock engine** (canned tokens), so no
  model is needed.
- **Real out-of-process transport in CI — fake-service mode.** The service binary has a
  `--fake` mode that speaks the real protocol but emits canned tokens instead of loading a
  model. Always-on tests **actually spawn, stream from, cancel, and reclaim** a real child
  process in CI — exercising the spawn/kill/exit path that is the whole point — without the
  8 GB model. (Without this, the real transport would be covered only by human-run AI tests.)
- **AI/integration tests** (`LLM_RUN_AI=1`, human/Phase-4 run, real model): updated to go
  through `LLMService`. They **share one open connection** across tests for speed
  (load-once/serve-many), mirroring today's shared-engine suite. At least one test asserts
  the reclamation contract end-to-end (service process exits on close). Keep coverage for
  determinism and streaming/buffered parity through the new layer.

## 10. Out of scope

- **Multi-turn / conversation state.** Each request is independent (fresh KV cache), as
  the engine already enforces. No chat history on the connection.
- **A real `.xpc` bundle / `NSXPCConnection`.** Deferred to Project 10 productionization
  (needs an app host bundle/launchd). This experiment uses the spawn-child + framed-IPC
  transport behind the same client API, so the swap is transport-only.
- **Model download over the service.** Stays an in-process CLI concern.
- **Multiple concurrent connections sharing one service / a pool.** One service per open
  connection; no pooling.
- **A full `AsyncStream<State>` status feed.** A minimal `state` value only.
- **Custom vocabulary** (blocked upstream; repo-wide).

## 11. Resolved decisions

1. **Scoped-primary + explicit-secondary + deinit backstop** (§3.1/3.3): **confirmed.**
   Both forms ship — scoped `withConnection` is the headline; explicit
   `openConnection`/`close()` exists for connections that outlive one scope (e.g.
   long-lived SwiftUI) — with a `deinit` safety net as a leak backstop.
2. **Fake-service mode for CI** (§9): **confirmed.** The service binary gets a `--fake`
   mode so always-on CI tests exercise the real spawn/stream/cancel/reclaim path without
   the 8 GB model.
3. **`--backend` CLI flag** (§8): **confirmed**, with **default `out-of-process`**. The
   in-process toggle is for debugging/A-B.
4. **Single-turn only** (§2/§10): **confirmed.** No multi-turn chat state on the
   connection for this experiment.

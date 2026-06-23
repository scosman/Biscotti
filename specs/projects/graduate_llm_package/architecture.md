---
status: complete
---

# Architecture: Graduate LLM Package

Execution plan for: graduating `experiments/llm` → `Packages/LocalLLM`, **replacing the pipe
transport with a real NSXPC service `BiscottiLLM.xpc`** (mirroring `BiscottiTranscriber.xpc`),
hardening to a production bar, wiring into the build/test surface, and adding an XPC-driven
ManualTestApp tab. Single doc — no separate component designs.

The public client API (`LLMService`/`LLMConnection`) and the `ServiceBackend` seam are
**preserved**; only the backend behind the seam changes (pipe `RemoteBackend` → NSXPC
`XPCBackend`). This is exactly the swap the prior project parked behind the seam for "Project
10," pulled forward.

## 1. Final shape (package + repo)

```
Packages/LocalLLM/
  Package.swift                 # 2 products now: LocalLLM (lib), localllm (CLI). No service exe.
  Package.resolved  .gitignore  README.md
  Prompts/  Fixtures/sample_transcript.txt
  Sources/
    LocalLLM/                   # library  (product: LocalLLM)
    CLI/                        # executable target llm-cli (product: localllm)
  Tests/LocalLLMTests/

XPCServices/BiscottiLLM/        # NEW — shared xpc-service sources (like BiscottiTranscriber)
  main.swift                    # NSXPC host wrapping an in-process LLMConnection
  Info.plist                    # CFBundlePackageType XPC!, ServiceType Application
  BiscottiLLM.entitlements      # app-sandbox = false
```

### Package.swift (concrete)

- Two products: `.library(name:"LocalLLM", targets:["LocalLLM"])`,
  `.executable(name:"localllm", targets:["llm-cli"])`. **Remove** the `llm-service` target and
  `localllm-service` product.
- `warningsAsErrors` `SwiftSetting` (`[.unsafeFlags(["-warnings-as-errors"])]`) on every target;
  `swiftLanguageModes: [.v6]`.
- Test target: `resources: [.copy("Fixtures"), .copy("Prompts")]`.
- Keep the `localllm` product / `llm-cli` target split (APFS case collision is real); drop the
  experiment clause from the comment. Match trailing-comma style.
- Dependencies unchanged: `mattt/llama.swift`, `apple/swift-argument-parser` (CLI only).

> The XPC service host (`XPCServices/BiscottiLLM/main.swift`) is **not** part of the SPM
> package — it's an Xcode `xpc-service` target compiled by the consuming app project
> (ManualTestApp here), depending on the `LocalLLM` package product. This mirrors
> BiscottiTranscriber exactly (its `main.swift` lives in `XPCServices/`, the protocol + DTOs +
> client adapter live in the `Transcription` package).

## 2. Process topology

```
┌──────────── client process (app / ManualTestApp) ─────────────┐
│  LLMService.withConnection(backend: .hosted(serviceName:)) {…} │
│      │ opens                                                   │
│      ▼                                                         │
│  LLMConnection (actor)  — state machine, AsyncSemaphore(1)     │
│      │ delegates to ServiceBackend                             │
│      ▼                                                         │
│  XPCBackend ── NSXPCConnection(serviceName:) ───────────────┐ │
│   • remoteObjectInterface = LLMServiceProtocol              │ │
│   • exportedInterface     = LLMEventReporting               │ │
│   • exportedObject        = LLMEventReceiver (reverse proxy)│ │
└─────────────────────────────────────────────────────────────┘ │
                         NSXPC  │  reverse proxy: token/done/error │
                                ▼                                  │
        ┌──────────── BiscottiLLM.xpc (launchd-managed) ──────────┘
        │  NSXPCListener.service() + ServiceDelegate               │
        │  LLMXPCService (exported)  → wraps an in-process          │
        │     LLMConnection (LLMService.openConnection(.inProcess)) │
        │  ConnectionCounter → last invalidation → ordered teardown │
        │     (close → LocalLLMRuntime.shutdown) → _exit(0)         │
        └──────────────────────────────────────────────────────────┘
```

One service process per open connection. Closing the connection invalidates it → service exits
→ OS reclaims 100% of the model's memory. The CLI and `swift test` use `.inProcess` (no XPC).

## 3. Public client API (preserved)

```swift
public enum LLMService {
    public enum Backend: Sendable {
        case hosted(serviceName: String)   // NSXPC to BiscottiLLM.xpc
        case inProcess                     // real LLMEngine (CLI, tests, and the XPC host itself)
    }
    public static func withConnection<T: Sendable>(
        model: URL, backend: Backend, config: EngineConfig = .default,
        _ body: (LLMConnection) async throws -> T) async throws -> T
    public static func openConnection(
        model: URL, backend: Backend, config: EngineConfig = .default) async throws -> LLMConnection
}

public actor LLMConnection {
    public enum State: Sendable, Equatable { case opening, ready, generating, closed; case failed(LLMServiceError) }
    public var state: State { get }
    public func generate(prompt: String, system: String? = nil,
                         options: GenerationOptions = .default) async throws -> GenerationResult
    public func generateStreaming(prompt: String, system: String? = nil,
                         options: GenerationOptions = .default) -> AsyncThrowingStream<StreamEvent, Error>
    public func close() async   // idempotent; .hosted → invalidate (service reclaims); .inProcess → unload
}
```

`Backend` loses its default (was `.outOfProcess()`); callers state the backend explicitly. The
serial queue / state machine / `withConnection` close-on-every-path logic stay in
`LLMConnection`, unchanged. `LLMServiceError` keeps its cases (serviceUnavailable, loadFailed,
serviceInterrupted (retriable), connectionClosed, protocolError, cancelled) — they map naturally
to NSXPC failures.

## 4. The `@objc` XPC contract

`@objc` protocols can't use `Codable`/generics/`UInt64`, so DTOs cross as JSON `Data`. Strict
serialization (one in-flight generation per connection) means **no request ids on the wire**.

```swift
// client → service
@objc public protocol LLMServiceProtocol {
    func load(requestData: Data, reply: @escaping @Sendable (Error?) -> Void)            // {modelPath, config}
    func generate(requestData: Data, reply: @escaping @Sendable (Data?, Error?) -> Void) // buffered → GenerationResult Data
    func generateStreaming(requestData: Data, reply: @escaping @Sendable (Error?) -> Void) // tokens via reverse proxy; reply at terminal
    func cancel(reply: @escaping @Sendable () -> Void)                                    // cancels the in-flight generation
    func healthCheck(reply: @escaping @Sendable (Bool) -> Void)
}

// service → client (reverse proxy; streaming path)
@objc public protocol LLMEventReporting {
    func reportToken(_ piece: String)
    func reportReasoningToken(_ piece: String)
    func reportDone(resultData: Data)   // final GenerationResult (Codable → Data)
    func reportError(errorData: Data)   // LLMErrorPayload (Codable → Data)
}
```

### DTOs (Codable; all in the `LocalLLM` library)

- `LLMLoadRequest { modelPath: String; config: EngineConfig }`
- `LLMGenerateRequest { prompt: String; system: String?; options: GenerationOptions }`
- `GenerationResult` (reused; keep its Codable conformance)
- `LLMErrorPayload` — the Codable error mirror (this is the **renamed/retained `WireError`**:
  same case set mapping `LocalLLMError` + service-level failures). Transport-agnostic; now used
  for `reportError` and for bridging buffered-`generate` errors. `from(_:)`/`toClientError()`
  retained. (Keep the type; it is *not* part of the deleted framing.)

### Error bridging across the `@objc` boundary

Buffered `generate` replies `(Data?, Error?)`: on failure the service wraps `LLMErrorPayload`
into an `NSError(domain: "net.scosman.biscotti.LocalLLM", code:, userInfo: ["payload": Data])`;
the client's `mapError` decodes the payload back to `LocalLLMError`/`LLMServiceError`. Streaming
errors cross as `reportError(errorData:)` (the payload `Data` directly). NSXPC
interruption/invalidation (no reply) → `LLMServiceError.serviceInterrupted`.

## 5. Client adapter (`XPCBackend: ServiceBackend`)

Mirrors `XPCEngineAdapter` + `TranscriberXPCConnectionImpl` + `TranscriberStatusReceiver`.

- **`start()`** — create `NSXPCConnection(serviceName:)`; set `remoteObjectInterface =
  NSXPCInterface(with: LLMServiceProtocol.self)`, `exportedInterface = NSXPCInterface(with:
  LLMEventReporting.self)`, `exportedObject = LLMEventReceiver()`; install
  `interruptionHandler` (set an `InterruptedFlag` → next call surfaces `serviceInterrupted`) and
  `invalidationHandler` (log); `activate()`; then `withCheckedThrowingContinuation { proxy.load(
  encode(LLMLoadRequest)) { err in resume } }`. Spawn/connect failure → `serviceUnavailable`;
  load failure → `loadFailed`.
- **`generate(...)`** — `withCheckedThrowingContinuation { proxy.generate(encode(req)) { data,
  err in decode GenerationResult / mapError } }`.
- **`generateStreaming(...)`** — return an `AsyncThrowingStream`; in its body set the
  `LLMEventReceiver` handlers (lock-guarded) to push `.token`/`.reasoningToken`, finish on
  `reportDone` (yield `.done(result)` then finish) / `reportError` (finish throwing); call
  `proxy.generateStreaming(encode(req)) { err in if let err finish-throwing }`. On terminal or
  consumer cancellation (`onTermination`), **detach the receiver handlers** so a late callback is
  dropped, and send `proxy.cancel` if cancelled.
- **`cancel(id:)`** — `proxy.cancel { }` (best-effort; id ignored on the wire).
- **`shutdown()`** — `connection.invalidate()` (idempotent via a `didShutdown` flag) → service
  connection-count → 0 → `_exit(0)`.
- **`forceKill()`** (nonisolated deinit backstop) — `connection?.invalidate()`.

`LLMEventReceiver: NSObject, LLMEventReporting, @unchecked Sendable` holds lock-guarded
`token/reasoning/done/error` handler closures (like `TranscriberStatusReceiver`, but four
methods); `set…`/`clear` swap them per request.

## 6. The XPC service host (`XPCServices/BiscottiLLM/main.swift`)

A thin NSXPC ↔ in-process-`LLMConnection` bridge — reuses **all** existing in-process logic
(serial queue, streaming, cancellation, ordered teardown) so the host adds no inference logic.

```swift
import Foundation; import os.log; import LocalLLM

final class LLMXPCService: NSObject, LLMServiceProtocol, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let holder = ConnectionHolder()          // actor: stores the in-process LLMConnection + current Task
    init(connection: NSXPCConnection?) { self.connection = connection }

    func load(requestData: Data, reply: @escaping @Sendable (Error?) -> Void) {
        // decode LLMLoadRequest → Task { let c = try await LLMService.openConnection(
        //   model: url, backend: .inProcess, config: cfg); await holder.set(c); reply(nil) } catch reply(NSError…)
    }
    func generate(requestData: Data, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        // decode LLMGenerateRequest → Task { let r = try await holder.conn.generate(…);
        //   reply(encode(r), nil) } catch reply(nil, nserror(LLMErrorPayload.from(error)))
    }
    func generateStreaming(requestData: Data, reply: @escaping @Sendable (Error?) -> Void) {
        let reporter = UncheckedSendableBox(connection?.remoteObjectProxy as? LLMEventReporting)
        // Task stored in holder so cancel() can reach it:
        //   for try await ev in holder.conn.generateStreaming(…) {
        //       .token→reporter.reportToken; .reasoningToken→reportReasoningToken; .done(r)→reportDone(encode(r)) }
        //   reply(nil)   // catch: reporter.reportError(encode(payload)); reply(nil or nserror)
    }
    func cancel(reply: @escaping @Sendable () -> Void) { /* Task { await holder.cancelCurrent(); reply() } */ }
    func healthCheck(reply: @escaping @Sendable (Bool) -> Void) { reply(true) }
}
```

`ConnectionHolder` is a small `actor` storing the loaded `LLMConnection` and the current
generation `Task` (for `cancel`). `UncheckedSendableBox` wraps the non-`Sendable` NSXPC proxy
exactly as `BiscottiTranscriber/main.swift` does.

### Listener, reclamation, teardown (mirror BiscottiTranscriber)

- `ServiceDelegate.listener(_:shouldAcceptNewConnection:)`: set `exportedInterface =
  LLMServiceProtocol`, `remoteObjectInterface = LLMEventReporting`, `exportedObject =
  LLMXPCService(connection:)`; `connectionCounter.increment()`; install interruption (log) and
  **invalidation** handlers; `connection.resume()`; return `true`.
- **Invalidation handler** (the reclamation trigger): on last connection
  (`decrementAndCheckZero()`), perform **ordered Metal teardown then `_exit(0)`** — `await
  holder.conn?.close()` (frees context/model) → `LocalLLMRuntime.shutdown()`
  (`llama_backend_free()`) → `_exit(0)` (skips C++ static destructors / the ggml `rsets` assert).
  Because the handler is sync, bridge to the async close via a detached `Task` + a short bounded
  wait, then `_exit(0)`; if the close can't be awaited in time, `_exit(0)` still reclaims (the OS
  frees memory on process death — teardown order only matters to avoid the in-process assert,
  which `_exit` already bypasses).
- Entry point: `NSXPCListener.service(); listener.delegate = …; listener.resume()`.

### Info.plist / entitlements (`XPCServices/BiscottiLLM/`)

`Info.plist`: `CFBundleIdentifier = net.scosman.biscotti.BiscottiLLM`, `CFBundleName =
BiscottiLLM`, `CFBundlePackageType = XPC!`, `CFBundleVersion = 1`,
`CFBundleShortVersionString = 0.0.1`, `XPCService = { ServiceType = Application }`.
`BiscottiLLM.entitlements`: `com.apple.security.app-sandbox = false` (non-sandboxed; matches the
repo's distribution model). No audio entitlement (LLM needs none); no special Metal/GPU
entitlement (non-sandboxed processes get GPU access — BiscottiTranscriber uses Metal with none).

## 7. Lifecycle, serialization, cancellation, retry

- **Open** (`.hosted`): connect + `load` + await ready. **Serial**: `LLMConnection`'s
  `AsyncSemaphore(1)` keeps ≤1 in-flight generation, so the service handles one at a time and the
  wire needs no ids. **Streaming** holds the semaphore for the full response; `onTermination`
  cancels.
- **Cancel**: consumer cancels → stream `onTermination` → `XPCBackend` detaches its receiver and
  calls `proxy.cancel`; the host cancels the in-process generation `Task` (engine honors
  `Task.isCancelled`); client finishes the stream with `.cancelled`. Late reverse-proxy callbacks
  are dropped (receiver detached).
- **Close / reclaim**: `LLMConnection.close()` → `XPCBackend.shutdown()` →
  `connection.invalidate()` → host invalidation → ordered teardown → `_exit(0)`.
- **Crash / interruption**: host crash fires the client `interruptionHandler` → `InterruptedFlag`
  → in-flight call surfaces `LLMServiceError.serviceInterrupted` (retriable); the next
  `openConnection` relaunches a fresh service via `launchd`. Mirrors the transcriber's
  `workerInterrupted` retriable model.
- **deinit backstop**: `LLMConnection.deinit` (nonisolated) → `backend.forceKill()` →
  `connection?.invalidate()` so a dropped connection can't strand an 8 GB worker.

## 8. Deletions vs. retained

**Delete** (pipe transport + experiment scaffolding): `RemoteBackend.swift` (Process/pipes/
stdout rescue-and-gag), `ServiceLoop.swift`, `Sources/Service/` + the `llm-service` target,
`FrameCodec.swift`, the framed `ServiceRequest`/`ServiceEvent` in `WireProtocol.swift`, `--fake`
mode + magic prompts, `Tests/.../TestServiceBinary.swift`, `Tests/.../TransportTests.swift`,
`LOCALLLM_SERVICE_PATH` resolution, `SamplingFallback` (+ `SamplingTests`), `BuiltinChatTemplate`
+ `useBuiltinTemplate`. Move `MockEngine` → test target.

**Retain** (now serving the XPC path): `LLMService`/`LLMConnection`/`ServiceBackend` seam,
`InProcessBackend`, `InferenceEngine`, `LLMEngine`, `GenerationOptions`/`GenerationResult`/
`EngineConfig`/`StreamEvent`/`FinishReason`/`ThinkingMode`/`LocalLLMError`/`LLMServiceError`,
`GemmaChatTemplate`/`OutputParser`/`StreamingChannelSplitter`, `Sampling` (llama.cpp chain),
`ModelDownloader`, `LocalLLMRuntime`, the Codable conformances, and `LLMErrorPayload` (ex-
`WireError`). **Add**: `LLMServiceProtocol`/`LLMEventReporting`, the DTOs, `XPCBackend`,
`LLMEventReceiver`, `LocalLLMPaths` (§13.4).

## 9. Move mechanics

`git mv experiments/llm Packages/LocalLLM` (tracked files only; `.build*`/artifacts excluded).
Path-string fixes in comments/docs (`ChatTemplate.swift`, `LLMEngine.swift`, README). The
deleted `TestServiceBinary`/`TransportTests` remove the only `#filePath`-package-root logic, so
no path-walk logic survives to update.

## 10. Hardening change-list

Per functional spec §"Quality bar". Concretely: manifest (§1); deletions (§8); framing/path
edits (`LocalLLMCLI.swift:10`, `CLIHelpers.swift:8`, `LLMEngine.swift:319-320,421`,
`LLMService.swift:13`, `ServiceBackend.swift:6`, `LocalLLMRuntime.swift:11`,
`ChatTemplate.swift:32-34,131`); lint (>120-char lines, force-unwraps → safe unwraps or justified
inline disables for `strdup`/`URL(string:)!`); `GenerationResult` debug-field framing tidy;
access-control tightening bounded by what the **XPC service target** + tests need across the
module boundary (the `@objc` protocols, DTOs, `LLMService`/`LLMConnection`, `LLMErrorPayload`,
`EngineConfig`, `LocalLLMRuntime` must stay `public`; collapse genuinely-internal types).

## 11. CLI changes (`llm-cli`)

In-process only. **Remove the `--backend` flag** (and `--template`, per the builtin removal).
`RunCommand` runs `LLMService.withConnection(model:, backend: .inProcess, config:) { … }`. Keep
all output behavior (`--stream`, `=== thinking ===`/`=== response ===` sections, `--show-raw`,
sampling flags, `--thinking`, stderr speed summary) and the ordered teardown + `_exit` Metal
workaround (reword its TODO). `DownloadCommand` unchanged (in-process `ModelDownloader`).

## 12. Build / test / CI wiring

- **Makefile**: `PACKAGES += Packages/LocalLLM`; `test-ai` appends
  `BISCOTTI_RUN_AI_TESTS=1 swift test --package-path Packages/LocalLLM`.
- **Env rename** `LLM_RUN_AI` → `BISCOTTI_RUN_AI_TESTS` (in `IntegrationTests.swift`,
  `StreamingTests.swift`, README); keep `LLM_MODEL_PATH`. AI suites run `.inProcess`; add a
  model-presence skip-with-message.
- **`hooks_mcp.yaml`**: repoint `build_llm`/`test_llm` to `Packages/LocalLLM`.
- **`make build-app`** now builds + embeds `BiscottiLLM.xpc` via ManualTestApp; keep it green.
- **`ci.yml`**: unchanged (`make ci` picks up the package via `PACKAGES`; lint via the glob).

## 13. ManualTestApp: LocalLLM tab (XPC-driven)

### 13.1 Script (ManualTestKit) — `Scripts/LocalLLMScript.swift`

`public extension TestScript { static let localLLM = TestScript(id: "local_llm", title: "Local
LLM", steps: [ … ]) }` with the `llm_*` steps from functional spec §ManualTestApp. Action
closures are placeholder no-ops; register `.localLLM` in `Scripts/AllScripts.swift`.

### 13.2 `ManualTestApp/project.yml`

- `packages:` += `LocalLLM: { path: ../Packages/LocalLLM }`.
- Add the xpc-service target (mirror `BiscottiTranscriber`):
  ```yaml
  BiscottiLLM:
    type: xpc-service
    platform: macOS
    deploymentTarget: "15.0"
    sources:
      - path: ../XPCServices/BiscottiLLM
        excludes: ["*.plist", "*.entitlements"]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: net.scosman.biscotti.BiscottiLLM
        INFOPLIST_FILE: ../XPCServices/BiscottiLLM/Info.plist
        CODE_SIGN_ENTITLEMENTS: ../XPCServices/BiscottiLLM/BiscottiLLM.entitlements
    dependencies:
      - package: LocalLLM
        product: LocalLLM
  ```
- `ManualTestApp` target `dependencies:` += `- package: LocalLLM / product: LocalLLM` and
  `- target: BiscottiLLM / embed: true`.

### 13.3 `WiredScripts.swift` — `wireLocalLLM(_:)`

- `case "local_llm": wireLocalLLM(script)` in `all()`.
- `llm_model_download` → in-process `ModelDownloader(cacheDirectory: LocalLLMPaths
  .defaultModelCacheDir()).download { bytes, total in status(progressLine) }`.
- `llm_xpc_inference` (and the streaming/quality drivers) → real XPC:
  ```swift
  let model = ModelDownloader(cacheDirectory: cache).modelPath
  let text = try await LLMService.withConnection(
      model: model, backend: .hosted(serviceName: "net.scosman.biscotti.BiscottiLLM")
  ) { conn in try await conn.generate(prompt: …, options: …).text }
  status(text)
  ```
  Streaming steps use `generateStreaming` and append tokens to `status` so the human sees live
  tokens routed through XPC.
- `.humanQuestion`/`.instruction` steps need no wiring.

### 13.4 Shared default cache path

Add `enum LocalLLMPaths { public static func defaultModelCacheDir() -> URL }` to the library
(`~/Library/Application Support/Biscotti/llms/`); the CLI and the tab both use it (one
authoritative path; matches `ModelDownloader`'s caller-supplies-dir contract).

### 13.5 Reclamation check (`llm_reclamation`)

An `autoCheck` is preferred over a human question: after an XPC generation + `close()`, verify no
`BiscottiLLM` service process remains. Implement in `ManualTestKit/AutoChecks.swift`
(`checkNoLLMServiceRunning`) by enumerating processes (e.g. `sysctl`/`proc_listpids`, or a
bundled `pgrep`-style check) for a `BiscottiLLM` executable; the app is non-sandboxed so process
enumeration is permitted. Fall back to a `humanQuestion` if enumeration proves unreliable.

### 13.6 Results & staleness

Results committed only after a human run. `CLAUDE.md`: touching `Packages/LocalLLM` (or
`XPCServices/BiscottiLLM`) marks `llm_*` recordable steps `not-run`.

## 14. Testing strategy

- **Always-on unit suite** (gating, `make test`): connection lifecycle, serial ordering,
  streaming relay, cancellation, `withConnection` close-on-return/throw, error mapping —
  all over `InProcessBackend` + `MockEngine`. Codable round-trips for the DTOs +
  `LLMErrorPayload` mapping (every `LocalLLMError` ↔ payload, both directions). Chat-template
  golden tests, output-parser, streaming-splitter. **No NSXPC tests** (can't host an embedded
  service under `swift test`) — same as Transcription. Deleted transport/sampling/builtin tests
  are expected reductions.
- **Model-backed suite** (`make test-ai`, human, `.inProcess`): load, greedy determinism,
  streaming-vs-buffered parity.
- **ManualTestApp tab** (human, hardware): the `llm_*` steps through `BiscottiLLM.xpc` — the only
  place the NSXPC path is exercised.
- **Lint** (`make lint --strict`): clean over the package.

## 15. Risks / watch-items

- **NSXPC token streaming** via the reverse proxy is the main new surface — get the
  receiver-detach-on-terminal/cancel right to avoid leaked/late callbacks; cover the relay logic
  with in-process unit tests up to the XPC seam, validate the real seam on hardware.
- **Reclamation via invalidation** — the sync invalidation handler must reliably `_exit(0)`
  after ordered teardown; don't block it on an un-awaitable async close (bounded wait, then
  `_exit`). Validate with `llm_reclamation`.
- **xpc-service discovery from ManualTestApp** — `NSXPCConnection(serviceName:)` finds the
  embedded `.xpc` in `Contents/XPCServices/`; confirm `make build-app` embeds it (mirrors
  BiscottiTranscriber, so high confidence).
- **Access-control vs. the xpc-service module boundary** — the `@objc` protocols/DTOs/
  `LLMService`/`LLMConnection`/`EngineConfig`/`LocalLLMRuntime`/`LLMErrorPayload` must remain
  `public`; verify downgrades against the `BiscottiLLM` target build, not just the library.
- **`-warnings-as-errors`** may surface latent warnings — budget time.
- **Bundle resources** — adding `.copy("Prompts")`/`.copy("Fixtures")` must not shadow a test's
  filesystem-relative assumption.

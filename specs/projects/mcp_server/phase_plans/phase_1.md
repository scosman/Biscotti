---
status: complete
---

# Phase 1: Dependencies and transport plumbing

## Overview

Resolve the MCP SDK and swift-nio into `Packages/BiscottiKit`, create the
`MCPServer` module (product + target + tests), and stand up the whole server
skeleton minus tools: configuration, state types, the NIO HTTP listener, the
NIO⇄MCP channel bridge, the lifecycle controller (wiring an `MCP.Server` with
an **empty tool catalog**), and logging. Verified by HTTP-surface tests, an
`initialize` + `tools/list` round trip on an ephemeral port, and the lifecycle
cases.

## Spike outcome (architecture §2.1) — decided

**`0.12.1` won.** `swift package resolve` + `swift build` both succeed on this
toolchain (Swift 6.1 manifest; the `swift-docc-plugin` `branch: "main"` entry
does not trip resolution here). Pinned `.exact("0.12.1")`; swift-nio resolved
to `2.101.3` (`from: "2.65.0"`). Recorded in a comment next to the dependency.
No fallback to `0.11.0` needed.

## Steps

1. **`Packages/BiscottiKit/Package.swift`** — add dependencies
   (`swift-sdk` `.exact("0.12.1")` with the spike-outcome comment;
   `swift-nio` `from: "2.65.0"`), the `MCPServer` product, the `MCPServer`
   target (deps: `DataStore`, `MCP`, `NIOCore`, `NIOConcurrencyHelpers`,
   `NIOPosix`, `NIOHTTP1`), and the `MCPServerTests` target (deps:
   `MCPServer`, `DataStore` — the raw-socket test client uses POSIX via
   `Darwin`, so the test target links no NIO products).

2. **`Sources/MCPServer/MCPServerConfiguration.swift`** — host/port/path/
   `endpointURL` + `maxBodyBytes` (1 MB), `maxConcurrentConnections` (16),
   `idleTimeoutSeconds` (120). (`searchCandidatePool`/`maxResultLimit` are
   tool-logic constants; they land in Phase 2 with the code that uses them.)
   Deviation from the original plan text: the constant URL carries **no**
   `swiftlint:disable:next force_unwrapping` — SwiftLint 0.63.3 does not flag
   call-result unwraps (`URL(...)!`), so the disable command is rejected as
   *superfluous* and breaks `--strict`. A code comment records this; add the
   disable only if a SwiftLint bump starts flagging call results.

3. **`Sources/MCPServer/MCPServerState.swift`** — `MCPServerState`
   (stopped/starting/running(URL)/failed) and `MCPServerStartError`
   (portInUse/bindFailed) with `userMessage` carrying the functional-spec §2.3
   strings (SettingsUI renders, never composes — Phase 3).

4. **`Sources/MCPServer/MCPServerLog.swift`** — `os.Logger`, subsystem
   `net.scosman.biscotti`, category `MCP`.

5. **`Sources/MCPServer/HTTPListener.swift`** — `actor HTTPListener`:
   single-thread `MultiThreadedEventLoopGroup`; `ServerBootstrap` with
   `configureHTTPServerPipeline(withErrorHandling: true)` + a
   `ConnectionLimiter` inbound handler (`NIOLockedValueBox<Int>`; over-cap
   connections close immediately) + the channel handler.
   `start(host:port:)` returns the **bound port** (tests bind 0);
   bind errors map `EADDRINUSE` → `.portInUse`, else `.bindFailed(message)`.
   `shutdown()` closes the server channel then awaits
   `group.shutdownGracefully()` so the port is provably released.

   **Constraint found while building (replaces the §4.1 aggregator/IDLE
   handler sketch):** swift-nio marks the `Sendable` conformances of both
   `NIOHTTPServerRequestAggregator` and `IdleStateHandler`
   `@available(*, unavailable)`, so neither can be installed from Swift 6
   strict-concurrency code (the package builds `-warnings-as-errors`).
   Their jobs moved into `HTTPChannelHandler`: it aggregates request parts
   itself, answers oversized bodies with `413` + close, and evicts idle
   connections with a `Task.sleep`-based timer — the same shape as the SDK's
   own conformance-server adapter, which is why it doesn't use those NIO
   handlers either. One more NIO gap discovered by tests: the pipeline does
   **not** honor `Connection: close`, so the handler closes the channel
   itself after responding to a close-headed request.

6. **`Sources/MCPServer/HTTPChannelHandler.swift`** — `ChannelInboundHandler`
   over `NIOHTTPServerRequestFull`: 404 (plain JSON) when the URI path ≠
   `/mcp` (query ignored); builds `MCP.HTTPRequest` (duplicate headers joined
   per RFC 7230, as the SDK's conformance app does); hops the await off the
   event loop in a `Task` and writes back via `context.eventLoop.execute`;
   maps `HTTPResponse` → head+body+`.end` always with `Content-Length`
   (keep-alive left to NIO's pipeline handler); `.stream` → logged 500
   (unreachable in stateless mode — never `fatalError`); idle events close
   quietly; `errorCaught` logs and closes the channel only.

7. **`Sources/MCPServer/MCPServerController.swift`** —
   `@MainActor @Observable` lifecycle per architecture §3.3, with one
   forced deviation (below): an internal `Task`-chained queue serializes
   `start/stop/applyEnabled`; all server/transport/listener objects are
   created in `start()` and released in `stop()`.
   **Bind-first order:** the listener binds *before* the transport is built so
   `OriginValidator.localhost(port:)` gets the **actual bound port**
   (8516 in production, ephemeral in tests). The SDK's `OriginValidator`
   421s any request whose `Host` header port mismatches, and `URLSession`
   always sends `Host` — a transport pinned to 8516 would reject every request
   on an ephemeral test port (architecture §11 flags exactly this Host/421
   interplay). The handler closure routes through a
   `NIOLockedValueBox<StatelessHTTPServerTransport?>` (503 before the
   transport is installed); `server.start(transport:)` failure tears the
   listener down. Everything else follows §3.3: empty `ListTools` handler for
   now (Phase 2 swaps in the catalog), capabilities
   `.init(tools: .init(listChanged: false))`, version from
   `CFBundleShortVersionString ?? "0.0.0"`.
   Tests bind an ephemeral port via an internal `start(port:)`
   (public `start()` keeps the §3.3 signature; default
   `MCPServerConfiguration.port`).

## Tests

- `HTTPSurfaceTests` — against a running controller (ephemeral port):
  `GET /mcp` → 405 + `Allow: POST`; `POST /other` → 404; body > 1 MB → 413;
  malformed JSON body → 400; JSON-RPC notification POST → 202 empty;
  `Origin: http://evil.example` → 403; absent `Origin` allowed;
  automatic `Host: 127.0.0.1:<port>` allowed. Header-control cases use a
  small POSIX-socket raw-HTTP client helper (full control of exact bytes);
  happy paths use `URLSession`.
- `MCPRoundTripTests` — `initialize` (serverInfo.name "Biscotti",
  tools capability present, protocol version echoed) then `tools/list`
  → empty `tools` array, over `URLSession` on the ephemeral port. Also
  `tools/list` *without* prior `initialize` — the SDK serves it (stateless
  has no session gate), which pins that behavior deliberately.
- `MCPServerControllerTests` — lifecycle: `start()` twice no-op;
  `stop()` twice no-op; start→stop→start rebinds the **same** port (second
  start passes the first bound port explicitly — proves shutdown released it);
  port-in-use → `.failed(.portInUse)`; `applyEnabled(false)` from `.running`
  reaches `.stopped`; rapid on/off/on serializes to a consistent state
  (whichever order the concurrent calls enqueue in, the final state is
  `.running` serving requests or `.stopped` — `async let` does not guarantee
  enqueue order, so "final wins" is asserted as this invariant).

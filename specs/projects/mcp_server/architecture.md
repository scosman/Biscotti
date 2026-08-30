---
status: complete
---

# Architecture: MCP Server

Implements `functional_spec.md`. Everything below is decided — the coding agent
executes, it does not design.

## 1. Shape of the change

One new BiscottiKit module, one new SwiftData settings field, one new DataStore
read method, one AppCore-owned service, one Settings row, one manual test script.

```
Packages/BiscottiKit/Sources/MCPServer/     ← new module (the whole server)
Packages/BiscottiKit/Sources/DataStore/     ← + mcpServerEnabled, + meetingPeople(id:)
Packages/BiscottiKit/Sources/AppCore/       ← owns MCPServerController, starts/stops it
Packages/BiscottiKit/Sources/SettingsUI/    ← the General row + How-to-connect sheet
Packages/BiscottiKit/Sources/ManualTestKit/ ← one script, one recordable step
App/project.yml                             ← no new app-target product (AppCore re-exports)
```

**Dependency direction:** `MCPServer → DataStore` only. Nothing in the module
knows about UI, AppCore, recording, or the LLM. `AppCore → MCPServer` is the
single inbound edge, and it exists for the same reason `AppCore → Recording`
does: AppCore is where services are composed and where the UI reads them.

## 2. Dependencies

| Package | Version | Used by | Why |
|---|---|---|---|
| `modelcontextprotocol/swift-sdk` (`MCP`) | see §2.1 | MCPServer | Protocol, JSON-RPC, `Server`, stateless HTTP transport, request validators |
| `apple/swift-nio` (`NIOCore`, `NIOPosix`, `NIOHTTP1`) | from 2.65.0 | MCPServer | The HTTP listener the SDK deliberately does not ship |

Both are added to `Packages/BiscottiKit/Package.swift`. The `MCPServer` target
is the only one that links them; `AppCore` links `MCPServer`.

### 2.1 SDK version — decide by spike, in this order

1. **Try `0.12.1`** (latest). Its manifest declares
   `swift-docc-plugin` at `branch: "main"`, which can trip SwiftPM's
   *"required using a stable-version but depends on an unstable-version
   package"* resolution error for downstream consumers.
2. **If resolution fails, pin `0.11.0`.** Its manifest has no branch
   dependency. It is otherwise equivalent for our purposes: same protocol set
   (`2025-11-25`, `2025-06-18`, `2025-03-26`), same
   `StatelessHTTPServerTransport`, same `OriginValidator.localhost(port:)`,
   same `structuredContent`/`outputSchema` support.

Pin an exact version (`.exact(...)`), not a range — this is a protocol
implementation and we want deliberate upgrades. Record which version won, and
why, in a comment next to the dependency.

### 2.2 Why not a hand-rolled listener

`NWListener` avoids the NIO dependency but means owning HTTP/1.1 framing:
`Content-Length` vs chunked bodies, keep-alive, pipelining, header limits,
partial reads. NIO's `configureHTTPServerPipeline()` plus
`NIOHTTPServerRequestAggregator` gives all of that, correct, in ~15 lines, and
the SDK's own conformance server (`Sources/MCPConformance/Server/HTTPApp.swift`)
is a working reference for exactly this adapter.

## 3. Module layout

```
Sources/MCPServer/
  MCPServerController.swift     @MainActor @Observable lifecycle + UI-facing state
  MCPServerState.swift          state enum + start-failure enum
  MCPServerConfiguration.swift  host/port/path/limits constants
  HTTPListener.swift            NIO bootstrap: bind, serve, shutdown
  HTTPChannelHandler.swift      NIOHTTP1 ⇄ MCP.HTTPRequest/HTTPResponse bridge
  MeetingToolProvider.swift     the three tools over DataStore (the real logic)
  ToolArgumentDecoding.swift    centralized argument decoding (invalidParams messages)
  MeetingToolCatalog.swift      Tool definitions: names, descriptions, JSON schemas
  MeetingToolPayloads.swift     Codable response DTOs
  TranscriptTextFormatter.swift segments → "[MM:SS] Name\ntext"
  ToolDateFormatting.swift      ISO-8601 parse/format helpers
  MCPServerLog.swift            os.Logger, category "MCP"
```

### 3.1 `MCPServerConfiguration`

```swift
public enum MCPServerConfiguration {
    public static let host = "127.0.0.1"
    public static let port = 8516
    public static let path = "/mcp"
    public static let endpointURL = URL(string: "http://127.0.0.1:8516/mcp")!
    static let maxBodyBytes = 1_048_576          // 1 MB
    static let maxConcurrentConnections = 16
    static let idleTimeoutSeconds: Int64 = 120
    static let searchCandidatePool = 500         // see §6.1
    static let maxResultLimit = 50
}
```

### 3.2 `MCPServerState`

```swift
public enum MCPServerState: Sendable, Equatable {
    case stopped
    case starting
    case running(URL)
    case failed(MCPServerStartError)
}

public enum MCPServerStartError: Sendable, Equatable {
    case portInUse(port: Int)
    case bindFailed(String)      // any other bind/listener failure, message for display
}
```

`MCPServerStartError` carries a `userMessage: String` computed property holding
the exact strings from functional spec §2.3, so SettingsUI renders and never
composes them.

### 3.3 `MCPServerController`

```swift
@MainActor @Observable
public final class MCPServerController {
    public private(set) var state: MCPServerState = .stopped
    public init(store: DataStore)
    public func start() async        // idempotent; no-op when running/starting
    public func stop() async         // idempotent
    public func applyEnabled(_ enabled: Bool) async   // start or stop to match
}
```

- Owns: the `MCP.Server`, the `StatelessHTTPServerTransport`, the
  `HTTPListener`. **All three are created inside `start()` and released in
  `stop()`** — this is what "zero overhead when off" means concretely: a
  stopped controller holds one enum and a `DataStore` reference, no event loop
  group, no sockets, no tool objects.
- `start()`/`stop()`/`applyEnabled()` are serialized by an internal
  `Task`-chained queue (`private var work: Task<Void, Never>?`, each call
  awaits the previous) so a rapid on/off/on sequence cannot leave an orphan
  listener. Final state wins.
- `@MainActor` because its only observer is SwiftUI. All blocking work inside
  `start()`/`stop()` is `await`ed on other executors (NIO's ELG, the
  `DataStore` actor); nothing blocks the main thread.

Start sequence:

1. `state = .starting`
2. Build `MeetingToolProvider(store:)`.
3. Build `MCP.Server(name: "Biscotti", version: <CFBundleShortVersionString ?? "0.0.0">, instructions: <one-paragraph orientation>, capabilities: .init(tools: .init(listChanged: false)))`.
4. `await server.withMethodHandler(ListTools.self) { … }` → `MeetingToolCatalog.all`
   `await server.withMethodHandler(CallTool.self) { … }` → `provider.call(name:arguments:)`
5. Build the transport with an explicit pipeline (do not rely on the default,
   so the port is pinned):
   ```swift
   StatelessHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
       OriginValidator.localhost(port: MCPServerConfiguration.port),
       AcceptHeaderValidator(mode: .jsonOnly),
       ContentTypeValidator(),
       ProtocolVersionValidator(),
   ]))
   ```
6. `try await server.start(transport: transport)`
7. `try await listener.start(port:)` — on success `state = .running(endpointURL)`;
   on failure tear down server + transport and `state = .failed(…)`.

Stop sequence: `await listener.shutdown()` → `await server.stop()` →
`await transport.disconnect()` → release all three → `state = .stopped`.

## 4. HTTP listener

### 4.1 `HTTPListener`

```swift
actor HTTPListener {
    init(handle: @Sendable @escaping (HTTPRequest) async -> HTTPResponse)
    func start(host: String, port: Int) async throws -> Int   // returns the bound port
    func shutdown() async
}
```

- Creates `MultiThreadedEventLoopGroup(numberOfThreads: 1)`. One thread is
  ample for a single local client and keeps the idle footprint small.
- Bootstrap:
  ```swift
  ServerBootstrap(group: group)
      .serverChannelOption(.backlog, value: 16)
      .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
          channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
              channel.pipeline.addHandlers([
                  ByteToMessageHandler(...)  // supplied by configureHTTPServerPipeline
                  NIOHTTPServerRequestAggregator(maxContentLength: maxBodyBytes),
                  IdleStateHandler(allTimeout: .seconds(idleTimeoutSeconds)),
                  HTTPChannelHandler(...)
              ])
          }
      }
      .bind(host: host, port: port)
  ```
  (`NIOHTTPServerRequestAggregator` yields whole requests and answers oversized
  bodies with `413` itself — that is why the 1 MB cap needs no custom code.)
- Returning the bound port lets tests bind `port: 0` and discover the ephemeral
  port.
- **Connection cap:** a `NIOLockedValueBox<Int>` shared by child channels;
  `channelActive` increments and closes immediately past
  `maxConcurrentConnections`, `channelInactive` decrements.
- `shutdown()` closes the server channel, then `try? await
  group.shutdownGracefully()`. Both are awaited so `stop()` cannot return while
  the port is still held (otherwise a fast off→on cycle self-inflicts
  `EADDRINUSE`).
- **Bind error mapping:** catch `IOError` / `NIOPosixError`; `errnoCode ==
  EADDRINUSE` → `.portInUse(port:)`, anything else → `.bindFailed(message)`.

### 4.2 `HTTPChannelHandler`

`ChannelInboundHandler` over `NIOHTTPServerRequestFull`:

1. Reject by path first: `uri` path component ≠ `/mcp` → `404`, plain JSON body,
   `connection: keep-alive` preserved. (Query strings are ignored, not rejected.)
2. Build `MCP.HTTPRequest(method:headers:body:path:)` from the head + aggregated
   body. Header names are copied verbatim; the SDK does case-insensitive lookup.
3. `let response = await handle(request)` — hop out of the event loop with a
   `Task`, then write back **on the channel's event loop** via
   `context.eventLoop.execute`.
4. Map `HTTPResponse` → `HTTPResponseHead` + body:
   - `.data(d, headers)` → 200 + `d`
   - `.accepted` → 202, empty
   - `.ok` → 200, empty
   - `.error(code, …)` → `code` + `bodyData`
   - `.stream` → **unreachable** in stateless mode; if ever hit, respond `500`
     and log. Never left as a `fatalError`.
   Always set `Content-Length` and honour keep-alive.
5. `IdleStateHandler` events close the connection quietly.
6. `errorCaught` logs and closes; a broken client must never take the app down.

## 5. MCP tool surface

### 5.1 `MeetingToolCatalog`

Static `[Tool]` with the names, descriptions (verbatim from functional spec §5),
`inputSchema`, and `outputSchema` as `MCP.Value` literals. Descriptions live
here and nowhere else. Input schemas mirror the parameter tables exactly,
including `"minimum": 1, "maximum": 50` on `limit`.

### 5.2 `MeetingToolProvider`

```swift
actor MeetingToolProvider {
    init(store: DataStore)
    func call(name: String, arguments: [String: Value]?) async throws -> CallTool.Result
}
```

- Unknown tool name → `throw MCPError.methodNotFound(name)`.
- Argument decoding is centralized: small helpers (`requiredUUID`,
  `optionalString`, `optionalDate`, `optionalInt(range:)`) that throw
  `MCPError.invalidParams(message)` with a message naming the offending field.
- Domain failures (unknown id, no transcript) return
  `CallTool.Result(content: [.text(message)], isError: true)` — a tool error,
  not a protocol error, per functional spec §5.
- Success returns `try CallTool.Result(content: [.text(json)],
  structuredContent: payload)` where `payload` is the `Codable` DTO and `json`
  is that same DTO encoded with sorted keys — one source of truth, two
  encodings, as the 2025-11-25 spec expects.

### 5.3 Response DTOs

`MeetingToolPayloads.swift` holds `Codable` structs mirroring functional spec
§5 exactly: `QueryMeetingsPayload`, `MeetingResultItem`, `MeetingDetailPayload`
(+ `CalendarPayload`, `PersonPayload`, `AudioFilesPayload`, `TranscriptStatsPayload`,
`SpeakerPayload`), `TranscriptPayload`. Snake_case keys via explicit
`CodingKeys` — never a global encoder strategy, so a field rename cannot
silently change the wire contract. Optional fields use
`encodeIfPresent` semantics (omit, don't emit `null`).

## 6. Algorithms

### 6.1 `biscotti_query_meetings`

```
validate: at least one of query/before/after present, else invalidParams
          limit ∈ 1...50, default 50
          before/after parse as ISO-8601 (full or date-only), after ≤ before

if query != nil:
    hits = try await store.searchHits(query, limit: searchCandidatePool)   // 500
    filtered = hits.filter { date range }
    results = filtered.prefix(limit).map { id, title, date, query_snippet: hit.snippet }
    // order: as returned by FTS (bm25 rank, then date desc, then UUID)
else:
    summaries = try await store.meetingSummaries(limit: nil)               // already date-desc
    filtered = summaries.filter { date range }
    results = filtered.prefix(limit).map { id, title, date }

results_truncated = (results.count == limit)
```

Date comparison uses the meeting's effective date (`SearchHit.date` /
`MeetingSummary.date`), inclusive on both bounds.

`searchHits` already calls `syncSearchIndex()` internally, so an index rebuild
in progress is handled exactly as it is for in-app search — no extra work here.

### 6.2 `biscotti_get_meeting`

```
detail = try await store.meetingDetail(id: id)      → nil ⇒ tool error
audio  = try await store.storedAudioFileRefs(meetingID: id)  → paths reported
                                                    regardless of presence
                                                    (functional spec §5.2);
                                                    only `present` reflects
                                                    the disk
people = try await store.meetingPeople(id: id)      → new, §7.2

transcript stats from detail.preferredTranscript:
    segment_count   = segments.count
    character_count = Σ segment.text.count
    word_count      = Σ segment.text.split(whitespace, omittingEmptySubsequences).count
    speaker_count   = transcript.speakerCount
    speakers        = distinct speakerID/label pairs in segment order,
                      name from transcript.speakerAssignments
transcript_version_count = detail.versions.count
```

`calendar` is emitted only when `detail.calendar != nil`; each of its fields is
omitted when nil. `audio_files.present` comes straight from
`StoredAudioFileRefs.present`; deleted files keep their stored paths.

### 6.3 `biscotti_get_transcript`

`meetingDetail(id:)` → `preferredTranscript` (nil ⇒ tool error "no transcript
yet") → `TranscriptTextFormatter.text(segments:names:)`, plus the same word and
character counts as §6.2 (computed on the *segments*, so they agree with
`get_meeting` exactly).

### 6.4 `TranscriptTextFormatter`

Pure, no imports beyond `DataStore` + `Foundation`:

```
for each segment:
    name = names[speakerID] ?? segment.speakerLabel
    if speakerID != nil && speakerID == previous speakerID:
        append " " + trimmed text to the current turn
    else:
        flush current turn; start a new turn at segment.startTime
turn rendering: "[\(timestamp)] \(name)\n\(text)"
joined by "\n\n"
timestamp: MM:SS, or HH:MM:SS once startTime ≥ 3600
```

This deliberately does **not** reuse `Intelligence.TranscriptFormatter` (whose
output is untimestamped and whose module drags in `LocalLLM`) nor
`MeetingDetailUI.TranscriptContent` (SwiftUI). ~40 lines of pure code beats
either coupling.

## 7. DataStore changes

### 7.1 `mcpServerEnabled`

- `AppSettings`: `public var mcpServerEnabled: Bool = false`
- `AppSettingsData`: matching `public var mcpServerEnabled: Bool` (default
  `false`) — added to the memberwise init as a defaulted parameter, and to the
  read/write mapping in `settings()` / `updateSettings`.
- Additive property with a default on a `@Model`: no schema version bump, no
  migration, consistent with `recordingDuration` and `calendarVocabularyEnabled`.

### 7.2 `meetingPeople(id:)`

`MeetingSummary.participants` is capped at 5 for display, so it cannot serve the
tool. New read model + accessor in `DataStore+ReadModels.swift`:

```swift
public struct MeetingPeople: Sendable, Equatable {
    public let organizer: PersonData?
    public let participants: [PersonData]   // uncapped, organizer excluded, deduped by id
}

func meetingPeople(id: UUID) throws -> MeetingPeople?   // nil when the meeting is gone
```

### 7.3 Notification

`AppCore`'s `Notification.Name` extension gains:

```swift
static let mcpServerEnabledDidChange = Notification.Name(
    "net.scosman.biscotti.mcpServerEnabledDidChange")
```

Same file and pattern as the six existing ones.

## 8. Wiring

### 8.1 AppCore

- New stored property `public let mcpServer: MCPServerController`, constructed
  in `init` from `store` (an optional injection parameter defaulting to `nil`,
  so no existing call site or `BiscottiTestSupport` fake changes).
- `onLaunch()` — inside `startBackgroundServices()`, after the existing
  services: `if settings.mcpServerEnabled { await mcpServer.start() }`. Nothing
  runs when the flag is off.
- `startNotificationSettingsObservers()` gains a fourth task observing
  `.mcpServerEnabledDidChange` → re-read settings → `await
  mcpServer.applyEnabled(settings.mcpServerEnabled)`.
- Onboarding path (`onLaunch` returns early) never starts the server — correct:
  a user who has not finished onboarding has nothing to serve.

### 8.2 SettingsUI

- `SettingsViewModel`: `public private(set) var mcpServerEnabled = false`
  (loaded in `load()`), plus
  `func setMCPServerEnabled(_:) async` following the exact
  `setStopRecordingAutomatically` shape — optimistic update, persist, post
  `.mcpServerEnabledDidChange`, revert on throw.
- `SettingsView.generalSection`: a new final row, `Toggle("MCP")` +
  caption `VStack`, matching the "Keep app running in tray" pattern. The
  caption switches on `viewModel.core.mcpServer.state`:
  - `.stopped` → the subtitle
  - `.starting` → "Starting…"
  - `.running(url)` → subtitle + endpoint line with a Copy button
    (`NSPasteboard`, transient "Copied" like the transcript Copy button)
    and a "How to connect" link
  - `.failed(err)` → `err.userMessage` in `Tokens` error styling + "Retry"
    (`await core.mcpServer.start()`)
- `MCPHelpSheet.swift` (new, alongside `AlertsHelpSheet.swift`): the endpoint,
  the paste-ready JSON snippet, the one-sentence exposure warning.
- SettingsUI reads state from `AppCore`, so it needs **no** new package
  dependency (AppCore already re-exports what it owns).

### 8.3 App target

No change. `App/project.yml` already depends on `AppCore`; the MCPServer
product ships transitively.

## 9. Errors and logging

| Failure | Handling |
|---|---|
| Bind fails | `.failed(...)`, surfaced in Settings, Retry available. Never retried automatically, never crashes. |
| `DataStore` throws inside a tool | Caught at `MeetingToolProvider.call`; returned as a tool error result with a generic message. The underlying error is logged, never returned (paths/queries could leak). |
| Malformed JSON-RPC | Handled inside the SDK transport → 400. |
| Handler panic-ish error in NIO | `errorCaught` logs + closes the channel only. |
| `stop()` while a request is in flight | Graceful shutdown closes the channel; the client sees a dropped connection. Acceptable. |

Logging: `Logger(subsystem: "net.scosman.biscotti", category: "MCP")`.
`info` for start/stop/bind-failure; `debug` for tool name + argument *shape*
(which optional params were present, the limit, result count). **Never** log
query text, titles, snippets, transcript text, or file paths.

## 10. Testing

New test target `MCPServerTests` (+ additions to `DataStoreTests`,
`SettingsUITests`, `AppCoreTests`).

**Tool logic** (in-memory `DataStore`, no sockets):
- `query_meetings`: no-filter error; `limit` alone is an error; query-only
  relevance order; date-only newest-first; `after`/`before` inclusive bounds;
  `after > before` invalid params; unparseable date invalid params; date-only
  string accepted; `limit` clamped/rejected outside 1…50; `results_truncated`
  true at exactly `limit` and false below; `query_snippet` present only with a
  query; empty result set is not an error.
- `get_meeting`: full payload for a rich meeting (calendar + tags + people +
  transcript); missing-calendar and missing-transcript variants; unknown id →
  `isError` result; `audio_files.present` false when files are gone; stats math
  (segment/word/character/speaker counts) on a known fixture.
- `get_transcript`: turn collapsing across consecutive same-speaker segments;
  mapped vs unmapped speaker names; `MM:SS` and `HH:MM:SS` boundary at 3600 s;
  empty-segment transcript → empty text, zero counts; unknown id and
  no-transcript tool errors.
- Payload encoding: golden-JSON assertions on key shape (snake_case, omitted
  optionals) so the wire contract can't drift silently.

**Transport / HTTP** (real listener on `127.0.0.1:0`, driven with `URLSession`):
- `initialize` → `tools/list` → `tools/call` round trip; the three tools appear
  with non-empty descriptions and schemas.
- `Origin: http://evil.example` → 403; absent `Origin` → allowed; `Host:
  127.0.0.1:<port>` → allowed.
- `GET /mcp` → 405 + `Allow: POST`; `POST /other` → 404; body > 1 MB → 413;
  malformed JSON → 400.
- Notification-only POST → 202.

**Lifecycle**:
- `start()` twice is a no-op; `stop()` twice is a no-op; start→stop→start
  rebinds the same port (proves shutdown actually releases it).
- Bind conflict: hold the port, `start()`, assert `.failed(.portInUse)`.
- `applyEnabled(false)` from `.running` reaches `.stopped`.

**Wiring**:
- `AppCoreTests`: server does not start when the setting is off; starts when on;
  the notification observer flips it live.
- `SettingsUITests`: toggle persists + posts the notification; failure state
  renders the message and Retry.
- `DataStoreTests`: `mcpServerEnabled` round-trips; `meetingPeople` dedupes,
  excludes the organizer from participants, returns nil for an unknown id.

**Manual test** — new `MCPScript` in `ManualTestKit/Scripts`, registered in
`allScripts`, with one `.instruction` step (run the real app, enable MCP,
connect a real MCP client with the config snippet, call all three tools) and
**one recordable `.humanQuestion` step** (`mcp_real_client`) so
`make manual-tests-check` tracks it. Per the repo's staleness rule, later
changes to this module set `mcp_real_client` back to `not-run`.

## 11. Risks

| Risk | Mitigation |
|---|---|
| SDK 0.12.1 resolution failure (docc branch dep) | Spike first; fall back to 0.11.0 (§2.1) |
| SDK is pre-1.0; API churn between versions | Exact version pin; all SDK contact confined to `MCPServerController` + `MeetingToolProvider` |
| NIO adds build time to every AppCore-dependent test target | One-time cold cost; measured in the spike phase. If unacceptable, the fallback is moving `MCPServerController` ownership from AppCore to the app target and passing state to SettingsUI explicitly. |
| A client that insists on the GET SSE stream | 405 is spec-legal; verified in the manual test against a real client. If a major client turns out to require it, `StatefulHTTPServerTransport` is a contained swap inside `start()`. |
| `Host` header without a port → 421 from `OriginValidator` | Documented; the help sheet's snippet always includes the port |

## 12. Single doc, no component designs

This is ~10 small files behind one controller with no cross-component
negotiation. Splitting it into `components/` would add navigation cost without
adding clarity, so everything stays in this document.

---
status: complete
---

# Functional Spec: Graduate LLM Package

## Purpose & Scope

Graduate the local-LLM inference experiment (`experiments/llm`) into a first-class, shippable
Swift package at `Packages/LocalLLM`, and **replace its experiment-only transport with the
repo's real production isolation pattern**: a true macOS XPC service, `BiscottiLLM.xpc`,
mirroring `XPCServices/BiscottiTranscriber.xpc`. The new XPC path is validated on hardware by a
LocalLLM tab in the ManualTestApp — i.e. the harness exercises the same path the app will ship.

This is a **graduation + transport-replacement + hardening + relocation** project. The local
inference *runtime* already exists and is hardware-validated; we are (1) reviewing/hardening it
to a high bar, (2) moving it to `Packages/LocalLLM`, (3) **deleting the bespoke pipe transport
and building a real NSXPC service** behind the unchanged `LLMService`/`LLMConnection` API,
(4) wiring everything into the canonical build/test/lint/CI surface, (5) adding a LocalLLM
ManualTestApp tab that drives the XPC service, and (6) verifying it all (autonomous + human).

### Why the transport changes

The experiment's "out-of-process" mode was a **spawned child process + framed-JSON over pipes**
(`RemoteBackend` → `localllm-service`), chosen deliberately so it ran under `swift run`/`swift
test` with no app bundle; real `NSXPCConnection` was explicitly deferred to Project 10. But the
repo's actual production isolation for its other heavy ML worker is a true `xpc-service`
(`BiscottiTranscriber.xpc`). A manual-test harness exists to validate the **production** path on
hardware, so the LLM must use the same `NSXPC` mechanism. We pull that swap forward now.

### In scope

- Quality review + hardening of the `LocalLLM` library and CLI (punch-list below).
- Relocation via `git mv experiments/llm Packages/LocalLLM` (experiment dir removed).
- **Delete the pipe transport**: `RemoteBackend` (Process/pipes/stdout rescue-and-gag),
  `ServiceLoop`, `Sources/Service/main.swift` + the `llm-service` target / `localllm-service`
  product, `FrameCodec`, the framed `ServiceRequest`/`ServiceEvent` enums, `--fake` mode +
  `__CRASH__`/`__SLEEP__`, `TestServiceBinary`, `TransportTests`, `LOCALLLM_SERVICE_PATH`.
- **Build the real NSXPC service** `XPCServices/BiscottiLLM/` (host `main.swift` mirroring
  BiscottiTranscriber: `NSXPCListener.service()`, connection-count → `_exit(0)` reclamation,
  ordered Metal teardown), plus, in the `LocalLLM` library, the `@objc` protocols, request/result
  DTO marshaling (JSON `Data` over the boundary), the client adapter, and a `.hosted(serviceName:)`
  backend behind the existing `LLMService`/`LLMConnection` API.
- Wire `Packages/LocalLLM` into Makefile/`hooks_mcp.yaml`/CI; align AI tests to
  `BISCOTTI_RUN_AI_TESTS=1` via `make test-ai`.
- A LocalLLM ManualTestApp tab (`llm_*` steps) that drives `BiscottiLLM.xpc` for in-app
  inference and is wired into the `manual-tests-check` gate; plus the `CLAUDE.md` staleness rule.
- Docs: production README; fold/remove experiment-era `NOTES.md`/`VALIDATION.md`; update
  `CLAUDE.md`, `architecture.md`, `implementation_plan.md`.
- Verification: autonomous unit suite green via `make test`/`ci`; human-in-the-loop run of the
  CLI, `make test-ai`, and the new ManualTestApp tab (which exercises the XPC service) on real
  Apple-silicon hardware.

### Out of scope (explicitly)

- **Project 10 (Intelligence) product features.** No provider abstraction, no external
  OpenAI-compatible provider, no summary/action-item/speaker-name/vocab *features* as product
  surface, no `Intelligence` package.
- **Real-app integration.** The shipping `App/` target does not consume `LocalLLM` or embed
  `BiscottiLLM.xpc` yet (that's Project 10). Only **ManualTestApp** embeds it here.
- **`swift-jinja` / multi-model templating; custom vocabulary.** Deferred.
- **Concurrency/pooling.** One in-flight generation per connection, one service per connection,
  as today.

### Consequences of the NSXPC pivot (confirmed)

- **CLI + autonomous tests are in-process-only.** NSXPC needs an app bundle, so it can't run
  under `swift run`/`swift test`. The CLI (`localllm run`) runs `.inProcess` (keeps the `_exit`
  Metal-teardown workaround). Autonomous tests cover `.inProcess` + `MockEngine`. The **XPC path
  is validated only on hardware via the ManualTestApp tab** — exactly how the transcriber's
  `.hosted` path is validated (no autonomous NSXPC tests exist for it either). This supersedes
  the earlier "keep `--backend in-process` and reframe": the CLI's `--backend` flag is **removed**
  (only one mode remains).
- **Model download stays in-process** (client-side `ModelDownloader`; a plain URLSession fetch,
  no inference process needed). Only *generation* crosses XPC.
- **JSON stays, framing goes.** `@objc` XPC can't carry `Codable`/generics, so DTOs
  (`GenerationOptions`/`GenerationResult`/request) are JSON-encoded to `Data` across the
  boundary — the `Codable` conformances are retained and reused. What's deleted is the
  length-prefixed framing and the stdout rescue-and-gag (NSXPC doesn't multiplex over stdout;
  backend log noise goes to the service's `os_log`).

## Background: what the package is (post-pivot)

- A `LocalLLM` **library**: the public `LLMService`/`LLMConnection` API (scoped, leak-proof
  connections) with two backends — `.inProcess` (real `LLMEngine`, or `MockEngine` in tests)
  and `.hosted(serviceName:)` (NSXPC to `BiscottiLLM.xpc`); the actor inference engine over
  `llama.swift`/llama.cpp; buffered + streaming generation; channel-aware output parsing
  (`StreamingChannelSplitter`/`OutputParser`); the hand-rolled `GemmaChatTemplate`;
  `GenerationOptions`/`GenerationResult`/`LocalLLMError`/`EngineConfig` value types; a
  `ModelDownloader`; the `@objc` XPC protocols + client adapter + error DTO.
- A **CLI** (`localllm`): `download` and `run` (in-process) subcommands.
- A **macOS XPC service** (`XPCServices/BiscottiLLM/`, bundle id
  `net.scosman.biscotti.BiscottiLLM`): hosts the engine, vends `LLMServiceProtocol`, streams
  tokens back via an `LLMEventReporting` reverse proxy, and `_exit(0)`s on last-connection
  invalidation for full memory reclamation. Built as an Xcode `xpc-service` target depending on
  the `LocalLLM` package product; embedded into ManualTestApp (and, later, the app).

The model is Gemma 4 12B QAT (GGUF, ~8 GB), at `~/Library/Application Support/Biscotti/llms/`.

## XPC contract (functional level)

Two `@objc` protocols (detailed signatures in architecture):

- **`LLMServiceProtocol`** (client → service): `load` (model path + `EngineConfig` as `Data`,
  loads once), `generate` (buffered: replies with `GenerationResult` `Data`), `generateStreaming`
  (tokens via the reverse proxy, terminal reply), `cancel` (cancels the in-flight generation),
  `healthCheck`.
- **`LLMEventReporting`** (service → client, reverse proxy): `reportToken`,
  `reportReasoningToken`, `reportDone(resultData:)`, `reportError(errorData:)`. Used for the
  streaming path; mirrors the transcriber's `reportDownloadStatus`.

Serialization is strict (one in-flight generation per connection), so the wire carries no
request ids; the client detaches its event receiver at terminal/cancel so stale callbacks are
dropped. Errors cross as a small `Codable` payload (`Data`) mapped to/from `LocalLLMError` /
`LLMServiceError`.

Lifecycle (preserves the existing `LLMService.withConnection` semantics):
`openConnection(.hosted)` → NSXPC connect + `load` + await ready; `generate`/`generateStreaming`
→ XPC calls + reverse-proxy events; `close()` → `connection.invalidate()` → service
connection-count hits 0 → `_exit(0)` → OS reclaims 100% of the model's memory.

## Quality bar & hardening punch-list

Bar: indistinguishable from code authored as production. Passes `swiftlint --strict` +
`swiftformat --lint` (auto-applied under `Packages/`), builds `-warnings-as-errors`, no
experiment framing, clean public surface, no dead code or test-only types in the library.

### Must fix (blocking)

- **Manifest (`Package.swift`)** — match Transcription: `warningsAsErrors` `SwiftSetting` on
  every target; `swiftLanguageModes: [.v6]`; test `resources: [.copy("Fixtures"), .copy("Prompts")]`;
  drop the experiment-era clause in the case-collision comment; remove the now-deleted
  `llm-service`/`localllm-service` target+product; match trailing-comma style. Remaining targets:
  `LocalLLM` library + `llm-cli` (product `localllm`) + `LocalLLMTests`.
- **Pipe-transport deletion** (see In-scope list) — remove the code and its tests cleanly; the
  always-on suite stays green minus the deleted transport/sampling/template tests.
- **Public surface** — move `MockEngine` to the test target; delete `SamplingFallback` (dead);
  delete `BuiltinChatTemplate` + `useBuiltinTemplate` + `--template builtin` (ratified: renders
  known-broken Gemma 4 output); tighten remaining library internals to `internal`/`package`
  except what the XPC service target and tests must see across the module boundary.
- **Experiment framing & paths** — strip "experiment/Phase N/Project 10" wording and fix
  `experiments/llm` path strings in source comments/docs.
- **Lint cleanliness** — fix >120-char lines, force-unwraps (or justified inline disables), the
  `_exit` Metal-teardown TODO wording (CLI keeps `_exit` for in-process; reword as
  "blocked upstream"). Note the service host also does ordered teardown + `_exit(0)`.
- **Docs** — production `README.md`; fold durable findings from `NOTES.md`/`VALIDATION.md`
  (speed numbers, template/sampler decisions, Metal-teardown note, chat-template rationale)
  into it; remove both experiment files.
- **Hygiene** — no build artifacts/`.build*` follow the move.

### Ratified decisions (already confirmed)

1. Remove the builtin-template A/B path. ✔
2. ~~Keep `--backend in-process`~~ → **superseded**: remove the CLI `--backend` flag entirely
   (CLI is in-process only post-pivot). The library's `.inProcess` backend stays.
3. `GenerationResult` debug fields: keep (back `--show-raw`), drop the "Debug fields" framing. ✔
4. `_exit` Metal-teardown: keep at both sites (CLI in-process; XPC host); reword the CLI TODO. ✔

## Build / test / CI integration

- **`Makefile`**: add `Packages/LocalLLM` to `PACKAGES` (joins `build`/`test`/`ci`/
  `precommit-checks`/`clean`; lint covers it via the `Packages` glob). Extend `test-ai` with
  `BISCOTTI_RUN_AI_TESTS=1 swift test --package-path Packages/LocalLLM`.
- **AI-test env var**: rename `LLM_RUN_AI` → `BISCOTTI_RUN_AI_TESTS`; keep optional
  `LLM_MODEL_PATH` override. AI tests run `.inProcess` (load/determinism/streaming-parity);
  skip cleanly when the flag is unset or the model is absent.
- **`hooks_mcp.yaml`**: repoint `build_llm`/`test_llm` to `Packages/LocalLLM`.
- **App-tier build**: `make build-app` runs `xcodebuild` on ManualTestApp, which now builds +
  embeds `BiscottiLLM.xpc`. Must stay green (non-gating tier).
- **`ci.yml`**: no change expected — `package-tier` runs `make ci`; the app/manual tiers cover
  the rest.

## ManualTestApp: LocalLLM tab (XPC-driven)

A `Local LLM` tab matching the AudioCapture/Transcription pattern, `llm_*`-prefixed, registered
via `allScripts`, enforced by `manual-tests-check`. **In-app inference goes through the real
`BiscottiLLM.xpc`** (`.hosted(serviceName: "net.scosman.biscotti.BiscottiLLM")`) — the whole
point. Model download is in-process (`ModelDownloader`).

Touch-points: new `LocalLLMScript.swift` in ManualTestKit; add `.localLLM` to `AllScripts`; add
the `LocalLLM` package + the `BiscottiLLM` xpc-service target (`embed: true`) to
`ManualTestApp/project.yml`; `wireLocalLLM(_:)` in `WiredScripts.swift`; `BiscottiLLM`
Info.plist + entitlements under `XPCServices/BiscottiLLM/`; `CLAUDE.md` staleness rule for
`llm_*`/`Packages/LocalLLM`.

Proposed recordable steps (`llm_*`):

| Step ID | Kind | Validates |
|---|---|---|
| `llm_model_download` | action | In-process `ModelDownloader` fetches the model (progress); succeeds/already present. |
| `llm_model_disk` | humanQuestion | Download showed progress and the model is on disk. |
| `llm_ai_tests_passed` | humanQuestion | `make test-ai` (in-process model suite) passed. |
| `llm_xpc_inference` | action | In-app generation **via `BiscottiLLM.xpc`** returns a sensible answer; tokens visible. |
| `llm_summarize_quality` | humanQuestion | Summarize prompt over the fixture is accurate, no hallucinations. |
| `llm_action_items_quality` | humanQuestion | Action items capture owners/deadlines. |
| `llm_speaker_names_quality` | humanQuestion | Speaker-name inference correct with supporting quotes. |
| `llm_thinking_mode` | humanQuestion | Thinking mode produces reasoning then a final answer. |
| `llm_streaming_channels` | humanQuestion | Streaming over XPC renders incrementally; thinking vs. response routed cleanly (no raw markers). |
| `llm_reclamation` | autoCheck (fallback humanQuestion) | After inference + connection close, no `BiscottiLLM` service process remains (reclaimed). |

(Backend A/B parity is dropped — only one in-app path, XPC, now exists. `.instruction` steps may
hold setup text; excluded from the gate.) Results are committed only after a human run.

## Edge cases & error handling

- **Model absent**: CLI `run` errors with the "run `localllm download`" hint (preserved). The
  tab's `llm_xpc_inference`/`llm_model_download` surface a clean failed-action message, not a
  crash, when the model is missing.
- **XPC worker crash / interruption**: the client's `interruptionHandler` marks the connection
  interrupted; the next call relaunches a fresh service (retriable), mirroring the transcriber's
  `workerInterrupted` model. In-flight generation surfaces a retriable `LLMServiceError`.
- **Reclamation**: closing the connection invalidates it; the service's connection count hits 0
  → `_exit(0)`; the `llm_reclamation` step confirms no orphaned `BiscottiLLM` process.
- **`make test-ai`**: gated suite skips cleanly when `BISCOTTI_RUN_AI_TESTS` is unset, and skips
  with a clear message (not a hard suite failure) if set but the model is missing.
- **No regressions**: the always-on unit suite stays green after the deletions and the API
  changes (deleted tests are expected reductions, not regressions).

## Verification / acceptance criteria

**Autonomous (agent + CI):**
1. `make build` builds `Packages/LocalLLM`.
2. `make test` (gating) green — LocalLLM's always-on suite (in-process + `MockEngine`) included.
3. `make lint --strict` clean over the package (only justified inline disables).
4. `make ci` green.
5. `make build-app` builds ManualTestApp **with `BiscottiLLM.xpc` embedded** (non-gating tier).
6. `build_llm`/`test_llm` succeed at the new path; zero `experiments/llm` references remain
   outside historical spec/process docs.

**Human-in-the-loop (real Apple-silicon hardware):**
7. `make test-ai` (model present) runs the in-process model suite green.
8. CLI works end-to-end from the new location: `download`, `run` (streaming + buffered),
   `--thinking auto/off`, `--show-raw`; clean exit (no GGML_ASSERT); no `--backend` flag.
9. The ManualTestApp `Local LLM` tab runs on hardware **through `BiscottiLLM.xpc`**: inference,
   streaming, thinking, the three quality judgments, and reclamation (no orphaned service). All
   recordable `llm_*` steps recorded and committed, turning `make manual-tests-check` green for
   the `llm_*` set.

## Documentation updates

- `architecture.md` (root): the local LLM runtime now exists as `Packages/LocalLLM`, **and its
  production transport — `BiscottiLLM.xpc` — is built ahead of Project 10**; the future
  `Intelligence` package will consume both. Keep the Intelligence/Project-10 plan otherwise.
- `CLAUDE.md`: add `Packages/LocalLLM` + `XPCServices/BiscottiLLM` to the repo map; extend the
  manual-test staleness rule with `llm_*`; note the new tab.
- `implementation_plan.md`: note the NSXPC transport is graduated ahead of Project 10.
- Package `README.md`: production rewrite (library API, CLI, the XPC service, build/test, model
  location, the preserved technical rationale).

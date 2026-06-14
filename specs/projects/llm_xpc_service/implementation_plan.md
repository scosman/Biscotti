---
status: complete
---

# Implementation Plan: LLM XPC Service Interface

Four phases, dependency-ordered. Each is one reviewable unit. Details live in
`functional_spec.md` and `architecture.md` (section refs below) — this is just the build
order. Verify each phase with `build_llm` + `test_llm` (out-of-sandbox).

## Phases

- [x] **Phase 1 — Wire protocol foundation** (arch §6)
  - `Codable` conformances on existing types: `GenerationOptions`, `EngineConfig`,
    `GenerationResult`, `FinishReason`, `ThinkingMode` (§6.3).
  - `ServiceRequest` / `ServiceEvent` Codable enums (§6.2); `WireError` + 1:1 mapping
    to/from `LocalLLMError` (`from(_:)` / `toClientError()`) (§6.4).
  - `FrameCodec`: 4-byte big-endian length prefix + JSON; read-exactly-N reassembly;
    oversize/garbage → `protocolError` (§6.1).
  - Tests: codec round-trips + partial/coalesced/oversize; Codable round-trips; WireError
    mapping both directions. No process spawning. (arch §13)

- [x] **Phase 2 — Connection + in-process backend** (arch §3, §4, §5, §11)
  - Seams: `ServiceBackend`; `InferenceEngine` (+ `LLMEngine` conformance) (§4).
  - `InProcessBackend` (wraps `InferenceEngine`); `MockEngine` (canned tokens/results,
    scriptable errors) for model-free tests.
  - `AsyncSemaphore(1)` serial gate (§5); `LLMServiceError` (§3); `LLMConnection` actor —
    state machine (§11), id counter, `generate` / `generateStreaming`, `close` (idempotent).
  - `LLMService.withConnection` (guaranteed close on return/throw/cancel) + `openConnection`
    (§3).
  - Tests (InProcess + MockEngine): open→ready; buffered generate; streaming relay; serial
    ordering of overlapping calls; reuse-after-close → `connectionClosed`; idempotent close;
    `withConnection` closes on success **and** throw; cancellation releases the gate;
    mock-error → correct `LocalLLMError`. (arch §13)

- [x] **Phase 3 — Out-of-process transport** (arch §2, §7, §8, §9)
  - `Package.swift`: add executable target `llm-service` (product `localllm-service`),
    depends on `LocalLLM` (§2).
  - `ServiceLoop` (in `LocalLLM`, unit-testable): rescue-and-gag stdout (§7.1/§8 step 0);
    load + `ready`/`loadError`; concurrent reader + single serial worker; `.cancel` cancels
    worker; `.shutdown`/stdin-EOF → ordered teardown → `_exit(0)` (§8). `llm-service/main.swift`
    = parse argv → `ServiceLoop.run()`.
  - `--fake` mode: instant `ready`, canned token frames; magic prompts `__CRASH__`
    (exit 1), `__SLEEP__` (cancellable) (§8).
  - `RemoteBackend`: binary resolution (explicit → env → sibling/xctest dir) (§7.1); `Process`
    spawn w/ pipes + verbosity-gated stderr; reader/writer (lock-guarded writes) (§7.2);
    close/kill sequence (shutdown→stdin-EOF→SIGTERM→SIGKILL) (§7.3); `nonisolated forceKill`
    deinit backstop (§7.4).
  - Tests (spawn real `--fake` child; resolve-or-skip per §2): open→ready; canned
    generate/stream; cancel mid-stream (`__SLEEP__`) frees the queue; `__CRASH__` →
    `serviceInterrupted` + `state==failed`; **close reclaims** (pid gone, `kill(pid,0)`→ESRCH);
    deinit backstop kills a dropped connection. (arch §13)

- [ ] **Phase 4 — CLI rework + AI tests + docs** (arch §12, §13)
  - `RunCommand` over `LLMService.withConnection`: `--backend out-of-process|in-process`
    (default out-of-process); `--verbose` gates child stderr; preserve all existing output
    (`--stream`, thinking/response sections, `--show-raw`, speed summary, sampling/`--thinking`/
    `--template`); remove the parent-side `_exit` teardown hack (§12). `DownloadCommand`
    unchanged.
  - AI tests (`LLM_RUN_AI=1`) rewritten over `LLMService` (out-of-process), **one shared
    connection** across the suite; re-cover stack-works / determinism / streaming-buffered
    parity; add reclamation assertion (pid gone after close); optional `.inProcess` parity.
  - Docs: update `experiments/llm/README.md` + `VALIDATION.md` for the service interface,
    `--backend`, and the new manual reclamation check.

## Notes

- **Build-before-test:** transport tests need `localllm-service` built; the `build_llm`-then-
  `test_llm` flow provides it, and tests resolve-or-skip otherwise (arch §2).
- **No `Makefile`/root-doc changes** — experiment is self-contained under `experiments/llm`;
  productionization into the `Intelligence` package is repo Project 10 (out of scope here).

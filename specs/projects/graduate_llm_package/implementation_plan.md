---
status: complete
---

# Implementation Plan: Graduate LLM Package

Ordered by dependency. Each phase references `functional_spec.md` + `architecture.md` for
detail. Phases 1–3 are agent-buildable and gated by `make ci`; Phase 4 is the human
hardware run (the agent cannot run it).

## Phases

- [x] **Phase 1 — Graduate, harden, strip the pipe transport.**
  `git mv experiments/llm Packages/LocalLLM`; bring `Package.swift` to house style
  (`-warnings-as-errors` on all targets, `swiftLanguageModes: [.v6]`, test resources; **remove
  the `llm-service` target + `localllm-service` product**). Delete the pipe transport and dead
  scaffolding (`RemoteBackend`, `ServiceLoop`, `Sources/Service/`, `FrameCodec`, the framed
  `ServiceRequest`/`ServiceEvent` enums, `--fake`/magic prompts, `TestServiceBinary`,
  `TransportTests`, `LOCALLLM_SERVICE_PATH`, `SamplingFallback` + tests, `BuiltinChatTemplate` +
  `useBuiltinTemplate`); move `MockEngine` → test target. Collapse `Backend` to `.inProcess`
  only; CLI in-process-only (remove `--backend` and `--template`). Rename
  `LLM_RUN_AI`→`BISCOTTI_RUN_AI_TESTS`; strip experiment framing/paths; lint `--strict` clean.
  Wire `Makefile` (`PACKAGES`, `test-ai`) + `hooks_mcp.yaml`; initial production `README`.
  *Gate:* `make build`/`test`/`lint`/`ci` green; CLI builds; always-on suite green (minus
  deleted tests).

- [x] **Phase 2 — NSXPC transport (library side).**
  Add the `@objc` `LLMServiceProtocol` + `LLMEventReporting`, the Codable DTOs
  (`LLMLoadRequest`/`LLMGenerateRequest`), rename `WireError`→`LLMErrorPayload`, the
  `XPCBackend: ServiceBackend` client adapter, `LLMEventReceiver`, and `LocalLLMPaths`. Restore
  `Backend.hosted(serviceName:)` behind the unchanged `LLMService`/`LLMConnection` API. Unit
  tests: DTO round-trips, `LLMErrorPayload` mapping (both directions), and event-receiver relay
  via a fake reporter up to the seam. *Gate:* `make build`/`test`/`lint` green. (NSXPC itself
  isn't autonomously testable — validated in Phase 4.)

- [x] **Phase 3 — XPC host + ManualTestApp tab + docs.**
  `XPCServices/BiscottiLLM/` (`main.swift` thin bridge over an in-process `LLMConnection`;
  `ConnectionCounter`→ordered teardown→`_exit(0)`; `Info.plist` `XPC!`/`ServiceType
  Application`; `BiscottiLLM.entitlements` app-sandbox=false). ManualTestApp `project.yml`
  (LocalLLM package + `BiscottiLLM` xpc-service target + `embed: true`). The `Local LLM` tab
  (`LocalLLMScript` in ManualTestKit, register in `AllScripts`, `wireLocalLLM` in
  `WiredScripts` driving `BiscottiLLM.xpc` for inference + in-process `ModelDownloader` for
  download; `llm_reclamation` autoCheck). Docs: root `architecture.md`/`implementation_plan.md`
  notes, `CLAUDE.md` repo-map + `llm_*` staleness rule, README finalize. *Gate:* `make
  build-app` builds ManualTestApp with `BiscottiLLM.xpc` embedded; `make ci` green;
  `manual-tests-check` reports `llm_*` not-run (expected).

- [x] **Phase 4 — Human hardware validation.** (Human-run; agent cannot.)
  `make test-ai` (in-process model suite) green; CLI end-to-end from the new location; the
  `Local LLM` ManualTestApp tab through `BiscottiLLM.xpc` (inference, streaming, thinking, the
  three quality judgments, reclamation). Record + commit `llm_*` results, turning
  `make manual-tests-check` green for the set.

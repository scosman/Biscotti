---
status: complete
---

# Implementation Plan: Local LLM Experiment

Ordered build phases. Details live in `functional_spec.md` + `architecture.md`; this is the
checklist. Each phase is one reviewable unit. Built/tested in `experiments/llm` via its own
`swift build` / `swift test` (not repo `make`/CI).

> **Live-model note:** anything needing the real ~8 GB Gemma run — the `[Phase-1 validate]` items
> (architecture §12) and qualitative judgment — is opt-in and may be run by a human on hardware (or
> the agent if the environment allows). Phases 1–3 are written so that **`swift build` + the fast
> unit tests are fully agent-verifiable without the model**; the model-backed checks are gated.

## Phases

- [x] **Phase 1 — Library core (`LocalLLM`) + unit tests.**
  Standalone `Package.swift` (LlamaSwift + ArgumentParser, macOS 15, tools 6.0); value types
  (`EngineConfig`, `GenerationOptions`, `ThinkingMode`, `GenerationResult`, `FinishReason`),
  `LocalLLMError`; `ModelDownloader` (progress, skip-if-present, temp-then-move, no resume/checksum);
  `ChatTemplating` (built-in primary + hand-rolled Gemma 4 fallback); `Sampling` (built-in chain +
  fallback); pure `OutputParser` (stop/turn + thinking-channel stripping); `LLMEngine` actor (load +
  single-turn `generate` decode loop). All **always-on unit tests** (architecture §10) green via
  `swift test`. Built-in paths primary, fallbacks present; live-model confirmation deferred to
  Phase 4.

- [x] **Phase 2 — CLI + validation harness + integration test + docs.**
  `localllm` CLI (`download` + `run`, clean stdout/stderr, speed summary, sampling/`--raw`/
  `--thinking`/`--template` flags); `Prompts/{summarize,action_items,infer_speaker_names}.txt` +
  `Fixtures/sample_transcript.txt`; env-gated model-backed **integration test** (`LLM_RUN_AI=1`);
  `README.md` (build/download/run) + `VALIDATION.md` skeleton (manual run script + empty results).

- [ ] **Phase 3 — Streaming (P2, final).**
  `generateStreaming` (`AsyncThrowingStream<StreamEvent>`) with non-streaming buffering over the same
  loop; CLI `--stream`; streaming unit tests (event ordering, final result parity).

- [ ] **Phase 4 — Live validation (human-run on Apple silicon).**
  Resolve the `[Phase-1 validate]` items against the real model (built-in-vs-hand-rolled template &
  sampler decision, double-BOS, Gemma 4 thinking tokens, b9601 specifics); run the integration test
  + each prompt file; record stack + qualitative findings, speed/memory, and the Project 10
  recommendation in `VALIDATION.md`. This is the experiment's payoff.

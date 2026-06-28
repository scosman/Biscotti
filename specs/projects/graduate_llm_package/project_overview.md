---
status: complete
---

# Graduate LLM Package

We started `experiments/llm` as an experiment. We want to graduate it to a package in
`Packages/` at the repo root.

This involves:

- **Quality review.** Review the package against a high, shippable-package quality bar.
  Identify any remaining "experiment-level" quality (framing, conventions not matching the
  other graduated packages, missing strictness flags, lint/format gaps, dead code, docs).
  Fix the issues found.
- **Move it into `Packages/`.** Relocate the package from `experiments/llm` to its home under
  `Packages/`, matching the layout and conventions of the existing graduated packages
  (`AudioCapture`, `Transcription`, `BiscottiKit`).
- **Update the CLI to point to the new package location.** The package ships a CLI
  (`localllm`) and an out-of-process service binary (`localllm-service`). Update everything
  that references the old `experiments/llm` location — build wiring (`hooks_mcp.yaml`,
  `Makefile`), docs, and any invocation paths — so the CLI builds and runs from the new home.
- **Verify it all still works.** Autonomous tests (the always-on unit suite, wired into the
  gating build/test/CI like the other packages) plus human-in-the-loop verification for the
  CLI and the model-backed LLM tests (which need the ~8 GB model on real hardware).

## Context

- The package is the **local LLM inference runtime** (Swift + `llama.swift`/llama.cpp +
  Gemma 4 12B QAT): a `LocalLLM` library (`LLMService`/`LLMConnection` API, actor engine,
  streaming, channel-aware output parsing, hand-rolled Gemma chat template), an
  out-of-process service for full memory reclamation, and a CLI harness.
- It was built and hardware-validated under the `llm_xpc_service` spec project; the
  validation (`experiments/llm/VALIDATION.md`) recommends porting it "largely as-is" and
  judges the core API "production-grade."
- In the roadmap (`specs/architecture.md` / `specs/implementation_plan.md`), the eventual **Intelligence**
  package (Project 10, P2) is the product feature layer — a provider abstraction (local +
  external OpenAI-compatible) delivering summaries, action items, speaker-name inference, and
  vocab extraction. This graduation is **not** Project 10: it ships the local inference
  foundation only, which Project 10 will later build on.

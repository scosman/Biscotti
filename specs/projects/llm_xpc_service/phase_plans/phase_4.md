---
status: complete
---

# Phase 4: CLI Rework + AI Tests + Docs

## Overview

Rework `RunCommand` to use `LLMService.withConnection` instead of directly constructing
`LLMEngine`. Add a `--backend out-of-process|in-process` flag (default out-of-process) and
a `--verbose` flag that gates child stderr. Remove the parent-side `_exit` teardown hack
(out-of-process delegates teardown to the child; in-process still needs the ordered
`LocalLLMRuntime.shutdown()`). Rewrite the AI integration tests to go through `LLMService`
with a shared connection. Update docs.

## Steps

1. **Fix `LLMService.createBackend` for in-process with real `LLMEngine`**: The `.inProcess`
   case currently throws "not implemented" for real models. Add a new internal
   `InProcessBackend` initializer that takes `model: URL, config: EngineConfig` and lazily
   constructs the `LLMEngine` at `start()` time. Wire this into `createBackend`.

2. **Add `verbose` parameter to `RemoteBackend`**: Already exists (`verbose: Bool` in init).
   Wire it through `LLMService.withConnection` / `openConnection` by adding an optional
   `verbose: Bool = false` parameter to the public API and threading it through
   `createBackend`.

3. **Rework `RunCommand` over `LLMService.withConnection`**:
   - Add `--backend out-of-process|in-process` option (default `out-of-process`).
   - Map to `LLMService.Backend`.
   - Move engine construction into the `withConnection` block.
   - For streaming: adapt `runStreaming` to accept `LLMConnection` instead of `LLMEngine`.
   - For buffered: use `conn.generate(...)`.
   - Template routing: move the Gemma template rendering to happen before the connection
     (it only needs the prompt/system/options, not the engine). Pass pre-rendered prompt
     and options through the connection.
   - Remove the `_exit(EXIT_SUCCESS)` hack and the manual `engine.unload()` /
     `LocalLLMRuntime.shutdown()` calls -- `withConnection` handles teardown.
   - For `--backend in-process`, still need `LocalLLMRuntime.shutdown()` + `_exit` since
     the in-process backend's unload doesn't bypass the Metal static destructors. Gate
     this on the backend choice.
   - Preserve: `--stream`, thinking/response sections, `--show-raw`, speed summary,
     sampling flags, `--thinking`, `--template`, `--verbose`.

4. **Expose child PID from `LLMConnection` for AI test reclamation assertion**:
   Add an internal `childPID` property to `LLMConnection` that delegates to the backend.
   `RemoteBackend` returns its transport handle PID; `InProcessBackend` returns nil.

5. **Rewrite AI integration tests over `LLMService`**:
   - Replace the shared `LLMEngine` with a shared `LLMConnection` (via
     `LLMService.openConnection`, out-of-process by default).
   - Re-cover: `stackWorks`, `determinism`, `streamingParityWithBufferedGenerate`,
     `builtinTemplateSanity`.
   - Add: `reclamation` test -- after `close()`, assert the child PID is gone.
   - Add: optional `inProcessParity` test -- run one generate in-process and verify
     result matches out-of-process.
   - Keep the `LLM_RUN_AI=1` gate and `LLM_MODEL_PATH` support.

6. **Update `experiments/llm/README.md`**:
   - Document the service interface (`LLMService.withConnection`).
   - Document the `--backend` flag.
   - Add the build/test gotcha note about orphaned processes and `.build` lock.

7. **Update `experiments/llm/VALIDATION.md`**:
   - Add the `--backend` flag to validation commands.
   - Add manual reclamation check step (run with `--backend out-of-process`, then verify
     no orphaned `localllm-service` processes remain).

8. **Create `experiments/llm/NOTES.md`**:
   - Document the build/test gotcha: hooks-mcp kills a build/test on its timeout but
     orphans the underlying `swift` process, which keeps the `.build` lock and silently
     blocks all later builds; recovery requires `pkill`-ing the orphan. The
     `hooks_mcp.yaml` `build_llm`/`test_llm` timeout was raised to 300s.

## Tests

- `testStackWorks` (AI, LLM_RUN_AI=1): load + generate via LLMService, verify sane result
- `testDeterminism` (AI): greedy decoding deterministic across two runs via connection
- `testStreamingParityWithBufferedGenerate` (AI): streaming and buffered produce identical
  results through the service layer
- `testBuiltinTemplateSanity` (AI): built-in template produces sane tokenization via service
- `testReclamation` (AI): after close(), child PID is gone (kill(pid,0) returns ESRCH)
- `testInProcessParity` (AI): in-process generate matches out-of-process for same prompt
- All existing always-on tests remain green (no changes to them)

---
status: complete
---

# Phase 1: Graduate, harden, strip the pipe transport

## Overview

Move `experiments/llm` to `Packages/LocalLLM` via `git mv`, harden to production quality
(house-style Package.swift, `-warnings-as-errors`, `swiftLanguageModes: [.v6]`, test resources),
and delete the pipe transport and dead experiment scaffolding. The package emerges as a clean
library + CLI with `.inProcess` as the only backend; the CLI loses `--backend` and `--template`.
Wire into Makefile, `hooks_mcp.yaml`, and rename the AI-test env var to `BISCOTTI_RUN_AI_TESTS`.
Write a production README.

## Steps

1. **`git mv experiments/llm Packages/LocalLLM`** -- relocate tracked files; exclude `.build*/`
   and stray build intermediates (the `.gitignore` already covers them).

2. **Delete pipe-transport sources** from `Sources/LocalLLM/`:
   - `RemoteBackend.swift` (+ `TransportHandle`)
   - `ServiceLoop.swift`
   - `FrameCodec.swift`
   - `SamplingFallback` from `Sampling.swift` (keep `SamplerBuilder`)
   - `BuiltinChatTemplate` from `ChatTemplate.swift` (keep `GemmaChatTemplate`, protocol,
     and `withChatMessages` helper but remove the `BuiltinChatTemplate` struct entirely)
   - `ServiceRequest`, `ServiceEvent` from `WireProtocol.swift` (keep `WireError` -- renamed
     to `LLMErrorPayload` in Phase 2 -- and `LLMServiceError`)
   - `MockEngine.swift` from `Sources/LocalLLM/` (move to test target)

3. **Delete `Sources/Service/` directory** (the `main.swift` service binary).

4. **Delete test files** that test deleted code:
   - `TransportTests.swift`
   - `TestServiceBinary.swift`
   - `FrameCodecTests.swift`
   - `SamplingTests.swift`
   - Remove `ServiceRequest`/`ServiceEvent`/`WireError` Codable + mapping tests from
     `WireProtocolTests.swift` (keep `LLMServiceError` tests; rename file if only those remain)

5. **Update `Package.swift`** to house style:
   - Remove `llm-service` target and `localllm-service` product
   - Add `warningsAsErrors` swift setting to every target
   - Add `swiftLanguageModes: [.v6]`
   - Add `resources: [.copy("Fixtures"), .copy("Prompts")]` to test target
   - Clean up experiment-era comments; match trailing-comma style from Transcription
   - Remaining: `LocalLLM` library, `llm-cli` executable, `LocalLLMTests`

6. **Collapse `Backend` enum** in `LLMService.swift`:
   - Remove `.outOfProcess(serviceBinary:)` case; keep `.inProcess` only
   - Remove default from `withConnection`/`openConnection` backend param (or hardcode `.inProcess`)
   - Remove `createBackend` outOfProcess arm and all `RemoteBackend` references
   - Remove `openFakeConnection` method
   - Remove `LOCALLLM_SERVICE_PATH` references

7. **Strip `--backend`, `--template` flags from CLI**:
   - Remove `CLIBackend` enum, `TemplateChoice` enum
   - Remove `--backend` and `--template` options from `RunCommand`
   - Hardcode in-process backend and gemma template
   - Always do ordered teardown + `_exit(EXIT_SUCCESS)` (no backend check needed)
   - Reword the `_exit` TODO: "blocked upstream" instead of experiment-era wording
   - Remove `useBuiltinTemplate` usage from generation options

8. **Remove `useBuiltinTemplate` from `GenerationOptions`** and all references:
   - Remove the property and init parameter
   - Remove from `LLMEngine.selectTemplate` (always use `GemmaChatTemplate`)
   - Remove `BuiltinChatTemplate` construction path from `LLMEngine`
   - Remove `builtinTemplateString` field from `LLMEngine`

9. **Move `MockEngine.swift`** to `Tests/LocalLLMTests/`

10. **Update `LLMConnection`**:
    - Remove `childPID` property (no more `RemoteBackend`)

11. **Update `IntegrationTests.swift`**:
    - Rename `LLM_RUN_AI` to `BISCOTTI_RUN_AI_TESTS` in the env check
    - Remove out-of-process connection, `sharedPID`, `TestServiceBinary` references
    - Make all tests use `.inProcess`
    - Remove `reclamation()` test (no child process)
    - Remove `inProcessParity()` test (only one backend now)
    - Keep `stackWorks`, `determinism`, `streamingParityWithBufferedGenerate`,
      `builtinTemplateSanity` (adapted for in-process)

12. **Update `StreamingTests.swift`**: no changes expected (uses `SyntheticStream`, no transport)

13. **Update `WireProtocolTests.swift`**:
    - Remove `ServiceRequest`/`ServiceEvent` Codable tests
    - Remove `WireError` Codable + mapping tests
    - Keep `LLMServiceError` tests only; rename file to `ErrorTests.swift` if merged,
      or keep separate -- merge into existing `ErrorTests.swift`

14. **Strip experiment framing** from comments/docs:
    - `ChatTemplate.swift`: remove `experiments/llm/README.md` path references
    - `LLMEngine.swift`: remove experiment-era comments, Phase references
    - `ServiceBackend.swift`: update doc comment (only `InProcessBackend` now)
    - `LLMService.swift`: remove "Phase 3" references
    - `LocalLLMRuntime.swift`: remove "Project 10" reference in comment

15. **Lint cleanup**: fix >120-char lines, justified inline disables for `strdup`/`URL(string:)!`

16. **Wire into Makefile**:
    - Add `Packages/LocalLLM` to `PACKAGES`
    - Add `BISCOTTI_RUN_AI_TESTS=1 swift test --package-path Packages/LocalLLM` to `test-ai`
    - Add `Packages/LocalLLM` to `clean` loop

17. **Wire into `hooks_mcp.yaml`**:
    - Repoint `build_llm` to `Packages/LocalLLM`
    - Repoint `test_llm` to `Packages/LocalLLM`
    - Update descriptions to say "LocalLLM package" not "experiment"
    - Update env var reference in test_llm description

18. **Write production `README.md`** for the package (library API, CLI, build/test, model
    location, preserved technical rationale from NOTES.md/VALIDATION.md)

19. **Remove experiment files**: `NOTES.md`, `VALIDATION.md` (durable findings folded into README)

20. **Add `LocalLLMPaths`** enum to the library with `defaultModelCacheDir() -> URL`
    (shared between CLI and future ManualTestApp tab). Update CLI's `CLIHelpers.swift` to use it.

## Tests

- All existing always-on tests pass (minus deleted transport/sampling/builtin tests)
- `ConnectionTests`: lifecycle, serial ordering, cancellation, error handling -- unchanged
- `StreamingTests`: streaming contract, channel splitter -- unchanged
- `ChatTemplateTests`: GemmaChatTemplate golden tests -- unchanged
- `OutputParserTests`: parse, strip, stop sequences -- unchanged
- `GenerationOptionsTests`: Codable round-trips -- minus `useBuiltinTemplate`
- `GenerationResultTests`: Codable round-trips -- unchanged
- `ErrorTests`: LocalLLMError descriptions -- unchanged
- `CLITests`: transcript substitution -- unchanged
- `RuntimeTests`: shutdown idempotency -- unchanged
- `ModelDownloaderTests`: file helpers -- unchanged
- `WireProtocolTests` -> merged: `LLMServiceError` tests only (+ `LLMErrorPayload` round-trips
  retained for Phase 2 reuse)
- `make build`/`test`/`lint`/`ci` green

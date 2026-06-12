---
status: complete
---

# Phase 1: Library Core (`LocalLLM`) + Unit Tests

## Overview

Build the standalone `experiments/llm/` SPM package containing the production-grade `LocalLLM`
library with all value types, the `LLMEngine` actor (load + single-turn `generate`), model
downloading, chat templating (built-in primary + hand-rolled Gemma 4 fallback), sampling (built-in
chain + hand-rolled fallback), pure output parsing, and comprehensive always-on unit tests. No CLI,
no prompt files, no streaming -- those are later phases.

The verification bar is: `swift build` succeeds and ALL always-on unit tests pass via `swift test`.
The env-gated integration test skeleton exists but is not run. No model download required.

## Steps

1. **Create `experiments/llm/Package.swift`** -- swift-tools-version 6.0, macOS 15, products
   `LocalLLM` (library) + `localllm` (executable, stubbed), dependencies on `mattt/llama.swift`
   `.upToNextMajor(from: "2.9601.0")` and `swift-argument-parser` from `"1.3.0"`. Test target
   with resources for fixtures.

2. **Create value types** (`Sources/LocalLLM/`):
   - `EngineConfig.swift` -- `contextSize`, `nGpuLayers`, `threadCount`, `seed`, `.default`
   - `GenerationOptions.swift` -- all sampling params, `ThinkingMode`, `applyChatTemplate`,
     `stopSequences`, `.default` with Gemma-recommended values
   - `GenerationResult.swift` -- `text`, `reasoning`, counts, `FinishReason`, timings,
     `tokensPerSecond`
   - `LocalLLMError.swift` -- typed error enum with `LocalizedError` conformance

3. **Create `ChatTemplate.swift`** -- `ChatTemplating` protocol; `BuiltinChatTemplate` (uses
   `llama_chat_apply_template` + `llama_model_chat_template`); `GemmaChatTemplate` (hand-rolled
   Gemma 4 format: `<start_of_turn>system\n...<end_of_turn>\n<start_of_turn>user\n...<end_of_turn>\n<start_of_turn>model\n`).

4. **Create `Sampling.swift`** -- `SamplerBuilder` that builds a `llama_sampler` chain from
   `GenerationOptions` (penalties -> top_k -> top_p -> min_p -> temp -> dist; greedy for temp==0).
   Plus hand-rolled fallback functions (pure, testable) for logit transforms.

5. **Create `OutputParser.swift`** -- pure string operations: strip trailing `<end_of_turn>` /
   `<eos>` / stop sequences; extract thinking channel (`<|channel>thought\n...<channel|>`) into
   `reasoning`; trim.

6. **Create `ModelDownloader.swift`** -- `download(from:to:progress:)` with skip-if-present,
   directory-vs-file destination handling, temp-then-move atomicity. Network via `URLSession`.

7. **Create `LLMEngine.swift`** -- actor with `init(modelPath:config:)`, `generate(prompt:system:options:)`,
   `unload()`. Backend init guarded by global once. Full decode loop: clear KV cache ->
   template -> tokenize -> prompt eval -> sample loop -> output parse -> assemble result.

8. **Create CLI stub** (`Sources/localllm/LocalLLMCLI.swift`) -- minimal `@main` entry point that
   compiles but defers real subcommands to Phase 2.

9. **Write comprehensive unit tests** (`Tests/LocalLLMTests/`):
   - `ChatTemplateTests.swift` -- golden renders for GemmaChatTemplate
   - `OutputParserTests.swift` -- stop/turn stripping, thinking channel extraction
   - `GenerationOptionsTests.swift` -- defaults, overrides, maxTokens clamping
   - `SamplingTests.swift` -- hand-rolled transforms over known logit vectors
   - `ModelDownloaderTests.swift` -- pure helper logic (stubbed network)
   - `ErrorTests.swift` -- error descriptions, mapping
   - `GenerationResultTests.swift` -- tokensPerSecond math, duration computation

## Tests

- **ChatTemplateTests**: system+user render, user-only render, no literal `<bos>` in output,
  addGenerationPrompt on/off, raw mode bypass
- **OutputParserTests**: strips `<end_of_turn>`, strips `<eos>`, strips custom stop sequences,
  extracts thinking channel to reasoning, handles no-thinking case, idempotent on clean text
- **GenerationOptionsTests**: `.default` has Gemma values (temp 1.0, topK 64, topP 0.95, etc.),
  override application, maxTokens clamping logic
- **SamplingTests**: argmax for temp==0, top-k filtering, top-p nucleus cut, min-p filtering,
  temperature scaling, repeat penalty application, seed determinism
- **ModelDownloaderTests**: file-vs-directory destination, filename derivation from URL,
  skip-if-present returns immediately, partial file cleanup
- **ErrorTests**: each error case produces a non-empty errorDescription, no leaked C type names
- **GenerationResultTests**: tokensPerSecond with known values, zero-safe division

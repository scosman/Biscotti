---
status: complete
---

# Phase 1: LocalLLM Message-List Format

## Overview

Convert the entire LocalLLM stack from the current `(system: String?, user: String)` /
`(prompt: String, system: String?)` parameter pairs to a single `messages: [LLMMessage]`
list at every layer: the public `ChatTemplating` protocol, `InferenceEngine`,
`LLMEngine`, `ServiceBackend`, `InProcessBackend`, `XPCBackend`, `LLMConnection`,
the request DTOs, the XPC host (`BiscottiLLM/main.swift`), `MockEngine`, and the CLI.

The existing ManualTestApp `llm_*` call sites are rewired to use the messages API
(single-turn = one `[.user(prompt)]` message list). A new `llm_chat_system` step
exercises a `[.system(...), .user(...)]` call to confirm system framing works.
All `llm_*` recordable steps are marked not-run per the staleness rule.

**No behavior change** beyond the API shape: a single- or two-message list produces
identical output to the old `system + user` pair.

## Steps

1. **Add `LLMMessage` value type.** New file
   `Packages/LocalLLM/Sources/LocalLLM/LLMMessage.swift` with `Role` enum
   (`.system`, `.user`, `.assistant`), static factories, `Codable`/`Sendable`/`Equatable`.

2. **Generalize `ChatTemplating` + `GemmaChatTemplate`.** Change the protocol to
   `render(messages:addGenerationPrompt:)`. Implement the multi-turn loop:
   - `.system` → `<|turn>system\n` + (thinking? `<|think|>\n`) + content + `<turn|>\n`
   - `.user` → `<|turn>user\n` + content + `<turn|>\n`
   - `.assistant` → `<|turn>model\n` + content + `<turn|>\n`
   - thinking-with-no-system edge: emit bare directive turn before first message
   - generation prompt + empty thought prefill at end

3. **Update `LLMRequestDTOs`.** Replace `LLMGenerateRequest.prompt/system` with
   `messages: [LLMMessage]`. Replace `LLMCountTokensRequest.user/system` with
   `messages: [LLMMessage]`.

4. **Update `InferenceEngine` protocol.** Change all three methods to take
   `messages: [LLMMessage]` instead of `prompt`/`system`/`user`.

5. **Update `LLMEngine`.** Convert `countTokens`, `generate`, `generateStreaming`,
   and the internal `runGeneration` to take `messages: [LLMMessage]`. Build the
   prompt string from messages via the chat template.

6. **Update `ServiceBackend` protocol.** Change `countTokens`, `generate`,
   `generateStreaming` to take `messages: [LLMMessage]`.

7. **Update `InProcessBackend`.** Forward `messages` to the engine. Update
   `PlaceholderEngine` signatures.

8. **Update `XPCBackend`.** Encode the new DTOs; forward `messages` in generate,
   generateStreaming, countTokens.

9. **Update `LLMConnection`.** Change `countTokens`, `generate`, `generateStreaming`
   public methods to take `messages: [LLMMessage]`.

10. **Update XPC host (`BiscottiLLM/main.swift`).** Decode new DTOs, call
    `conn.generate(messages:options:)` etc.

11. **Update CLI (`RunCommand.swift`).** Build messages from the resolved system/prompt,
    pass to connection methods.

12. **Update `MockEngine` (tests).** Change method signatures to `messages:`.

13. **Update `FailingBackend` (connection tests).** Change signatures.

14. **Update existing tests.** Rewrite `ChatTemplateTests` to use `render(messages:…)`,
    adding parity assertions (single/two-message list matches old output byte-for-byte).
    Update `LLMRequestDTOTests` for new DTO shapes. Update `ConnectionTests` and
    `IntegrationTests` call sites.

15. **Add multi-turn template tests.** Test rendering of a full
    `[.system, .user, .assistant, .user]` conversation with `addGenerationPrompt: true`.
    Test assistant turn rendering (model turn marker, no empty-thought prefill).

16. **Add DTO round-trip tests for new message-list payloads.**

17. **Update ManualTestApp `WiredScripts.swift`.** Rewire all `llm_*` action steps
    to use `conn.generate(messages:…)` / `conn.generateStreaming(messages:…)`.

18. **Add `llm_chat_system` step to `LocalLLMScript.swift`.** A
    `[.system(…), .user(…)]` call with a humanQuestion confirming system framing works.

19. **Mark all `llm_*` recordable steps not-run** in
    `ManualTestApp/Results/manual_test_results.json`.

## Tests

- `ChatTemplateTests`: parity tests (messages API matches old output); multi-turn
  rendering; assistant turn rendering; all existing edge cases updated to messages API.
- `LLMRequestDTOTests`: round-trip tests for new `messages`-based DTOs; decode-failure
  tests updated.
- `ConnectionTests`: all call sites updated to `messages:` API; existing behavior
  preserved.
- `IntegrationTests`: call sites updated to `messages:` API.
- `MockEngine` flow: messages pass through generate/streaming/countTokens correctly.

---
status: complete
---

# Phase 2: KV-Cache Prefix Reuse

## Overview

Add KV-cache prefix reuse to `LLMEngine` so that consecutive generate calls
within a single connection automatically reuse the longest matching token prefix
from the previous call's KV cache. This is the core performance optimization
that makes multi-turn analysis (Phase 3) fast: the transcript is decoded once
on the first turn and served from cache on the second.

## Steps

1. **Add `cachedTokens` state to `LLMEngine`.** A `private var cachedTokens:
   [llama_token] = []` tracking what is currently resident in the KV cache
   (seq 0). Reset to `[]` in `createContext`, `unload`, and on any generation
   error/cancellation.

2. **Add `commonPrefixLength` helper.** A `static func commonPrefixLength(_:_:)
   -> Int` on `LLMEngine` that returns the first divergent index between two
   `[llama_token]` arrays.

3. **Replace the unconditional `llama_memory_clear` in `runGeneration` with the
   diff/seq_rm/suffix-prefill algorithm.** Tokenize the full prompt, compute the
   common prefix with `cachedTokens`, trim the divergent KV tail via
   `llama_memory_seq_rm`, and prefill only the suffix. Context-overflow check
   uses the full prompt length. On successful generation, update `cachedTokens`
   to `newTokens + generatedContentTokens`.

4. **Error/cancel consistency.** Wrap the decode loop in a do/catch that clears
   the KV cache (`llama_memory_clear`) and resets `cachedTokens = []` on any
   error or cancellation, so the next call starts cold.

5. **Add `GenerationResult.cachedPromptTokenCount`.** New `Int` field reporting
   how many prompt tokens were served from the KV cache. Set to `prefixLen` in
   the engine; set to `0` in all mock/test construction sites.

6. **Add `#if DEBUG` timing log.** At the end of `runGeneration`, emit a
   structured log line showing cached/fresh token counts and per-phase timings.

7. **Add `llm_kv_reuse` manual-test steps.** Three new steps in
   `LocalLLMScript.swift`: an instruction explaining what to look for, an action
   that runs two extending generates in one connection, and a humanQuestion
   confirming reuse happened and output was coherent. Wire the action in
   `WiredScripts.swift`.

8. **Add KV-reuse integration test.** In `IntegrationTests.swift` (env-gated,
   `make test-ai`): two-turn extend within one connection, assert
   `cachedPromptTokenCount < 10` on turn 1 (near-cold; allows small BOS/template
   prefix overlap from shared connection) and `> 0` on turn 2 with at least
   50% of turn-1 prompt tokens reused. Uses a realistically-long transcript.

9. **Update `manual_test_results.json`.** Add `llm_kv_reuse` and
   `llm_kv_reuse_quality` as `not-run`. Existing `llm_*` steps already
   marked `not-run` from Phase 1.

10. **Update `ScriptShapeTests`.** Bump expected step count from 18 to 21 and
    add the three new step IDs to the canonical set.

11. **Update all `GenerationResult` construction sites.** Add
    `cachedPromptTokenCount: 0` (or appropriate value) to every init call across
    source and test files.

## Tests

- `CommonPrefixLengthTests`: both-empty, first-empty, second-empty, identical,
  divergent-at-0, divergent-at-k, first-is-prefix, second-is-prefix,
  single-match, single-mismatch.
- `CachedPromptTokenCountTests`: stored value, Codable round-trip, zero for
  cold start (MockEngine.defaultResult).
- `GenerationResultCodableTests` (WireProtocolTests): updated to include
  `cachedPromptTokenCount` in round-trip assertions.
- `IntegrationTests.kvCacheReuse` (`make test-ai`, human-run): two-turn extend,
  assert cached count and reuse fraction.
- `ScriptShapeTests`: updated expected step count and ID set.

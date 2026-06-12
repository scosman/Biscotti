---
status: complete
---

# Phase 3: Streaming (P2, final)

## Overview

Add `generateStreaming` to `LLMEngine` returning `AsyncThrowingStream<StreamEvent, Error>`, then
**unify** the decode loop so the existing non-streaming `generate` is re-expressed as buffering
over the same single code path. Add `--stream` to the CLI `run` command. Add streaming unit tests
that verify event ordering and result parity -- all without requiring the real model.

The key design decision: factor the shared decode-loop logic into a protocol-based `TokenSource`
so the streaming assembly + buffering adaptor can be driven by a synthetic/stubbed token sequence
in unit tests.

## Steps

### 1. Define `StreamEvent` (GenerationResult.swift)

Add `StreamEvent` enum to GenerationResult.swift:
```swift
public enum StreamEvent: Sendable, Equatable {
    case token(String)
    case done(GenerationResult)
}
```

### 2. Factor decode loop into internal helpers (LLMEngine.swift)

Extract the shared decode-loop body into a private method that:
- Accepts a closure/callback for each emitted token piece (for streaming)
- Returns the same `GenerationResult` at the end
- Is called by both `generate` (ignoring per-token callback) and `generateStreaming`

The core method signature:
```swift
private func decodeLoop(
    ctx: OpaquePointer, vocab: OpaquePointer,
    promptTokenCount: Int, maxTokens: Int,
    options: GenerationOptions, systemText: String?,
    promptText: String, totalStart: ContinuousClock.Instant,
    evalStart: ContinuousClock.Instant, evalEnd: ContinuousClock.Instant,
    onToken: @Sendable (String) -> Void
) async throws -> GenerationResult
```

### 3. Re-implement `generate` as buffering over the shared loop

`generate` calls the shared decode method with a no-op `onToken` closure, then returns the
`GenerationResult`.

### 4. Add `generateStreaming` (LLMEngine.swift)

Returns `AsyncThrowingStream<StreamEvent, Error>`. Internally:
- Performs prompt setup (template, tokenize, prompt-eval) in the stream's build closure
- Calls the shared decode method, yielding `.token(piece)` for each token
- Yields `.done(result)` at the end
- Handles errors by finishing the stream with the error

### 5. Add `--stream` flag to `RunCommand` (CLI)

- New `@Flag` property `stream: Bool = false`
- When set, calls `engine.generateStreaming(...)` and prints each token to stdout as it arrives
  (no trailing newline per token -- use `print(..., terminator: "")` + `fflush`)
- After the stream completes, prints a final newline to stdout, then the speed summary to stderr
- When not set, behaves exactly as before (calls `generate`)

### 6. Add streaming unit tests (new StreamingTests.swift)

Tests that exercise streaming logic WITHOUT the model:
- **Event ordering**: tokens arrive before `.done`
- **Final-result parity**: streaming a known token sequence produces the same `GenerationResult`
  as buffering
- **Token concatenation**: streamed tokens join to form the complete text
- **Empty generation**: `.done` with zero tokens is valid
- **Error propagation**: errors in the stream are thrown correctly

To make this testable without the model, factor the stream-assembly/buffering logic so it can be
driven by a synthetic token sequence. Specifically, add an internal helper
`assembleStreamEvents(tokens:result:)` or test via the `AsyncThrowingStream` construction with
known inputs.

## Tests

- `StreamingTests/eventOrderingTokensBeforeDone`: verify `.token` events precede `.done`
- `StreamingTests/finalResultParityWithBufferedGenerate`: streaming and non-streaming produce
  identical `GenerationResult` for the same token sequence
- `StreamingTests/streamedTokensConcatenateToFullText`: joining all `.token` payloads equals
  `result.text` (pre-post-processing)
- `StreamingTests/emptyGenerationYieldsDoneOnly`: zero tokens yields just `.done`
- `StreamingTests/streamEventEquality`: verify `StreamEvent` Equatable conformance

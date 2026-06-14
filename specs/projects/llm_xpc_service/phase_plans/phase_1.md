---
status: complete
---

# Phase 1: Wire Protocol Foundation

## Overview

Establish the wire protocol types, codec, and Codable conformances that all subsequent
phases build on. This is pure data types + unit tests -- no process spawning, no backends,
no connection logic. Everything lives in `Sources/LocalLLM/` and
`Tests/LocalLLMTests/`.

## Steps

1. **Add `Codable` to existing types** (`GenerationOptions`, `EngineConfig`,
   `GenerationResult`, `FinishReason`, `ThinkingMode`). All are simple structs/enums
   whose stored properties are already Codable-friendly, so synthesized conformance
   suffices. Add `: Codable` to each declaration. (arch S6.3)

2. **Create `Sources/LocalLLM/WireProtocol.swift`** containing:
   - `ServiceRequest` -- Codable enum with cases `.generate(id:prompt:system:options:streaming:)`,
     `.cancel(id:)`, `.shutdown`. (arch S6.2)
   - `ServiceEvent` -- Codable enum with cases `.ready`, `.loadError(WireError)`,
     `.token(id:piece:)`, `.reasoningToken(id:piece:)`, `.done(id:result:)`,
     `.requestError(id:error:)`, `.fatal(WireError)`. (arch S6.2)
   - `WireError` -- Codable+Equatable enum mirroring LocalLLMError cases plus
     `.service(String)`. Includes `static func from(_ error: any Error) -> WireError`
     and `func toClientError() -> any Error` for bidirectional mapping. (arch S6.4)

3. **Create `Sources/LocalLLM/FrameCodec.swift`** containing:
   - `FrameCodec` enum with static `encode<T: Encodable>(_ value: T) throws -> Data`
     (4-byte big-endian UInt32 length prefix + JSON payload).
   - `static func decode<T: Decodable>(_ type: T.Type, from handle: FileHandle) throws -> T`
     that reads exactly 4 bytes for the length, validates against a 64 MB cap, reads
     exactly N bytes (reassembly loop for partial reads), then JSON-decodes. (arch S6.1)
   - `FrameCodecError` for oversize/truncated/decode failures.

4. **Create `Tests/LocalLLMTests/WireProtocolTests.swift`** with:
   - Codable round-trip tests for `GenerationOptions`, `EngineConfig`, `GenerationResult`
     (with all field variants), `FinishReason`, `ThinkingMode`.
   - Round-trip tests for every `ServiceRequest` case and every `ServiceEvent` case.
   - `WireError` mapping: every `LocalLLMError` case -> `WireError` -> client error,
     verifying the reconstructed error matches the original. Also test the `.service`
     fallback path and `.cancelled` -> `LLMServiceError.cancelled`.

5. **Create `Tests/LocalLLMTests/FrameCodecTests.swift`** with:
   - Basic encode/decode round-trip (encode a `ServiceRequest`, decode it back).
   - Partial-read reassembly: write a frame to a pipe in small chunks, read it back.
   - Coalesced frames: write two frames back-to-back, decode both sequentially.
   - Oversize length: write a length header > 64 MB, verify `protocolError`.
   - Truncated frame: write a length header promising N bytes but close the pipe early,
     verify error.
   - Garbage/zero-length edge cases.

## Tests

- `CodableRoundTripTests`: GenerationOptions, EngineConfig, GenerationResult (all fields
  populated + optional nil fields), FinishReason (all cases), ThinkingMode (all cases).
- `ServiceRequestCodableTests`: round-trip for .generate (full options), .cancel, .shutdown.
- `ServiceEventCodableTests`: round-trip for .ready, .loadError, .token, .reasoningToken,
  .done (full GenerationResult), .requestError, .fatal.
- `WireErrorMappingTests`: every LocalLLMError case -> WireError -> client error; .service
  fallback; .cancelled mapping.
- `FrameCodecEncodeDecodeTests`: basic round-trip, partial read, coalesced frames, oversize
  rejection, truncated frame, empty payload.

---
status: complete
---

# Phase 2: NSXPC Transport (Library Side)

## Overview

Add the NSXPC transport layer to the `LocalLLM` library: the `@objc` protocols
(`LLMServiceProtocol` + `LLMEventReporting`), Codable DTOs (`LLMLoadRequest`,
`LLMGenerateRequest`), rename `WireError` to `LLMErrorPayload`, the `XPCBackend:
ServiceBackend` client adapter, `LLMEventReceiver`, and `LocalLLMPaths`. Restore
`Backend.hosted(serviceName:)` behind the unchanged `LLMService`/`LLMConnection`
API. The actual NSXPC service host is Phase 3; this phase builds the library-side
plumbing and tests everything up to the XPC seam.

## Steps

1. **Rename `WireError` to `LLMErrorPayload`** in `WireProtocol.swift`. Update all
   references in source and tests. The type, methods (`from(_:)`, `toClientError()`),
   and Codable conformance are preserved.

2. **Add `@objc` protocols** in a new file `Sources/LocalLLM/LLMServiceProtocol.swift`:
   - `LLMServiceProtocol` (client -> service): `load`, `generate`, `generateStreaming`,
     `cancel`, `healthCheck` -- all with `@objc`-compatible `Data`/`Error?` signatures.
   - `LLMEventReporting` (service -> client, reverse proxy): `reportToken`,
     `reportReasoningToken`, `reportDone(resultData:)`, `reportError(errorData:)`.

3. **Add DTOs** in a new file `Sources/LocalLLM/LLMRequestDTOs.swift`:
   - `LLMLoadRequest`: `modelPath: String`, `config: EngineConfig`. Codable.
   - `LLMGenerateRequest`: `prompt: String`, `system: String?`,
     `options: GenerationOptions`. Codable.

4. **Add `LLMEventReceiver`** in a new file `Sources/LocalLLM/LLMEventReceiver.swift`:
   An `NSObject` conforming to `LLMEventReporting` and `@unchecked Sendable`. Holds
   lock-guarded handler closures (`onToken`, `onReasoningToken`, `onDone`, `onError`)
   that the `XPCBackend` swaps per request. Methods: `setHandlers(...)`, `clearHandlers()`.

5. **Add `XPCBackend: ServiceBackend`** in a new file `Sources/LocalLLM/XPCBackend.swift`:
   - `start()`: create `NSXPCConnection(serviceName:)`, configure interfaces, install
     interruption/invalidation handlers, `activate()`, call `proxy.load(...)` via
     continuation.
   - `generate(...)`: buffered call via `withCheckedThrowingContinuation`, decodes
     `GenerationResult` from reply `Data`, maps errors via `LLMErrorPayload`.
   - `generateStreaming(...)`: returns `AsyncThrowingStream`; sets `LLMEventReceiver`
     handlers, calls `proxy.generateStreaming(...)`, receiver pushes events. On terminal
     or cancellation, detaches receiver and sends `proxy.cancel`.
   - `cancel(id:)`: `proxy.cancel { }`.
   - `shutdown()`: `connection.invalidate()`.
   - `forceKill()`: `connection?.invalidate()`.
   - Error mapping: NSCocoaErrorDomain codes 4097/4099 -> `serviceInterrupted`/
     `serviceUnavailable`; payload decode for `LLMErrorPayload`.

6. **Wire `Backend.hosted` in `LLMService.createBackend`**: replace the `fatalError`
   with `XPCBackend(serviceName:, model:, config:)`.

7. **Unit tests**: New test files:
   - `LLMRequestDTOTests.swift`: round-trip `LLMLoadRequest` and `LLMGenerateRequest`.
   - `LLMEventReceiverTests.swift`: test handler relay (token, reasoning, done, error)
     and clearing.
   - Update `WireProtocolTests.swift`: rename references from `WireError` to
     `LLMErrorPayload`.

## Tests

- `LLMLoadRequest` round-trip: default config and custom config survive JSON encode/decode.
- `LLMGenerateRequest` round-trip: with and without system prompt, various options.
- `LLMErrorPayload` Codable round-trips (existing, just renamed).
- `LLMErrorPayload` mapping both directions (existing, just renamed).
- `LLMEventReceiver` relay: token, reasoningToken, done, error handler calls are
  correctly forwarded; clearing handlers causes subsequent calls to be dropped.

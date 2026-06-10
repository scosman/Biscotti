---
status: complete
---

# Phase 1.3: Client + XPC adapter + error mapping

## Overview

Builds the `Transcriber` actor (the public client the app holds), the `@objc TranscriberServiceProtocol` for XPC communication, and the adapter that bridges between the `@objc` XPC protocol and the async Swift `TranscriptionEngine` seam. The `Transcriber` supports two backends: `.inProcess` (delegates directly to a `TranscriptionEngine`) and `.hosted(serviceName:)` (talks to an XPC service). The hosted path is made unit-testable via an injected connection/proxy seam so tests can simulate normal replies, interruptions, and unavailability without a real XPC process.

## Steps

1. **Create `TranscriberServiceProtocol.swift`**: Define the `@objc` protocol with reply-handler-style methods carrying `Data` (JSON-encoded `TranscriptResult`) + `Error?`. Methods: `processAudio(micPath:systemPath:mergedPath:configData:customVocabulary:reply:)`, `ensureModelsDownloaded(configData:reply:)`, `unloadModels(reply:)`, `healthCheck(reply:)`. All parameters are `@objc`-compatible (strings, data, arrays of strings, closures).

2. **Create `XPCConnection.swift`**: Define a `TranscriberXPCConnecting` protocol (the testable seam for the XPC connection layer) with methods to get a proxy, invalidate, and set interruption/invalidation handlers. Implement `TranscriberXPCConnection` (the real `NSXPCConnection` wrapper) and allow tests to inject a mock.

3. **Create `XPCEngineAdapter.swift`**: A thin adapter that conforms to `TranscriptionEngine` and bridges calls to the `@objc TranscriberServiceProtocol` proxy. Encodes `ProcessorConfig` as JSON `Data` for transport, decodes `Data` replies back into `TranscriptResult`. Maps XPC-specific failures (interrupted, unavailable) to `TranscriptionError.workerInterrupted` / `.workerUnavailable`.

4. **Create `Transcriber.swift`**: The public `Transcriber` actor. Accepts a `Backend` enum (`.inProcess` / `.hosted(serviceName:)`). For `.inProcess`, creates and delegates to an `InProcessTranscriptionEngine`. For `.hosted`, uses the `XPCEngineAdapter` + `TranscriberXPCConnection`. Public API: `ensureModelsDownloaded(progress:)`, `processAudio(mic:system:merged:customVocabulary:)`, `reTranscribe(merged:customVocabulary:)`, `unloadModels()`, `statusStream()`, `isAvailable()`. The `statusStream()` returns an `AsyncStream<ModelStatus>` backed by polling or a continuation-based pattern from the engine. For `.hosted`, the `interruptionHandler` sets a flag so the next call knows to report `workerInterrupted`.

5. **Create `ClientErrorMappingTests.swift`**: Tests using a stub `TranscriptionEngine` and a mock XPC connection seam:
   - Engine errors map to the right `TranscriptionError` variants
   - Simulated interruption surfaces `workerInterrupted` and is retriable (next call succeeds)
   - Unavailable proxy returns `workerUnavailable`
   - `.inProcess` happy-path delegation to a stub engine
   - `statusStream` emits status updates from the engine

## Tests

- `ClientErrorMappingTests/inProcessDelegatesToEngine`: `.inProcess` backend delegates `processAudio` to the stub engine and returns the result.
- `ClientErrorMappingTests/inProcessEnsureModelsDownloaded`: `.inProcess` backend delegates download to the stub engine.
- `ClientErrorMappingTests/inProcessStatusStream`: `statusStream` emits the engine's current status.
- `ClientErrorMappingTests/inProcessIsAvailable`: `isAvailable` returns true when engine reports `.ready`.
- `ClientErrorMappingTests/inProcessReTranscribe`: `reTranscribe` delegates correctly.
- `ClientErrorMappingTests/hostedInterruptionSurfacesWorkerInterrupted`: Simulated interruption on the XPC connection causes the next call to throw `workerInterrupted`.
- `ClientErrorMappingTests/hostedInterruptionIsRetriable`: After `workerInterrupted`, a subsequent call succeeds (worker relaunched).
- `ClientErrorMappingTests/hostedUnavailableProxy`: When the proxy is nil/unavailable, throws `workerUnavailable`.
- `ClientErrorMappingTests/hostedEngineErrorPassesThrough`: Engine errors (e.g. `downloadFailed`) pass through the adapter correctly.
- `ClientErrorMappingTests/hostedUnloadModels`: `unloadModels` delegates through the adapter.

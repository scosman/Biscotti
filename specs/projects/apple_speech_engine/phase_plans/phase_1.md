---
status: complete
---

# Phase 1: Engine Core

## Overview

Add the engine abstraction layer, per-call config, component-based model management, Apple word grouping, and WAV writer to `Packages/Transcription` — no Speech framework yet (Phase 2). Every existing call site compiles unchanged via defaults.

## Steps

1. **New file `SpeechEngine.swift`**: `SpeechEngine` enum (`.whisper`, `.apple`), `ModelComponent` enum (`.whisper`, `.speakerID`) with `Set.all`, `TranscriptionConfig` struct (method, locale, factory methods, engine computed property).

2. **`TranscriptionMethod.swift`**: Add `Codable` conformance, `.appleV1` static, `.engine` computed property (`id.hasPrefix("apple") ? .apple : .whisper`).

3. **`TranscriptionError.swift`**: Add `.engineUnavailable(String)` case.

4. **`MethodResolver.swift`**: Add `engine: SpeechEngine` to `ResolvedMethodSettings`. Add `apple-v1` case to `resolve` (engine `.apple`, subsegment, no language detection, word timestamps on, sequentialLoading = isLowRAM). All existing cases get `engine: .whisper`.

5. **`TranscriptionEngine.swift`**: Add `components` param to `ensureModelsDownloaded`, `config` param to `processAudio`, `components` param to `modelsPresent`. Keep backward compatibility via protocol requirements (no defaults on protocols).

6. **`InProcessTranscriptionEngine.swift`**: Implement component-based `ensureModelsDownloaded(components:)`, `processAudio(…, config:)` with engine switch (whisper runs existing path; apple throws `.engineUnavailable` for now), `modelsPresent(components:)`, new `deleteModels(_:)`. Refactor static presence checks into `componentPresent(_:)`.

7. **`ModelStorage.swift`**: Add `whisperModelDirectory(repo:model:)` and `speakerIDDirectory` helpers for component-based delete.

8. **`Transcriber.swift`**: Update public API signatures with defaulted parameters (`components`, `config`). Add `deleteModels(_:)` public method. Forward components/config through to engine.

9. **`XPCProcessRequest.swift`**: Add `config: TranscriptionConfig?` (optional, decoded with `decodeIfPresent`; nil = whisper default).

10. **`XPCEngineAdapter.swift`**: Encode config into request, add components to download/presence, implement `deleteModels`.

11. **`TranscriberServiceProtocol.swift`**: Change `ensureModelsDownloaded` to take `requestData: Data` parameter. Add `XPCDownloadRequest` type.

12. **XPC service `main.swift`**: Decode config from process request, components from download request. Pass config to engine.

13. **New file `AppleSpeech/AppleWordGrouping.swift`**: Pure word grouping — `AppleRunInput`, `AppleResultInput`, `AppleWord` structs; `words(in:)`, `fillUntimed(_:result:)`, `transcriptionResults(from:language:)` (bridge to WhisperKit `TranscriptionResult`).

14. **New file `AppleSpeech/WAVWriter.swift`**: Write `[Float]` mono 16 kHz to a temp `.wav` file using `AVAudioFile`.

15. **CLI `TranscribeCLI.swift`**: Add `--engine whisper|apple` and `--locale <id>` options. Build `TranscriptionConfig` from options. Apple below macOS 26 prints a clear error message.

## Tests

- `methodEngineMapping`: `.v1/.v2` -> whisper, `.appleV1` -> apple; Codable round-trip
- `configFactories`: `.whisper()` and `.apple(locale:)` produce correct config
- `resolverAppleSettings`: `apple-v1` -> engine apple, subsegment, no language detection
- `processRequestDecodesWithoutConfig`: old JSON without `config` field decodes; defaults to whisper
- `processRequestRoundTripsConfig`: config survives encode/decode
- `downloadRequestComponents`: components encode/decode; empty -> all
- `componentPresenceAndDelete`: temp ModelStorage root; presence per component; delete whisper leaves Speaker ID
- `groupingWholeWordRuns` / `groupingLeadingSpaceRuns` / `groupingMultiRunToken`: ported STTLab grouping cases
- `fillUntimedUsesPreviousEnd` / `fillUntimedUsesNextStart` / `fillUntimedAllUntimedSpread`: untimed fill rules; no words dropped
- `bridgeOneSegmentPerResult`: segment count/order/text/times; empty results dropped
- `bridgeConfidenceDefault`: nil confidence -> probability 1.0
- `bridgeThenAssembleAssignsSpeakers`: bridged results + synthetic DiarizationResult -> addSpeakerInfo + SegmentBuilder -> expected speakers
- `hostedClientSendsConfig` / `hostedClientSendsComponents`: MockXPCConnection sees config/components
- `appleSupportUnavailableBelow26`: on CI (macOS 15) availability returns `.requiresOSUpdate`
- `engineUnavailableErrorMapping`: client error mapping handles the new case

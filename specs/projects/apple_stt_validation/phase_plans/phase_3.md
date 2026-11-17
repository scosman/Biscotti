---
status: complete
---

# Phase 3: Home Engines — WhisperRunner, DiarizationRunner, Reference (OpenRouter), CLI Commands

## Overview

Build the three home-Mac engine runners (WhisperKit, SpeakerKit diarization, and the OpenRouter reference model), plus the supporting infrastructure: ProductionSettings with a drift test, ChunkPlanner for splitting long audio, OpenRouterClient with retry/split policy, ReferenceResponse parsing, and four CLI commands (whisper, diarize, reference, home-run). Each runner is resumable and cached, errors are per-meeting (never fatal to the run), and a MemorySampler wraps each engine call.

## Steps

1. **`STTLabHome/ProductionSettings.swift`**: Copy the production constants from `MethodResolver` (model name, repo, word timestamps, diarization strategy, download base). A comment names the source file.
2. **`STTLabHome/WhisperRunner.swift`**: `WhisperOutput` schema (Codable) and `WhisperRunner.run(workspace:meetings:force:log:)`. Loads WhisperKit once, processes each meeting's WAV via `AudioProcessor.loadAudioAsFloatArray` + `whisperKit.transcribe(audioArray:decodeOptions:)`, saves `home/whisper/<mid>.json`. Resumable: skips completed unless force.
3. **`STTLabHome/DiarizationRunner.swift`**: `SavedDiarization`, `SavedSpeakerSegment`, `DiarizationOutput` schemas. `DiarizationRunner.run(...)` loads SpeakerKit once, diarizes each meeting, saves `home/diarization/<mid>.json`. Includes `SavedDiarization.init(_ result:)` and `rebuild() -> DiarizationResult`.
4. **`STTLabHome/Reference/ChunkPlanner.swift`**: `ChunkPlan`, `ChunkPlan.Chunk` types. `ChunkPlanner.plan(samples:range:targetSeconds:searchSeconds:windowSeconds:hopSeconds:sampleRate:)` returns chunks cut at the quietest silence window.
5. **`STTLabHome/Reference/OpenRouterClient.swift`**: `HTTPTransport` protocol, `URLSessionTransport`, `TranscriptionRequest` (with `jsonBody()` and `metadata()`), `AttemptOutcome` enum, `OpenRouterClient.transcribe(_:)`. Headers per spec. The metadata method excludes the audio data and the Authorization header value.
6. **`STTLabHome/Reference/ReferenceResponse.swift`**: All-optional `Decodable` struct with `text`, `language`, `duration`, `segments`, `words`, `usage`, `model`, `provider`.
7. **`STTLabHome/Reference/ReferenceRunner.swift`**: Orchestrates the reference engine run. Per-meeting: plan chunks, send each via OpenRouterClient with retry/split policy, save raw response + meta + status. Supports `--probe` (60 s clip, print results). Consent prompt before uploads. One model per workspace enforcement.
8. **CLI commands**: `WhisperCommand.swift`, `DiarizeCommand.swift`, `ReferenceCommand.swift`, `HomeRunCommand.swift` (runs whisper then diarize then reference). Register all in `STTLabCLI.swift`.
9. **Tests in `STTLabHomeTests/`**:
   - `ProductionSettingsTests.swift`: drift test that reads `MethodResolver.swift` source and asserts the model name matches.
   - `ChunkPlannerTests.swift`: chunks land in silent gaps, chunk length limits, single chunk for short audio, deterministic.
   - `OpenRouterClientTests.swift`: request builder fields, ZDR flag, no key in saved metadata, response parsing (words present/absent/with segments).
   - `RetryPolicyTests.swift`: stub transport exercises 429 -> retry, 400 -> fatal, repeated timeouts -> split.
   - `SavedDiarizationTests.swift`: round-trip through JSON, rebuild produces equal segment data.

## Tests

- `ProductionSettingsTests/driftTest`: reads `MethodResolver.swift` via `#filePath` and asserts the string `"openai_whisper-large-v3-v20240930_626MB"` matches `ProductionSettings.sttModel`.
- `ChunkPlannerTests/cutsAtSilence`: synthetic samples with known silent gaps; chunks cut inside the silent region.
- `ChunkPlannerTests/singleChunkForShortAudio`: audio shorter than target returns one chunk covering the full range.
- `ChunkPlannerTests/chunkLengthLimits`: no chunk exceeds `targetSeconds + 60`.
- `OpenRouterClientTests/requestBuilderFields`: verifies URL, headers (Content-Type, referer, title), body JSON structure.
- `OpenRouterClientTests/zdrFlagPresent`: body includes `"provider":{"zdr":true}` when enabled.
- `OpenRouterClientTests/noKeyInMetadata`: `metadata()` does not contain the API key string.
- `OpenRouterClientTests/responseParsingWithWords`: decodes a response with words and segments.
- `OpenRouterClientTests/responseParsingNoWords`: decodes a response with no words field; fields are nil.
- `RetryPolicyTests/retryOn429`: stub returns 429 twice then 200; succeeds with 3 attempts.
- `RetryPolicyTests/fatalOn400`: stub returns 400; marked fatal immediately.
- `RetryPolicyTests/splitOnRepeatedTimeout`: two timeouts trigger a split.
- `SavedDiarizationTests/roundTrip`: encode/decode through JSONFiles produces equal values.

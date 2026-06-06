---
status: complete
---

# Phase 1.5: Realign Transcription to the signed-off spec

## Overview

Bring the committed Transcription package (Phases 1.1-1.4) into alignment with the signed-off component spec (`components/transcription.md`). The core changes: replace `TranscriptResult.modelVersion` with `transcriptionMethodId`; introduce the `TranscriptionMethod` public type (`.v1`/`.current`); remove the public `ProcessorConfig` and `DiarizationStrategy` input types (folding their settings into an internal method resolver with RAM-aware quantization); drop `config:` and `mergedPath:`/`merged:` parameters from `TranscriptionEngine`, `Transcriber`, XPC adapter, and CLI; remove `AudioMerger.wrapMerged` and `StreamLabel.merged`; and update all tests accordingly.

## Steps

1. **Create `TranscriptionMethod.swift`** — new public struct with `id: String`, static `.v1` and `.current` properties.

2. **Create internal method resolver** — `MethodResolver.swift` maps `TranscriptionMethod` to concrete internal settings (model name, repo, word-timestamps, diarization strategy, sequential loading). Preserves the RAM-aware quantization logic from `ProcessorConfig.ramAware()` (8 GB threshold). This is an internal type, not public API.

3. **Update `TranscriptResult.swift`** — rename `modelVersion` to `transcriptionMethodId` in the struct, both inits, and `CodingKeys`.

4. **Update `TranscriptionEngine.swift`** — drop `mergedPath:` and `config:` from `processAudio`; both paths become non-optional `String`.

5. **Update `InProcessTranscriptionEngine.swift`** — replace stored `config: ProcessorConfig` with `method: TranscriptionMethod`; use `MethodResolver` internally; drop `mergedPath:`/`config:` from `processAudio`; remove `wrapMerged` usage from `loadAndMergeAudio`.

6. **Update `AudioMerger.swift`** — remove `wrapMerged(_:)` and `StreamLabel.merged`; make `merge(mic:system:)` params non-optional.

7. **Update `XPCProcessRequest.swift`** — drop `mergedPath` and `config` fields; make `micPath`/`systemPath` non-optional `String`.

8. **Update `TranscriberServiceProtocol.swift`** — drop `configData:` from `ensureModelsDownloaded`.

9. **Update `XPCEngineAdapter.swift`** — drop stored `config`; drop `config:` from init and `processAudio`; remove `encodeConfig` helper; update `ensureModelsDownloaded` to drop config encoding.

10. **Update `Transcriber.swift`** — replace `config: ProcessorConfig` with `method: TranscriptionMethod` in init; drop `merged:` from `processAudio`; make `mic:`/`system:` non-optional; update `reTranscribe` to take `mic:system:` instead of `merged:`.

11. **Update `TranscriptSanitizer.swift`** — `modelVersion` reference to `transcriptionMethodId`.

12. **Update `TranscribeCLI.swift`** — remove `--merged` and `--model` flags; make `--mic`/`--system` required; remove `buildConfig` helper; update `validate()`, `printInputSummary`, and `run()`.

13. **Update `OutputFormatting.swift`** — `result.modelVersion` to `result.transcriptionMethodId`.

14. **Delete `ProcessorConfig.swift` and `DiarizationStrategy.swift`**.

15. **Update all test files** — rename `ConfigTests.swift` to `MethodResolutionTests.swift` with new test content; update `modelVersion` references throughout; update `processAudio`/`reTranscribe` call sites to new signatures; remove merged-path tests; update test helpers (`StubTranscriptionEngine`, `makeFixtureResult`, `makeMergedURL` to `makeMicURL`/`makeSystemURL`, `MockTranscriberService`).

## Tests

- `MethodResolutionTests` — `TranscriptionMethod.current.id == "v1"`; `TranscriptionMethod.v1 == .current`; internal resolver picks quantized model + sequential load at <= 8 GB, full-precision at >= 16 GB.
- `ResultCodableTests` — round-trip with `transcriptionMethodId` field name.
- `MergeTests` — no `wrapMerged` tests; merge requires both non-empty streams.
- `ClientErrorMappingTests` — updated call sites (no `merged:`, no `config:`).
- `HostedClientTests` — XPC adapter without `config:`; process requests without `mergedPath`/`config`.
- `CLITests` — no `--merged`/`--model` flags; both `--mic` and `--system` required for validation.
- `CLIOutputTests` — `transcriptionMethodId` in JSON/text output; no merged-path preflight test.
- `SanitizerTests` — `transcriptionMethodId` in fixture results.

## Deferred to Phase 4.5 (real-hardware model lifecycle)

The "Done when" item *"report real model-download progress (replace hardcoded values) and emit `.compiling` / `.loading` separately (SpeakerKit `PyannoteConfig(load:false)` + split download/load)"* is **partially** implemented and the remainder is deferred to the manual-test phase (4.5), because the missing pieces are inherently real-hardware/runtime behaviors that cannot be wired truthfully or verified without downloading/compiling multi-GB models on-device (the autonomy rule defers all hardware validation to 4.5):

- **In place (autonomously verified):** `ModelStatus` has distinct `.downloading(progress:)`, `.compiling`, `.loading` cases; the status machine drives them; the WhisperKit *download* step uses `load: false` (download/load split); a progress callback is plumbed end-to-end (engine → `Transcriber` → CLI).
- **Deferred to 4.5:** (a) replacing the *stepped* download progress (0.0 → 0.8 → 1.0) with WhisperKit's real byte-level download callback; (b) emitting `.compiling` distinctly from `.loading` (CoreML compile vs. weight-load timing is only observable on a real first-compile); (c) giving SpeakerKit the same `load: false` download/load split (`PyannoteConfig`). These will be wired and pass/fail-validated against real models in Phase 4.5's "real model download/compile" step.

Implementation note: the actual code change in this phase was completed directly (the spec-skill coding sub-agents repeatedly hit an environmental autocompact-thrash failure and could not run to completion; see the phase commit message).

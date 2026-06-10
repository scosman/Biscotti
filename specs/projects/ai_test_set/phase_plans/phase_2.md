---
status: complete
---

# Phase 2: Diarization threshold knob + CLI diagnostic

## Overview

Plumb an optional `diarizationClusterThreshold: Float?` through the full production code path (Transcriber -> TranscriptionEngine -> InProcessTranscriptionEngine -> XPCProcessRequest + XPC service) so tests and the CLI can override the diarization cluster-distance threshold. Default is `nil` (SDK default), so production behavior is unchanged. Add `--diarization-threshold` and `--diarization-sweep` CLI flags. Add unit tests for the XPC request Codable round-trip (with/without the new field) and CLI argument parsing for the new flags.

## Steps

1. **Update `TranscriptionEngine` protocol** (`Sources/Transcription/TranscriptionEngine.swift`)
   - Add `diarizationClusterThreshold: Float?` parameter to `processAudio`.

2. **Update `InProcessTranscriptionEngine`** (`Sources/Transcription/InProcessTranscriptionEngine.swift`)
   - Update `processAudio` to accept and forward `diarizationClusterThreshold: Float?`.
   - Update `runDiarization` to accept `clusterThreshold: Float?` and map non-nil to `PyannoteDiarizationOptions(clusterDistanceThreshold:)`.

3. **Update `XPCProcessRequest`** (`Sources/Transcription/XPCProcessRequest.swift`)
   - Add `let diarizationClusterThreshold: Float?` property. Update init. Codable-compatible (optional automatically encodes as absent).

4. **Update `XPCEngineAdapter`** (`Sources/Transcription/XPCEngineAdapter.swift`)
   - Update `processAudio` to accept and forward the new parameter into `XPCProcessRequest`.

5. **Update XPC service** (`XPCServices/BiscottiTranscriber/main.swift`)
   - Forward `request.diarizationClusterThreshold` through to the engine's `processAudio`.

6. **Update `Transcriber`** (`Sources/Transcription/Transcriber.swift`)
   - Add `diarizationClusterThreshold: Float? = nil` to `processAudio` and `reTranscribe`. Forward to engine.

7. **Update `StubTranscriptionEngine`** (`Tests/TranscriptionTests/TranscriberTestHelpers.swift`)
   - Update `processAudio` signature to include the new parameter.

8. **Update CLI** (`Sources/transcribe-cli/TranscribeCLI.swift`)
   - Add `--diarization-threshold <Float>` option.
   - Add `--diarization-sweep <csv>` option.
   - Implement sweep mode: for each threshold, call processAudio, print `<threshold>: speakers=<speakerCount> distinct=<n>` to stderr, where distinct = `Set(result.segments.compactMap{$0.speakerID}).count`.
   - Forward `--diarization-threshold` to processAudio for normal mode.

## Tests

- `XPCProcessRequestCodableTests`: round-trip with `diarizationClusterThreshold` set to a value, and with it nil. Verify backward compatibility (decode JSON without the field).
- `CLIArgumentParsingTests`: parse `--diarization-threshold 0.35`, parse `--diarization-sweep "0.30,0.40"`, parse without either (defaults nil).
- `DiarizationSweepParsingTests`: CSV string -> `[Float]` parsing helper.

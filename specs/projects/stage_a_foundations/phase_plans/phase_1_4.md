---
status: complete
---

# Phase 1.4: CLI harness (`transcribe-cli`)

## Overview

Add a `transcribe-cli` executable target to the Transcription package. The CLI runs the in-process engine path (no XPC), accepts audio file paths and options via argument-parser, and prints the rich `TranscriptResult` as JSON to stdout with all diagnostics/progress on stderr (gotcha #15). Argument-parsing and output-formatting logic is factored into testable units so `CLITests` can verify correctness without downloading models.

## Steps

1. **Add `swift-argument-parser` dependency to `Package.swift`** — pin `from: "1.3.0"` matching the experiment.

2. **Add `transcribe-cli` executable target to `Package.swift`** — depends on `Transcription` library + `ArgumentParser`. Sources in `Sources/transcribe-cli/`.

3. **Create `Sources/transcribe-cli/OutputFormatting.swift`** — testable formatting/emission helpers:
   - `OutputWriter` protocol with `writeStdout(_ text: String)` / `writeStderr(_ text: String)`.
   - `StandardOutputWriter` (real impl using `FileHandle`).
   - `formatResultJSON(_:) throws -> String` — JSON-encode a `TranscriptResult` with pretty-printing + sorted keys + ISO 8601 dates.
   - `formatResultText(_:) -> String` — human-readable formatted text (speaker labels, timestamps, word probabilities).

4. **Create `Sources/transcribe-cli/TranscribeCLI.swift`** — the `@main` `AsyncParsableCommand`:
   - Args: `--mic <path>`, `--system <path>`, `--merged <path>`, `--model <id>`, `--vocab a,b,c`, `--json`.
   - Validation: at least one audio path required.
   - All diagnostics/progress/banners → stderr via the writer.
   - JSON or formatted text output → stdout.
   - Uses `Transcriber(backend: .inProcess, config:)` to run transcription.

5. **Create `Tests/TranscriptionTests/CLITests.swift`** — Swift Testing:
   - Argument parsing: paths, model, vocab, json flag.
   - JSON output formatting: round-trips through `TranscriptResult` decoder.
   - Text output formatting: contains expected labels.
   - Stdout/stderr split: JSON mode emits valid JSON on stdout, nothing non-JSON on stdout (using a `CapturingOutputWriter`).
   - Validation: no audio paths → throws `ValidationError`.

## Tests

- `argumentParsingPaths` — parses --mic, --system, --merged correctly.
- `argumentParsingModel` — parses --model flag.
- `argumentParsingVocab` — parses --vocab comma-separated list.
- `argumentParsingJsonFlag` — parses --json flag.
- `argumentParsingDefaultValues` — default model and empty vocab when omitted.
- `jsonOutputIsValidTranscriptResult` — `formatResultJSON` produces valid JSON decodable as `TranscriptResult`.
- `jsonOutputUsesISO8601Dates` — JSON date strings match ISO 8601 format.
- `jsonOutputUsesPrettyPrintAndSortedKeys` — formatted output is human-readable with sorted keys.
- `textOutputContainsSpeakerLabels` — `formatResultText` includes speaker labels.
- `textOutputContainsTimestamps` — formatted text includes time ranges.
- `validationRequiresAtLeastOneAudioPath` — validation rejects zero audio paths.

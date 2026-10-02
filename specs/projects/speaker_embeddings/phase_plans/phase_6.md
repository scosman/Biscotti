---
status: complete
---

# Phase 6: CLI, Docs, and Calibration

## Overview

This phase delivers the `voiceprint-cli` developer tool (backfill and metrics
subcommands), updates project documentation to reflect the voiceprint
infrastructure built in Phases 1-5, and provides calibration instructions for the
developer to tune thresholds on real data.

## Steps

1. Add `swift-argument-parser` dependency to `BiscottiKit/Package.swift` and
   create the `voiceprint-cli` executable target with dependencies on `DataStore`,
   `VoiceprintMatching`, and `Transcription`.

2. Create `Sources/voiceprint-cli/VoiceprintCLI.swift` — root
   `AsyncParsableCommand` with `backfill` and `metrics` subcommands.

3. Create `Sources/voiceprint-cli/OutputHelpers.swift` — `OutputWriter` protocol,
   `StandardOutputWriter`, and `AppRunningGuard` (NSWorkspace check for
   `net.scosman.biscotti`).

4. Create `Sources/voiceprint-cli/StoreLocation.swift` — shared `--store` option
   resolution (default `~/Library/Application Support/Biscotti`, validate
   `Biscotti.store` exists).

5. Create `Sources/voiceprint-cli/BackfillCommand.swift` — `backfill` subcommand
   per architecture.md section 9.1: guard, open store, resolve spaces, filter
   candidates, dry-run mode, run SpeakerAnalyzer, map speakers via
   BackfillSpeakerMapper, write voiceprints.

6. Create `Sources/voiceprint-cli/MetricsCommand.swift` — `metrics` subcommand
   per architecture.md section 9.2: guard, open store, evaluate corpus per kind,
   format with MetricsFormatter or JSON output.

7. Update `specs/research/argmax/README.md` — apply sdk_findings.md section 7
   corrections, add PLDA facts and fork info.

8. Update `specs/architecture.md` — add `VoiceprintMatching` module and
   `voiceprint-cli` executable to the topology.

9. Update `specs/implementation_plan.md` — update Project 11 status.

10. Create `specs/projects/speaker_embeddings/calibration.md` — template with
    instructions for the developer's calibration pass.

## Tests

No new automated tests for the CLI itself — the commands are thin wrappers over
already-tested library code (VoiceprintEvaluator, BackfillSpeakerMapper,
MetricsFormatter, DataStore voiceprint queries). The CLI requires a real DataStore
with SpeakerKit models, which cannot run in CI. The library code under
the CLI is fully covered by VoiceprintMatchingTests and DataStoreTests.

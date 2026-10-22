---
status: complete
---

# Phase 2: Prep — StoreReader, Selector, Confirm, BundleBuilder, CLI

## Overview

Build the home-Mac prep pipeline: read the Biscotti store to find eligible meetings, propose a diverse selection, let the user confirm, and build a runner bundle (merged WAV + metadata). Wire it all through a `sttlab` CLI with `select`, `confirm`, and `bundle` subcommands.

## Steps

1. Update `Package.swift`: add argmax (exact 1.0.0), Transcription (path), BiscottiKit (path), ArgumentParser dependencies. Add `STTLabHome` library target (depends on STTLabCore, Transcription, DataStore, WhisperKit). Add `sttlab` executable target (depends on STTLabHome, STTLabAnalysis stub, ArgumentParser). Add `STTLabHomeTests` test target.
2. Create `Sources/STTLabHome/StoreReader.swift`: `CandidateMeeting` struct, `StoreReader.loadCandidates(storeRoot:scratch:log:)` that copies the store files to scratch, opens via `DataStore(.onDisk(...))`, reads meetings via `store.read { s in try s.recentMeetings(limit:) }`, projects to `CandidateMeeting`, filters eligibility.
3. Create `Sources/STTLabHome/Selection.swift`: `Bucket`, `SelectionEntry`, `SelectionFile` types, `Selector.propose(_:short:long:)` with the greedy max-min variety algorithm.
4. Create `Sources/STTLabHome/Confirm.swift`: `Confirm.run(workspace:log:)` that reads selection, assigns mIDs, computes confirmedHash, prints the data-flow notice.
5. Create `Sources/STTLabHome/ConsentGate.swift`: `ConsentGate.require(workspace:)` that checks `confirmed == true` and hash integrity.
6. Create `Sources/STTLabHome/BundleBuilder.swift`: for each confirmed entry, copies AAC to `home/source/<mid>/`, merges with AudioMerger, writes Float32 WAV, meta.json, manifest.json, README.txt.
7. Create `Sources/sttlab/STTLabCLI.swift`: root `AsyncParsableCommand` with `select`, `confirm`, `bundle` subcommands (later phases add more).
8. Create `Sources/sttlab/SelectCommand.swift`, `ConfirmCommand.swift`, `BundleCommand.swift`: thin CLI wrappers that call STTLabHome functions.
9. Create placeholder `Sources/STTLabAnalysis/` with a stub file (needed by the `sttlab` target in later phases; not wired to commands yet).
10. Write `Tests/STTLabHomeTests/`: SelectionTests (bucket fill, shortfall, variety, eligibility), ConfirmTests (hash, ID assignment, rejection on invalid), ConsentGateTests (passes/fails), BundleBuilderTests (meta output for mock merge).

## Tests

- `SelectionTests`: bucket fill counts, shortfall fill with notes, deterministic variety pick, alternates populated, ordering, non-English locale note
- `ConfirmTests`: assigns sequential mIDs, confirmedHash matches recomputation, rejects empty selection, rejects empty appleLocale
- `ConsentGateTests`: passes when confirmed + hash valid, fails when not confirmed, fails when hash mismatches
- `StoreReaderTests`: (limited) eligibility filtering on synthetic CandidateMeeting data — the actual DataStore integration is manual

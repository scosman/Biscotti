---
status: complete
---

# Phase 1: Package scaffold and STTLabCore

## Overview

Set up the `experiments/STTLab/` SPM package with the `STTLabCore` target containing all shared schemas, JSON/WAV/SHA-256 utilities, MemorySampler, MachineInfo, RunLog, ErrorInfo, BundleLoader, and RunnerResume. Wire the package into the Makefile and hooks-mcp so agents can build and test it. No argmax or BiscottiKit dependencies yet (those arrive in later phases).

## Steps

1. Create `experiments/STTLab/Package.swift` with `STTLabCore` library target, `STTLabCoreTests` test target. swift-tools-version 6.0, macOS 15, swiftLanguageModes v6. No external dependencies in this phase.
2. Create `experiments/STTLab/.gitignore` (build artifacts, WAV, AAC, data files).
3. Implement shared schemas in `Sources/STTLabCore/`:
   - `SchemaVersions.swift` (bundle, appleResult version constants; toolVersion)
   - `RunStatus.swift` (completed/failed/unsupportedLocale enum)
   - `TimeSpan.swift` (TimedRun struct with start/end/wallSeconds)
   - `BundleManifest.swift` (manifest schema)
   - `MeetingMeta.swift` (per-meeting metadata schema)
   - `MachineInfo.swift` (hardware/OS info, `current()` via sysctl)
   - `MemoryReport.swift` (process/system memory report schemas)
   - `ErrorInfo.swift` (Error -> Codable bridge)
   - `AppleMeetingResult.swift` (runner result schemas: AppleMeetingResult, AppleConfig, AssetEvent, CMTimeValue, AppleResult, AppleRun, AppleAlternative, RunnerSession, RunFile)
   - `RunnerResume.swift` (shouldRun decision logic)
   - `BundleLoader.swift` (LoadedBundle, validate manifest + files)
4. Implement utilities in `Sources/STTLabCore/`:
   - `JSONFiles.swift` (atomic write via temp + rename, typed read)
   - `WAVFile.swift` (writeFloat32Mono16k, readFloat32Mono, int16WAVData)
   - `SHA256File.swift` (streaming hex digest)
   - `MemorySampler.swift` (actor: periodic phys_footprint + system speech process sampling)
   - `RunLog.swift` (timestamped append to file + stdout/observer)
5. Add `EXPERIMENT_PACKAGES` to Makefile; extend build/test/clean for local-only experiment packages.
6. Add `build_sttlab` and `test_sttlab` actions to hooks_mcp.yaml.
7. Write `STTLabCoreTests`:
   - JSON round-trip for every schema type
   - WAVFile write-then-read bit-exactness
   - int16WAVData header correctness and sample clamping
   - SHA256File on a known file
   - MemorySampler returns non-zero footprint
   - ErrorInfo from an NSError
   - RunnerResume.shouldRun all cases
   - BundleLoader: valid bundle, schema mismatch, missing WAV

## Tests

- `SchemaRoundTripTests`: JSON encode-decode of BundleManifest, MeetingMeta, MachineInfo, MemoryReport, ErrorInfo, AppleMeetingResult, RunnerSession, RunFile, TimedRun
- `WAVFileTests`: writeFloat32Mono16k then readFloat32Mono is bit-exact; int16WAVData has correct 44-byte RIFF header, correct sample count, clamped samples
- `SHA256FileTests`: hex digest of a known-content temp file matches expected
- `MemorySamplerTests`: start/stop returns MemoryReport with non-zero processPeakFootprintBytes
- `ErrorInfoTests`: init from NSError preserves domain, code, description
- `RunnerResumeTests`: shouldRun returns true for nil/force/failed, false for completed/unsupportedLocale
- `BundleLoaderTests`: loads valid temp bundle; rejects wrong schema version; rejects missing audio file

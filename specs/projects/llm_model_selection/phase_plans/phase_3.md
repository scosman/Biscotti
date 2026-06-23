---
status: complete
---

# Phase 3: Hardware + suitability (pure, additive)

## Overview

Add hardware probing and model suitability logic to the Intelligence module. This is
pure/additive -- no existing APIs change, no breaking changes. Three new files:

1. `HardwareProbing.swift` -- protocol + `LiveHardwareProbe` for RAM and free disk reads.
2. `ModelPolicy.swift` -- per-model-id product policy: RAM floor, UI description copy, RAM-usage copy.
3. `ModelSuitability.swift` -- pure functions: `canRun`, `recommendedModelID`, `hasEnoughDisk`.

All suitability logic is unit-testable via a fake `HardwareProbing` conformer.

## Steps

1. Create `Packages/BiscottiKit/Sources/Intelligence/HardwareProbing.swift`:
   - `public protocol HardwareProbing: Sendable` with `physicalMemoryBytes: UInt64` and
     `func availableDiskBytes(at url: URL) -> Int64?`.
   - `public struct LiveHardwareProbe: HardwareProbing` using `ProcessInfo.processInfo.physicalMemory`
     and `URL.resourceValues(forKeys:).volumeAvailableCapacityForImportantUsage`.

2. Create `Packages/BiscottiKit/Sources/Intelligence/ModelPolicy.swift`:
   - `public enum ModelPolicy` with static functions:
     - `description(id:) -> String` -- UI marketing copy per functional spec section 2.
     - `minRAMBytesToRun(id:) -> UInt64` -- 12B: 15 GB; everything else: 0.
     - `approxRAMUsageDescription(id:) -> String` -- "8 GB" for 12B, "4 GB" for E2B, etc.
   - Named constants for the thresholds: `ramFloor12B = 15_000_000_000`,
     `recommendationRAMThreshold = 24_000_000_000`.

3. Create `Packages/BiscottiKit/Sources/Intelligence/ModelSuitability.swift`:
   - `public enum ModelSuitability` with static functions:
     - `canRun(_ model: LLMModel, ram: UInt64) -> Bool`
     - `recommendedModelID(catalog: [LLMModel], ram: UInt64) -> String?`
     - `hasEnoughDisk(_ model: LLMModel, freeBytes: Int64?) -> Bool`

4. Write table-driven tests in a new `ModelSuitabilityTests.swift` in IntelligenceTests.

## Tests

- `canRun_12B_at_various_RAM`: 8 GB -> false, 14 GB -> false, 15 GB -> true, 16 GB -> true, 24 GB -> true, 64 GB -> true
- `canRun_E2B_always_true`: 8 GB, 16 GB, 64 GB -> all true
- `recommendedModelID_below_24GB`: returns "gemma-4-e2b"
- `recommendedModelID_at_24GB`: returns "gemma-4-12b"
- `recommendedModelID_above_24GB`: returns "gemma-4-12b"
- `recommendedModelID_never_non_runnable`: verify cannot recommend a model that fails canRun
- `hasEnoughDisk_nil_freeBytes_returns_true`: never block on unknown
- `hasEnoughDisk_boundaries`: exact size -> true, one byte below -> false, well above -> true
- `ModelPolicy.description_known_ids`: non-empty for both known IDs
- `ModelPolicy.minRAMBytesToRun_12B_vs_E2B`: 12B has floor, E2B is 0

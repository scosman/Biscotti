---
status: complete
---

# Phase 2: DataStore `selectedModelID`

## Overview

Add the persisted `selectedModelID: String = ""` field to the DataStore settings layer. This is the
single new setting that later phases (ModelManager, selection logic) will read and write. The field
follows the exact same pattern as `aiAnalysisEnabled` -- a stored property on the SwiftData `@Model`,
a matching field on the `Sendable` DTO, and mapping in both `settings()` and `updateSettings()`.

## Steps

1. **`AppSettings.swift`** -- add `public var selectedModelID: String = ""` stored property and a
   corresponding `selectedModelID: String = ""` parameter in `init(...)`.

2. **`DataStore+ReadModels.swift` (`AppSettingsData`)** -- add `public var selectedModelID: String`
   field with default `""` in the DTO struct and its `init`.

3. **`DataStore+ReadModels.swift` (`settings()`)** -- map `existing.selectedModelID` into the
   `AppSettingsData` initializer call.

4. **`DataStore+ReadModels.swift` (`updateSettings()`)** -- map the field in both directions:
   read `model.selectedModelID` into the DTO, and write `dto.selectedModelID` back to `model`.

5. **`SettingsAndQueryTests.swift`** -- add a test that verifies the default is `""` and a
   round-trip through `updateSettings` persists and reads back a non-empty value.

## Tests

- `selectedModelIDDefaultsToEmpty`: read settings from a fresh store, assert
  `selectedModelID == ""`.
- `selectedModelIDRoundTrip`: write `"gemma-4-e2b"` via `updateSettings`, read back, assert equal.

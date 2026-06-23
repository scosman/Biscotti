---
status: complete
---

# Phase 1: Extract `ModelManagementUI` (pure refactor, no behavior change)

## Overview

Move the Manage Models sheet out of `SettingsUI` into a new shared `ModelManagementUI` module so
both `SettingsUI` and `OnboardingUI` can present it. This is a mechanical move with no behavior
change -- Settings presents the identical sheet afterward.

## Steps

1. **Create `Sources/ModelManagementUI/ManageModelsSheet.swift`**: Copy the file from
   `Sources/SettingsUI/ManageModelsSheet.swift`. Make `ManageModelsSheet` `public` with a
   `public init`. `ManageModelsViewModel` is already `public`. `ModelRowView` and
   `ModelBlockedReason.warningText` stay internal to the new module.

2. **Create `Tests/ModelManagementUITests/ManageModelsViewModelTests.swift`**: Copy from
   `Tests/SettingsUITests/ManageModelsViewModelTests.swift`. Replace `@testable import SettingsUI`
   with `import ModelManagementUI`. The `ModelBlockedReasonTests` suite also moves (it tests
   `warningText` which is internal, so it needs `@testable import ModelManagementUI`).

3. **Update `Package.swift`**: Add `ModelManagementUI` library product + target (deps: `AppCore`,
   `DesignSystem`, `Intelligence`, `.product(name: "LocalLLM", package: "LocalLLM")`). Add
   `ModelManagementUITests` test target (deps: `ModelManagementUI`, `AppCore`,
   `BiscottiTestSupport`, `Intelligence`, `.product(name: "LocalLLM", package: "LocalLLM")`).
   Add `"ModelManagementUI"` to `SettingsUI`'s dependencies.

4. **Update `Sources/SettingsUI/SettingsView.swift`**: Add `import ModelManagementUI`.

5. **Delete `Sources/SettingsUI/ManageModelsSheet.swift`**: The original file is now in
   `ModelManagementUI`.

6. **Delete `Tests/SettingsUITests/ManageModelsViewModelTests.swift`**: The tests are now in
   `ModelManagementUITests`.

7. **Update `architecture.md`**: Add `ModelManagementUI` to the L3a Screens layer in the DAG.

## Tests

- **Existing `ManageModelsViewModelTests`** (moved): all tests continue to pass unchanged,
  verifying the extraction preserved behavior.
- **Existing `SettingsUITests`** (not moved): continue to pass, verifying `SettingsView` still
  compiles and uses the sheet through the new module.

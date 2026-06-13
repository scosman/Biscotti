---
status: complete
---

# Phase 9: Settings (standard macOS Settings menu item)

## Overview

Add the standard macOS "Settings..." menu item (Cmd+,) by declaring a `Settings` scene in `BiscottiApp.swift`, and reconcile the existing sidebar Settings row to open the same system settings window instead of routing to the in-window `.settings` route.

## Steps

1. **Add a `Settings` scene** to `BiscottiApp.body` that hosts the existing `SettingsView` from `SettingsUI`. Create a `SettingsRootView` (same pattern as `WindowRootView`) that reads `LaunchState` inside its `body` for reliable Observation tracking and creates a `SettingsViewModel` from the core.

2. **Modify `AppShellView`** to open the system settings window from the sidebar Settings row instead of calling `viewModel.showSettings()`. Use `@Environment(\.openSettings)` (macOS 14+) to trigger the system settings window. Remove the in-app `.settings` route handling from `detailContent`.

3. **Remove the `.settings` route** from `Route` enum and the `showSettings()` method from `AppCore`. Update `AppShellViewModel` to remove `showSettings()`. Clean up any remaining references.

4. **Run precommit checks and build_app** to verify everything compiles and passes.

## Tests

- NA: This is a pure UI/scene change with no new view-model logic. The existing `SettingsViewModel` and its tests are unchanged. The route removal is mechanical and covered by compilation.

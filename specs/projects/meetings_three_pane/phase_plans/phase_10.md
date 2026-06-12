---
status: complete
---

# Phase 10: Settings — restore in-window tab

## Overview

Revert the Phase-9 change that moved Settings into a separate macOS `Settings` scene/window. Settings should render inside the primary window as a route (like Home, Meetings, etc.), navigated from the sidebar Settings row. Remove the `Settings` scene, `SettingsRootView`, and the app-target `settingsViewModel` wiring that existed only to host it. Restore `Route.settings`, `AppCore.showSettings()`, `AppShellViewModel.settingsViewModel`/`showSettings()`, and the sidebar active-state highlight + detail-pane rendering for `.settings`.

P2: Add a custom `CommandGroup(replacing: .appSettings)` menu command bound to Cmd+, that navigates the main window to the settings tab via `AppCore.showSettings()`.

## Steps

1. **Route.swift** — Add back `case settings` (in-window settings) to the `Route` enum.

2. **AppCore.swift** — Add back `showSettings()` method that sets `route = .settings`.

3. **Package.swift** — Re-add `"SettingsUI"` to the `AppShellUI` target's dependencies list.

4. **AppShellViewModel.swift** — Import `SettingsUI`. Add back `settingsViewModel: SettingsViewModel` (created once in init). Add back `showSettings()` method.

5. **AppShellView.swift** — Import `SettingsUI`. Remove `@Environment(\.openSettings)`. Restore `settingsRow` to call `viewModel.showSettings()` with active-state highlight when `route == .settings`. Add `.settings` case to `detailContent` rendering `SettingsView(viewModel: viewModel.settingsViewModel)`.

6. **SettingsView.swift** — Restore doc comment to say "In-window settings screen" instead of "Hosted in the standard macOS Settings window".

7. **BiscottiApp.swift** — Remove the `Settings { SettingsRootView(...) }` scene. Remove the `SettingsRootView` struct. Remove `settingsViewModel` from `LaunchState`. Remove `import SettingsUI`. Remove `launchState.settingsViewModel = SettingsViewModel(core: appCore)` from `buildCore()`.

8. **App/project.yml** — Remove the `SettingsUI` product dependency from the app target (it's now pulled in transitively via `AppShellUI`).

9. **P2: Cmd+, menu command** — In BiscottiApp.swift, add `.commands { CommandGroup(replacing: .appSettings) { Button("Settings...") { ... }.keyboardShortcut(",", modifiers: .command) } }` on the Window scene that triggers `showSettings()` on the running core via LaunchState.

10. **Tests** — Restore the tests that the original commit removed: `showSettings` routing test in AppCoreTests, `settingsViewModel` stability test + `showSettings` routing test in AppShellViewModelTests, and revert the test helpers in MenuBarViewModelTests back to using `showSettings()`.

## Tests

- `AppCoreCalendarNavigationTests.showHomeShowSettingsRouting` — verifies `showSettings()` sets route to `.settings` and `showHome()` returns to `.home`.
- `AppShellChildVMTests.settingsVMStable` — verifies `settingsViewModel` is the same instance across accesses.
- `AppShellUpcomingSearchTests.showSettingsRoutesToSettings` — verifies `showSettings()` on the shell VM routes to `.settings`.
- `MenuBarNavigationTests.openAppHomeRoute` — uses `showSettings()` to set a non-home initial route (restoring the original test pattern).
- `AppCoreTests.onLaunchIdempotent` — uses `showSettings()` to navigate away from home before second launch call (restoring original pattern).

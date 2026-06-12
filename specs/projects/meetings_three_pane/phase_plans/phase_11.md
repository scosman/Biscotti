---
status: complete
---

# Phase 11: App lifecycle -- Cmd+Q closes window + "Exit app on window close" setting

## Overview

Biscotti is a menu-bar/tray app that should stay alive by default when the user
closes the window or presses Cmd+Q. This phase adds:

1. A persisted `exitOnWindowClose` boolean setting (default `false`) to
   `AppSettings` / `AppSettingsData`.
2. A toggle row in the in-window `SettingsView` for "Exit app on window close".
3. `SettingsViewModel` plumbing: read/write + unit tests.
4. App-target lifecycle behavior:
   - **Cmd+Q override** via `CommandGroup(replacing: .appTermination)` -- when the
     setting is false, Cmd+Q closes/hides the main window (app stays alive in
     the menu bar); when true, it terminates.
   - **Window red-close button** -- `applicationShouldTerminateAfterLastWindowClosed`
     reads the setting; when false the app stays alive, when true it terminates.
   - **Tray Quit** -- the existing "Quit" in `MenuBarContentView` always calls
     `NSApp.terminate(nil)` and remains unchanged.

## Steps

1. **DataStore model** -- Add `exitOnWindowClose` (Bool, default `false`) to
   `AppSettings` (`@Model`) and `AppSettingsData` (DTO). Wire through
   `settings()` and `updateSettings(_:)` in `DataStore+ReadModels.swift`.

2. **SettingsViewModel** -- Add `exitOnWindowClose` property + `setExitOnWindowClose(_:)`
   action that persists via `core.store.updateSettings`. Load initial value in `load()`.

3. **SettingsView** -- Add a toggle row "Exit app on window close" in the
   General section, below "Launch at login". Include a small footnote explaining
   the behavior.

4. **BiscottiApp.swift lifecycle** --
   a. Make `applicationShouldTerminateAfterLastWindowClosed` read the persisted
      setting from `core.store` (async fetch cached in a local bool, reloaded
      when the setting changes).
   b. Add `CommandGroup(replacing: .appTermination)` with a custom Cmd+Q that,
      when exitOnWindowClose is false, closes the main window (keeps app alive),
      and when true calls `NSApp.terminate(nil)`.
   c. Wire a mechanism for the AppDelegate to know the current setting value
      (cache it on AppDelegate, refresh on settings change).

5. **Unit tests** -- Add tests in `SettingsViewModelTests` for:
   - default `exitOnWindowClose` is false
   - toggling persists and reads back

## Tests

- `exitOnWindowCloseDefaultsFalse` -- verifies new VM starts with `exitOnWindowClose == false`
- `toggleExitOnWindowClosePersists` -- toggles the setting on, verifies persisted, toggles back off
- `exitOnWindowCloseLoadedFromStore` -- pre-sets the setting in the store and verifies `load()` picks it up
- DataStore-level: `exitOnWindowClose` included in existing settings round-trip test

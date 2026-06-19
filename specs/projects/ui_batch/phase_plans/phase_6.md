---
status: complete
---

# Phase 6: Global hotkey (Cmd+Shift+R) + settings toggle

## Overview

Add an OS-wide keyboard shortcut (Cmd+Shift+R) that starts a Biscotti recording from any app, plus a Settings toggle to enable/disable it. Uses Carbon `RegisterEventHotKey` (no third-party dependency, no extra permissions). The hotkey wrapper lives in the App target (Apple glue); the setting lives in `DataStore/AppSettings` (testable package).

## Steps

1. **Add `globalRecordShortcutEnabled` to `AppSettings`** (`Packages/BiscottiKit/Sources/DataStore/Models/AppSettings.swift`):
   - Add `public var globalRecordShortcutEnabled: Bool = true` stored property.
   - Add to the `init(...)` parameter list with default `true`.

2. **Add `globalRecordShortcutDidChange` notification name** (`Packages/BiscottiKit/Sources/AppCore/AppCore.swift`):
   - Add `static let globalRecordShortcutDidChange` to the existing `Notification.Name` extension, following the `exitOnWindowCloseDidChange` / `menuBarLeadTimeDidChange` pattern.

3. **Add SettingsViewModel support** (`Packages/BiscottiKit/Sources/SettingsUI/SettingsViewModel.swift`):
   - Add `public private(set) var globalRecordShortcutEnabled: Bool = true` observable property.
   - Add `public func setGlobalRecordShortcut(_ enabled: Bool) async` that updates the property, persists via `core.store.updateSettings`, posts `.globalRecordShortcutDidChange`, and reverts on failure. Follows the `setExitOnWindowClose` pattern exactly.
   - Load the setting in `load()`.

4. **Add Settings UI toggle** (`Packages/BiscottiKit/Sources/SettingsUI/SettingsView.swift`):
   - Add a toggle in the General section: `Toggle("Global shortcut to start recording (\u{2318}\u{21E7}R)", isOn: globalRecordShortcutBinding)`.
   - Add the `globalRecordShortcutBinding` computed property following the `exitOnWindowCloseBinding` pattern.

5. **Create `GlobalHotKey` Carbon wrapper** (`App/Sources/GlobalHotKey.swift`, new file in the App target):
   - A `@MainActor final class GlobalHotKey` that wraps Carbon's `RegisterEventHotKey` / `UnregisterEventHotKey` / `InstallEventHandler`.
   - `init(keyCode:modifiers:handler:)` stores the callback, does not auto-register.
   - `func register()` installs the Carbon event handler (idempotent), registers the hotkey, and inserts `self` into a `@MainActor`-isolated static map so the C callback can route events.
   - `func unregister()` unregisters the hotkey, removes the handler, and removes `self` from the static map. Must be called before dropping the instance.
   - **No `deinit`:** deliberate. While the hotkey is registered, the static `activeHotKeys` map holds a strong reference to the instance, so `deinit` would be unreachable. Once `unregister()` is called, the instance is removed from the map with nothing left to clean up. A `deinit` would be dead code. Callers (AppDelegate) are responsible for calling `unregister()` before releasing the instance.
   - The Carbon event handler dispatches to the stored Swift callback on the main actor; the `activeHotKeys` lookup happens inside `MainActor.assumeIsolated` so the compiler enforces isolation.

6. **Wire hotkey in `AppDelegate`** (`App/Sources/BiscottiApp.swift`):
   - Add a `private var globalRecordHotKey: GlobalHotKey?` property.
   - In `buildCore()`, after core is built, read the setting and register if enabled.
   - Add `observeGlobalRecordShortcutSetting()` (following the `observeExitOnWindowCloseSetting` pattern) to register/unregister on notification.
   - The hotkey callback calls `core?.startRecording()` (which already guards against double-start).

## Tests

- **`testGlobalRecordShortcutEnabledDefaultTrue`**: Verify `AppSettings` defaults `globalRecordShortcutEnabled` to `true`.
- **`testToggleGlobalRecordShortcutPersists`**: Toggle via SettingsViewModel, verify persisted to store.
- **`testLoadReadsGlobalRecordShortcutFromStore`**: Pre-set in store, verify `load()` reads it.
- **`testSetGlobalRecordShortcutPostsNotification`**: Verify the notification is posted on toggle.

The Carbon `GlobalHotKey` wrapper lives in the App target and cannot be unit-tested via `swift test`; it is verified by `build_app` compiling successfully.

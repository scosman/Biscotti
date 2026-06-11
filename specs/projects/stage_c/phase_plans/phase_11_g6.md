---
status: draft
---

# Phase 11 G6: App lifecycle / Menu bar / Dock

## Overview

Reworks the MenuBarExtra from `.window` (popover) to `.menu` (native menu items), fixes the
window-reopen-wipes-content bug by making AppCore a single persistent instance owned by the
AppDelegate (not per-window `@State`), implements robust window show/activate via AppDelegate,
adds dock-icon activation-policy switching (`.accessory` when no windows, `.regular` when a
window opens), removes "See All", and makes menu items navigate to events/meetings.

## Root cause analysis: window-reopen wipes content (item 5)

`BiscottiApp.body` holds `@State private var core: AppCore?` and `@State private var
shellViewModel: AppShellViewModel?`. When the window is closed (and don't-quit-on-close keeps
the app alive), SwiftUI tears down the `WindowGroup` body state. When a new window opens, the
body re-evaluates and `core`/`shellViewModel` are `nil` (state is fresh). `buildCore()` runs
again in `.task`, creating a BRAND NEW `AppCore` -- empty store, no loaded summaries.

**Fix:** Move `AppCore` ownership to `AppDelegate` (process-lifetime). The `buildCore()` call
happens once in `applicationDidFinishLaunching`. `BiscottiApp.body` reads the already-built
core from `appDelegate` and creates view models on demand, but the underlying `AppCore` is
always the same instance. View models that depend on AppCore can be recreated (they are
lightweight projections) because AppCore retains all state.

## Steps

### 1. Move AppCore to AppDelegate (item 5 fix)

- `AppDelegate` gains `var core: AppCore?` (already exists) -- make it the SOLE owner.
- Add `var shellViewModel: AppShellViewModel?` and `var menuBarViewModel: MenuBarViewModel?`
  to AppDelegate, lazily created from `core`.
- `buildCore()` moves to `applicationDidFinishLaunching`, runs once.
- `BiscottiApp.body` reads `appDelegate.core`, `appDelegate.shellViewModel`, etc.
  No more `@State private var core: AppCore?`.

### 2. Window lifecycle management (items 4, 6)

- AppDelegate tracks window open/close state.
- `applicationDidFinishLaunching`: set `NSApp.setActivationPolicy(.regular)`.
- On window close (not quit): `NSApp.setActivationPolicy(.accessory)`.
- On window reopen (menu bar "Open", Dock click, `applicationShouldHandleReopen`):
  set `.regular`, ensure window is shown, `NSApp.activate`.
- `applicationShouldHandleReopen` returns `true` and calls the window-open helper.

### 3. MenuBarExtra: switch to `.menu` style (item 1)

- Change `.menuBarExtraStyle(.window)` to `.menuBarExtraStyle(.menu)`.
- Replace `MenuBarContentView` (a SwiftUI `VStack`) with menu-compatible content:
  recording state, upcoming items, recent items, Open Biscotti, Quit -- all as `Button`s
  in the native menu.
- `MenuBarLabelView` stays as the label (icon + optional text).

### 4. Menu item navigation (item 2)

- Upcoming event rows: `Button(event.title)` that calls `viewModel.openEvent(event.id)`.
- Recent meeting rows: `Button(meeting.title)` that calls `viewModel.openApp(meetingID:)`.
- Both also activate the app and bring the window to the front.
- Add `openEvent(_:)` to `MenuBarViewModel` that calls `core.selectEvent(key)` + activate.

### 5. Remove "See All" (item 3)

- Delete the `seeAll()` method from `MenuBarViewModel`.
- Delete the "See all..." button from `MenuBarContentView`.
- Add `// TODO(see-all): add a 'See All' menu entry once a full upcoming/recent list page exists`.

### 6. Window show/activate helper (item 4)

- `AppDelegate` exposes `func showMainWindow()` that:
  - Sets activation policy to `.regular`
  - Creates/shows the window if needed (via `NSApp.activate`, `makeKeyAndOrderFront`)
  - Called from menu bar "Open Biscotti", dock click, notification actions.
- `MenuBarViewModel.openApp()` calls through to the AppDelegate's method.

## Tests

- `menuBarOpenEventNavigatesAndActivates`: verify `openEvent(key)` sets route to `.event(key)`.
- `menuBarOpenMeetingNavigatesAndActivates`: verify `openApp(meetingID:)` sets route to `.meeting(id)`.
- `menuBarSeeAllRemoved`: verify `MenuBarViewModel` no longer has `seeAll()` method (compile-time).
- Existing formatting/icon-state tests remain unchanged.

Window management (activation policy, `makeKeyAndOrderFront`) is AppKit glue -- not
unit-testable headlessly. Verified via `build_app` and manual reasoning.

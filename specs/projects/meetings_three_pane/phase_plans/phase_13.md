---
status: complete
---

# Phase 13: Top-bar & list polish

## Overview

Four targeted polish items from the human review round 3 feedback: remove
the "Biscotti" window title that still renders despite `titleVisibility =
.hidden`; wire Cmd+F to focus the search field app-wide; disable the
toolbar Home button when already on Home; vertically center the "No
results" empty state in the meetings list pane.

## Steps

### 1. Remove "Biscotti" title from the top bar

**Root cause:** `Window("Biscotti", id: "main")` sets the window's
`title` property to "Biscotti". `titleVisibility = .hidden` hides the
*title bar label* in a standard titlebar, but in a `.unified` toolbar
layout (which `NavigationSplitView` triggers), the window title is still
rendered inside the toolbar area. The fix is twofold: (a) change the
`Window` initializer to use an empty string `Window("", id: "main")` so
the underlying `NSWindow.title` is empty; (b) keep the existing
`WindowTitleHider` setting `titleVisibility = .hidden` as defense-in-depth
so no label area takes space.

- **File:** `App/Sources/BiscottiApp.swift`
- Change `Window("Biscotti", id: "main")` to `Window("", id: "main")`.
- Also set `window.title = ""` in `TitleHiderView.viewDidMoveToWindow()`
  and in `updateNSView` for belt-and-suspenders robustness.

### 2. Cmd+F focuses the search field

- **File:** `Packages/BiscottiKit/Sources/AppCore/AppCore.swift`
  - Add a published `searchFocusToken: UInt` property (incremented to
    signal focus requests). Add a `focusSearch()` method that increments
    it and routes to `.meetings` if not already on a screen with the search
    field (actually the search field is always present in the toolbar, so
    just increment).

- **File:** `Packages/BiscottiKit/Sources/AppShellUI/AppShellViewModel.swift`
  - Expose `searchFocusToken` passthrough from core.
  - Add `focusSearch()` passthrough.

- **File:** `Packages/BiscottiKit/Sources/AppShellUI/AppShellView.swift`
  - Add `@FocusState private var isSearchFocused: Bool` on the search
    `TextField`.
  - Apply `.focused($isSearchFocused)` to the search `TextField`.
  - Add `.onChange(of: viewModel.searchFocusToken)` that sets
    `isSearchFocused = true`.

- **File:** `App/Sources/BiscottiApp.swift`
  - Add a `CommandGroup(replacing: .textEditing)` or `CommandMenu("Find")`
    with a "Find..." menu item bound to Cmd+F that calls
    `appDelegate.core?.focusSearch()`.

### 3. Home toolbar button disabled when on Home

- **File:** `Packages/BiscottiKit/Sources/AppShellUI/AppShellViewModel.swift`
  - Add computed `isHome: Bool` → `core.route == .home`.

- **File:** `Packages/BiscottiKit/Sources/AppShellUI/AppShellView.swift`
  - Add `.disabled(viewModel.isHome)` to the Home toolbar button.

### 4. "No results for X" vertically centered

- **File:** `Packages/BiscottiKit/Sources/MeetingListUI/MeetingListView.swift`
  - In both browse and search modes, when the empty state should show,
    render the `ContentUnavailableView` OUTSIDE the `List` (not as a list
    row). Use an `if/else` at the top level of `body`: if in the empty
    state, show the `ContentUnavailableView` with
    `.frame(maxWidth: .infinity, maxHeight: .infinity)` so it fills the
    pane; else show the `List` with content.

## Tests

- `isHome returns true when route is .home` (AppShellViewModelTests)
- `isHome returns false when route is not .home` (AppShellViewModelTests)
- `searchFocusToken increments on focusSearch` (AppShellViewModelTests /
  AppCoreTests)
- `focusSearch passthrough increments token` (AppShellViewModelTests)

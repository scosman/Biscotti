---
status: complete
---

# Phase 3: Chrome, Extras & Docs

## Overview

Adds the remaining UI chrome (toolbar Home button, hidden window title, Home "See all" row),
updates the repo-root `architecture.md` to reflect the SearchUI removal and MeetingListUI rewrite,
and fills in the `review_for_human.md` autonomous-calls log. This is the final build phase before
the human on-device verification (Phase 4).

## Steps

1. **Add toolbar Home button to `AppShellView`.**
   Add a `ToolbarItem(placement: .navigation)` containing a `Button` with `Image(systemName: "house")`
   that calls `viewModel.showHome()`. Place it on the `NavigationSplitView` (inside the non-onboarding
   branch), alongside the existing `.searchable` modifier. Add `.help("Home")` for accessibility.

2. **Hide the window title in the app target (`BiscottiApp.swift`).**
   In the `showMainWindow()` method of `AppDelegate`, after obtaining the main window reference,
   set `window.titleVisibility = .hidden`. This removes the "Biscotti" title text from the toolbar
   while keeping the toolbar, traffic lights, and draggable title bar. The `Window("Biscotti", id:
   "main")` scene title stays (drives the macOS Window menu / app name). This is app-target code
   that cannot be unit-tested; it will be verified on-device in Phase 4.

3. **Add "See all" row to `HomeView`'s Recent Meetings section.**
   Add a `showMeetings()` action to `HomeViewModel` (delegates to `core.showMeetings()`).
   In `HomeView.recentSection`, after the meeting rows (and only when there ARE meetings -- hidden
   when `showNoRecent` is true), add a full-width plain button styled with a trailing chevron:
   `"See all"` + `Image(systemName: "chevron.right")`. Tapping routes to the Meetings screen
   in browse mode.

4. **Update repo-root `architecture.md`.**
   - Rewrite component #19 (MeetingListUI): update description to reflect its new role as the
     dedicated Meetings-screen list with grouped past meetings, in-place search results, and
     native `List(selection:)`.
   - Delete component #20 (SearchUI) entirely.
   - In the dependency graph: remove `SRCH[SearchUI]`, remove `SHELL --> ... & SRCH`, and update
     the L3a screens line to drop `SearchUI`.

5. **Fill in `review_for_human.md` "Autonomous calls made during development" section.**
   Document the autonomous decisions made across all three build phases.

## Tests

- `HomeViewModel.showMeetings` routes to `.meetings` (unit test in `HomeViewModelTests`)
- `HomeViewModel.showSeeAll` is hidden when no meetings exist (implicit via `showNoRecent`)
- Toolbar Home button and window title hiding are app-tier/visual -- verified on device in Phase 4
- Architecture doc edits are prose-only, no code tests needed

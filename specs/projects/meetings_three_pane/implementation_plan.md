---
status: complete
---

# Implementation Plan: Meetings — 3-Pane Layout

Dependency-ordered phases. **Built autonomously** — each phase runs as: coding agent (writes a
`phase_plans/phase_N.md`, implements, adds tests) → green `precommit_checks` (lint + test) →
spec-aware code review → commit. **No human stop between build phases.** The **final phase is the
human review + on-device verification** pass. Details live in `functional_spec.md`, `ui_design.md`,
`architecture.md`, and `review_for_human.md` (D1–D9); this file is the ordered checklist.

**Each build phase must end green** (`make ci`: lint + test + build). Where the route swap would
otherwise break the build, Phase 1 carries minimal interim UI that Phase 2 finalizes (called out
below). **Manual-test staleness:** this project touches only UI modules + `AppCore` (not
`Packages/AudioCapture` / `Packages/Transcription`), so the `ac_*`/`tx_*` staleness rule is **not**
triggered — `manual_test_results.json` is untouched.

## Phases

- [x] **Phase 1 — `AppCore` Meetings state machine + `DataStore` (the logic core).**
  `Route` → `.meetings` (remove `.meeting(UUID)` / `.search`); add `meetingsSelection` / `meetingsQuery`
  / `meetingsResults` / `isSearchingMeetings`; `select` / `selectFromList` / `showMeetings` /
  `setMeetingsQuery` (debounced via the `scheduler` seam) / `autoSelectTopResult` / `neighborID` +
  select-next; update `stopRecording` (→ `select`) and `deleteMeeting` (→ select-next); remove
  `presentSearch` / `dismissSearch` / `searchReturnRoute`. `DataStore.meetingSummaries(limit: Int? =
  nil)` + uncapped load in `AppCore`. **Bulk of the unit tests here** (state transitions, debounced
  search, `neighborID`, select-next in browse & search order, `meetingSummaries`). *Interim to stay
  green:* `AppShellView` renders `.meetings` as a basic `HSplitView` reusing the current list rendering
  + a flat results list + placeholder, search field re-pointed at `core.meetingsQuery`; `SearchUI`
  left unreferenced (removed in Phase 2). → `architecture.md` §1–§3, §2.
  *(Depends on: nothing.)*

- [x] **Phase 2 — Meetings two-pane UI: native `List`, date grouping, search mode; remove `SearchUI`.**
  Convert `MeetingListView` to native `List(selection:)` with pinned `Section` headers; add the
  6-bucket `groupByDateBuckets` (+ boundary/order-invariant tests) replacing the 4-bucket grouping;
  render search mode (flat results) and the `ContentUnavailableView` placeholder / empty / no-results
  states; finalize `HSplitView` pane min/ideal/max widths + window min width; sidebar "Past Meetings"
  row styling + active state. **Remove the `SearchUI` module** (`SearchView` / `SearchViewModel` /
  `SearchUITests` + `Package.swift` targets) and any remaining legacy AppShell code; migrate the useful
  `SearchViewModelTests` assertions into the Phase 1 AppCore search tests. → `ui_design.md` §3–§5,
  `architecture.md` §4–§5, §7.
  *(Depends on: Phase 1.)*

- [x] **Phase 3 — Chrome, extras & docs.** Toolbar **Home** button (`ToolbarItem(.navigation)`); hide
  the window **title** (`NSWindow.titleVisibility = .hidden` in the app target); Home **"See all"** row
  at the bottom of Recent Meetings. **`specs/architecture.md` doc edits** (rewrite #19
  *MeetingListUI*; delete #20 *SearchUI*; drop `SRCH` from the dependency graph). Fill in
  `review_for_human.md` → "Autonomous calls made during development". → `ui_design.md` §6, §8,
  `architecture.md` §0, §6.
  *(Depends on: Phase 2.)*

- [ ] **Phase 4 — Human review + on-device verification.** Run the app on Apple-silicon hardware and
  verify the `architecture.md` §8 checklist: `.inset` `List` pins section headers; window title hidden
  while toolbar/Home button remain; `HSplitView` divider drag + no detail clipping; `List(selection:)`
  ↑/↓ keyboard nav drives the detail pane; search → auto-render top result; Past Meetings / See all /
  delete-select-next flows. Review the `review_for_human.md` autonomous-calls log; fix bugs.
  *(Depends on: Phase 3. **Human-run.**)*

## Round 2 — Review feedback

- [x] **Phase 5 — AppCore behavior.** Search auto-selects the TOP result on load (not the previously-seen selection); allow up to 6 upcoming meetings. + unit tests.
- [x] **Phase 6 — Top app bar & record relocation.** Remove app name from the bar; add a Record button on the right next to search; search field ~60% width with placeholder "Search"; remove the record button from the sidebar.
- [x] **Phase 7 — Sidebar upcoming cells.** Full-width clickable cells; meeting-type badge right-aligned.
- [x] **Phase 8 — Right pane & layout.** Default column widths (meetings-list column = sidebar's current width; sidebar = 50% of its current width); fix the empty-detail offset bug (right pane only ~20% tall when "No meeting selected"); move Delete-meeting button to above the transcript.
- [x] **Phase 9 — Settings.** Standard macOS Settings… under the app-name menu (Cmd+,) launching a settings page (placeholder/stub content).

## Round 3 — Review feedback

- [x] **Phase 10 — Settings: restore in-window tab.** Revert the Phase-9 Settings-window change: settings render INSIDE the primary window again (restore Route.settings + showSettings(); sidebar row + detail render SettingsView in-window); remove the macOS `Settings` scene. P2: a custom Cmd+, menu command that navigates the main window to the settings tab.
- [x] **Phase 11 — App lifecycle: Cmd+Q + exit setting.** Cmd+Q and window-close close the window but keep the menu-bar/tray app alive; add persisted setting "Exit app on window close" (default false) controlling it; keep a real Quit in the tray menu.
- [x] **Phase 12 — Record button: stateful redesign.** Idle: "Record" with a red icon, click starts recording. Recording: "Recording… M:SS" live elapsed time, prominent red button with white text/icon, click opens the record page (does NOT stop). Remove the sidebar recording indicator and the big red start-recording button on Home (now app-wide in the top bar).
- [x] **Phase 13 — Top-bar & list polish.** Remove the "Biscotti" title from the bar; Cmd+F focuses the search field app-wide (custom Find command + focus state; P2 "Find" menu item); Home button disabled when on Home; "No results for X" block vertically centered.

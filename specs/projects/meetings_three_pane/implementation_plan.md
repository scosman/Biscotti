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

- [ ] **Phase 2 — Meetings two-pane UI: native `List`, date grouping, search mode; remove `SearchUI`.**
  Convert `MeetingListView` to native `List(selection:)` with pinned `Section` headers; add the
  6-bucket `groupByDateBuckets` (+ boundary/order-invariant tests) replacing the 4-bucket grouping;
  render search mode (flat results) and the `ContentUnavailableView` placeholder / empty / no-results
  states; finalize `HSplitView` pane min/ideal/max widths + window min width; sidebar "Past Meetings"
  row styling + active state. **Remove the `SearchUI` module** (`SearchView` / `SearchViewModel` /
  `SearchUITests` + `Package.swift` targets) and any remaining legacy AppShell code; migrate the useful
  `SearchViewModelTests` assertions into the Phase 1 AppCore search tests. → `ui_design.md` §3–§5,
  `architecture.md` §4–§5, §7.
  *(Depends on: Phase 1.)*

- [ ] **Phase 3 — Chrome, extras & docs.** Toolbar **Home** button (`ToolbarItem(.navigation)`); hide
  the window **title** (`NSWindow.titleVisibility = .hidden` in the app target); Home **"See all"** row
  at the bottom of Recent Meetings. Repo-root **`architecture.md` doc edits** (rewrite #19
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

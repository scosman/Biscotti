# Meetings — 3-Pane Layout — Review for Human

Running log of decisions for the final human review. The top table records the **core decisions**
(confirmed with the user during speccing or driven on their explicit "you drive details" instruction).
The lower section will record **smaller calls made autonomously during development** — review these and
flag anything to change.

---

## Core decisions

| # | Decision | Choice | Notes / implication |
|---|----------|--------|---------------------|
| D1 | **Search → right pane** | **Auto-render top result (Notes-style)** | On a non-empty query, auto-select & render the top-ranked result. Zero results → placeholder. (User: "Start with auto-render top search result.") |
| D2 | **Date grouping buckets** | **Apple Notes/Mail scheme** | Today → Yesterday → Previous 7 Days → Previous 30 Days → `<Month>` (earlier this year) → `<Year>` (prior years). First-match, gap-free. Replaces today's Today/Yesterday/This Week/Earlier. (User asked me to drive the details from their rough sketch.) |
| D3 | **Upcoming events** | **Not part of the Meetings two-pane** | Selecting an upcoming event still opens its read-only preview as a full-width detail screen. (User confirmed.) |
| D4 | **Meetings screen memory / re-entry** | **Keep selection, browse** | The Meetings screen keeps its selected meeting for the session. "Past Meetings"/"See all" deliberately clear the search (always reveal the full list) but keep the previously-selected meeting on the right (placeholder only until the first meeting is opened). (User choice.) |
| D5 | **Empty right pane** | **"No Meeting Selected" placeholder (Mail-style)** | Shown when no meeting is selected. (From brief.) |
| D6 | **Divider** | **Resizable within a session; cross-launch persistence out of scope** | Draggable with sensible min/ideal widths. Remembering width across launches is a best-effort nice-to-have, not required. |
| D7 | **Post-delete navigation** | **Stay on Meetings, auto-select next (Mail-style)** | Deleting the selected meeting auto-selects the next meeting in the current list order (previous if it was last; placeholder if the list is now empty); in search mode, the next result. Stays on Meetings instead of routing Home (today's behavior). (User choice.) |
| D8 | **List size** | **Full list via standard SwiftData + lazy `List`; no custom paging** | The Meetings list lifts the 50-summary cap and shows all recorded meetings, relying on the standard SwiftData fetch + SwiftUI `List` lazy rendering. No custom infinite-scroll/virtualization. (User: "no true infinite. SwiftUI + SwiftData standard use case.") Home's Recent preview keeps its small cap. |
| D9 | **Far-left sidebar contents** | **Keep Record / indicator / Home / Upcoming / Settings; add "Past Meetings"; remove embedded list** | Only the embedded past-meetings list is removed; "Past Meetings" row sits under Home. (User confirmed.) |

## Open / deferred to UI design

- **"See all" placement** — resolved: a row/button at the bottom of the Recent Meetings section.
- **Exact window minimum width** for three columns — chosen during UI design (today's min is 640×400).
- **Default list-column width & per-pane minimums** for the Meetings two-pane — chosen during UI design.

---

## Autonomous calls made during development

| # | Area | Decision | Rationale |
|---|------|----------|-----------|
| A1 | AppCore | Put all Meetings-screen state (`meetingsSelection`, `meetingsQuery`, `meetingsResults`, `isSearchingMeetings`) directly on AppCore rather than a separate screen view-model | External entry points (menu bar, Home, `stopRecording`, delete) all need to mutate selection/query without a UI module in the call path. One source of truth makes the state machine unit-testable with no SwiftUI. The state lives in `AppCore.swift`, organized via `MARK` sections (`MARK: - Meetings screen state`, `MARK: - Meetings search`) and a same-file extension to contain the growth. |
| A2 | MeetingListUI | `ContentUnavailableView` placed inside the `List` builder (not as an overlay or replacement) | The architecture spec called for it inside the list. May need on-device verification (Phase 4) to confirm centering/sizing -- noted in code comments. |
| A3 | MeetingListUI | Kept the "matches: title, transcript" caption on search-result rows | The spec said "may optionally show" and "lean yes"; it is already built and informative, so retained. |
| A4 | DataStore | `meetingSummaries(limit:)` changed to `limit: Int? = nil` (nil = all) rather than a separate method | Simpler API; `nil` means "no cap". The Home screen and menu bar still pass explicit limits. |
| A5 | AppCore | `neighborID` is a pure static function on `AppCore` | Keeps it trivially unit-testable (table-driven tests over ordered UUID arrays). |
| A6 | Date grouping | 6-bucket `groupByDateBuckets` uses `calendar.startOfDay` boundaries (not `calendar.dateComponents`) | Start-of-day is the cleanest, locale-safe boundary for "today", "yesterday", etc. Month/year buckets use `calendar.component(.month/.year)` for grouping. |
| A7 | AppShellUI | `HSplitView` for the Meetings two-pane (not a nested `NavigationSplitView`) | Spec-driven (D6): the list must be always-visible and non-collapsing. `HSplitView` is the correct native primitive. |
| A8 | AppShellUI | Sidebar "Past Meetings" row styled identically to Home/Settings rows (icon + label + `accentColor.opacity(0.15)` active state) | Consistent with existing sidebar row pattern; no new styling primitives needed. |
| A9 | App target | Window title hidden via `NSViewRepresentable` (`WindowTitleHider`) that sets `window.titleVisibility = .hidden` | The spec recommended setting it from the app target. An `NSViewRepresentable` background view is the most reliable way to access the hosting `NSWindow` from SwiftUI, firing both on initial display and on window recreation (e.g. reopen from Dock). Needs on-device verification in Phase 4. |
| A10 | HomeUI | "See all" row uses secondary text + trailing chevron, hidden when no recordings | Matches the spec's "subtle full-width plain button (chevron affordance)" description. Hidden in the no-recordings state since the section already shows "No recordings yet". |
| A11 | AppShellUI | Toolbar Home button uses `ToolbarItem(placement: .navigation)` | Spec-driven: placed in the leading toolbar area after the sidebar toggle and before the search field. `.navigation` placement achieves this on macOS. |
| A12 | SearchUI removal | Deleted `SearchUI` module entirely (sources, tests, Package.swift targets, AppShellUI dependency) in Phase 2 | Spec-driven: search is no longer a screen; its debounced-search logic moved to AppCore, its matched-fields formatting moved to `MeetingListViewModel`. |
| A13 | Architecture doc | Renumbered components 21-25 to 20-24 after deleting SearchUI (#20) | Keeps the numbering contiguous. Updated the dependency graph and layer diagram to match. |

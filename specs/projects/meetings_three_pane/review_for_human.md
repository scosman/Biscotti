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

_(to be filled in during implementation)_

---
status: complete
---

# Functional Spec: Meetings — 3-Pane Layout

This project restructures how the user browses, searches, and opens recorded meetings. It introduces
a dedicated, always-visible **Meetings** screen with its own meeting list and a resizable detail
pane — an Apple-native master/detail (like Mail or Notes) — and retires the embedded sidebar list and
the standalone search screen. It is a **UI/navigation restructuring** of existing Stage C surfaces
(`AppShellUI`, `MeetingListUI`, `SearchUI`, `HomeUI`, `AppCore` routing). No new product capabilities
(no new data, no transcription/recording changes); the underlying meeting data, search, and
meeting-detail views are reused as-is.

Confirmed core decisions are tagged **D1–D9** and collected in `review_for_human.md`.

---

## 0. Goals and non-goals

**Why:** Today the past-meetings list lives *inside* the collapsible far-left sidebar. That is wrong
on three counts: (a) the sidebar collapses, taking the whole list with it; (b) an unbounded, growing
list is crammed into a fixed-size sidebar that also hosts Record, Home, Upcoming, and Settings; and
(c) search has to take over the whole detail pane because the list can't show filtered results in
place. The fix is the standard Apple master/detail shape: a dedicated list column that is always
visible on its own screen, with search filtering that list in place.

**Goals**
- A dedicated **Meetings** screen: an always-visible meeting list (left) + a resizable meeting-detail
  pane (right), shown only on that screen — not an app-wide third column.
- Move past-meetings browsing out of the far-left sidebar; reach it via a **Past Meetings** entry.
- Fold search into the Meetings list (filter in place); remove the standalone search takeover screen.
- Make the app fully navigable with the far-left sidebar collapsed, via a **Home** button in the
  toolbar (replacing the "Biscotti" window title).
- A **See all** affordance on Home's Recent Meetings.

**Non-goals (out of scope)** — see §10 for the full list. Notably: no custom pagination /
infinite-scroll machinery (the Meetings list uses the standard SwiftData fetch + lazy `List`), no
transcript/recording/calendar behavior changes, no menu-bar redesign, no new search ranking.

---

## 1. Navigation model

The app keeps a single main window built around the existing far-left **app sidebar** +
**content area** (today a `NavigationSplitView`). The content area is routed to one of these
destinations (the existing routes, with meetings/search reorganized):

| Destination | What shows in the content area |
|---|---|
| **Home** | The Home screen (full width). Unchanged except for the new "See all". |
| **Meetings** *(new shape)* | The two-pane Meetings screen: meeting **list** (left) + meeting **detail or placeholder** (right). Replaces the old standalone meeting-detail and search screens. |
| **Recording** | The in-progress recording screen (full width). Unchanged. |
| **Event preview** | The read-only upcoming-event preview (full width). Unchanged (**D3**: events are *not* part of the Meetings two-pane). |
| **Settings** | In-window settings (full width). Unchanged. |
| **Onboarding** | First-run full-window takeover. Unchanged. |

### 1.1 The Meetings screen's internal state

The Meetings screen owns two pieces of state that persist while you are on it:
- **Selected meeting** — the meeting shown in the right pane, or *none* (→ placeholder).
- **Search query** — empty (→ browse mode) or non-empty (→ search mode). See §3.

### 1.2 How you reach the Meetings screen

The Meetings screen appears when any of these happen:

1. **Past Meetings** (new far-left sidebar entry, §4) → Meetings screen in **browse mode** (search
   cleared); keeps the **previously-selected meeting** on the right, or the placeholder if none has
   been opened yet (**D4**).
2. **Home → "See all"** (Recent Meetings, §6) → same as Past Meetings: Meetings screen, browse mode,
   prior selection kept (**D4**).
3. **Selecting any meeting** — from the Meetings list, Home's Recent Meetings, the menu bar
   (`openApp(meetingID:)`), or a search result → Meetings screen with **that meeting selected**.
4. **Typing in the toolbar search field** (§3) → Meetings screen in **search mode**, auto-selecting
   the top result.
5. **Stopping a recording** — after a recording stops, the app opens that meeting → Meetings screen
   with the **just-recorded meeting selected** (preserves today's "jump to the new meeting" behavior).

**Memory (D4):** the Meetings screen keeps its selected-meeting and search-query for the session.
Leaving it (Home button, a sidebar entry, Settings, Record, an upcoming event) and selecting a meeting
again preserves the selection. The explicit "Past Meetings" / "See all" entries deliberately **clear
the search** (so they always reveal the full list) but **keep** the selected meeting on the right.

### 1.3 What does NOT change

- The far-left app sidebar still hosts Record, the recording indicator, Home, Upcoming events, and
  Settings (§4). It is still collapsible.
- Recording, Settings, Onboarding, and upcoming-Event-preview screens are unchanged.
- The menu bar is unchanged; its existing "open this meeting" / "open Home" / "open this event"
  actions resolve to the destinations above.

---

## 2. The Meetings screen (two-pane)

### 2.1 Layout

- **Left bar — meeting list.** Always visible whenever the Meetings screen is shown; it does **not**
  collapse (unlike the far-left app sidebar). This is the dedicated column the project exists to add.
- **Right pane — meeting area.** Shows the existing single-meeting detail view for the selected
  meeting, or a **"No Meeting Selected"** placeholder when none is selected (**D5**, Mail-style).
- **Resizable divider** between the two, draggable by the user (**D6**). Each pane has a sensible
  minimum width so neither can be dragged to uselessness; the list has a comfortable default width.
- This two-pane area lives *inside* the content region, to the right of the far-left app sidebar. So
  with the app sidebar expanded the user sees three columns (app sidebar | meeting list | detail);
  with it collapsed, two (meeting list | detail). The meeting list is **not** an app-wide column — it
  only exists on the Meetings screen.

### 2.2 Right pane

- **Selected meeting:** renders the existing meeting-detail screen (audio playback, transcript,
  versions, notes, association correction) — reused unchanged. Selecting a different meeting swaps the
  right pane to that meeting.
- **No selection:** a calm, centered placeholder titled "No Meeting Selected" (icon + short caption),
  consistent with Mail's empty detail.
- **Deleting the selected meeting (D7, Mail-style):** the user stays on the Meetings screen and the
  **next meeting is auto-selected** — the meeting that now occupies the deleted row's position in the
  current list order, or the previous one if the deleted meeting was last. If the list becomes empty,
  the right pane shows the placeholder. In search mode, the next *result* is selected the same way.
  (Supersedes today's "route Home after delete.") Deleting a non-selected meeting just refreshes the
  list and leaves the current selection intact.

### 2.3 Left bar — the meeting list

The list has two modes driven by the search query (§3):

- **Browse mode** (empty query): all loaded meetings, grouped under sticky date headers (§2.4).
- **Search mode** (non-empty query): a flat, ranked list of matching meetings, **no date headers**.

Common to both modes:
- Newest-relevant first. Each row shows the meeting title and a secondary line (date · duration) —
  the existing row content.
- Native single-selection: the selected row is highlighted using the platform's native list selection
  (full-row accent), and selection is keyboard-navigable (↑/↓ move selection, which updates the right
  pane). This replaces today's hand-rolled highlight.
- The list scrolls independently of the right pane.
- The list shows the **full** set of recorded meetings (newest first), loaded via the standard
  SwiftData fetch and lazily rendered by SwiftUI's `List` — the artificial 50-summary cap used by
  today's sidebar list is lifted for this column. No custom paging/virtualization beyond what
  SwiftData + `List` give out of the box (**D8**, §10).

### 2.4 Date grouping (browse mode) — **D2**

Sticky section headers, rendered with native list sections (header pins to the top of the list while
its rows scroll under it). A meeting falls into the **first** bucket it matches, evaluated top-down,
so buckets never overlap and there are no gaps:

1. **Today**
2. **Yesterday**
3. **Previous 7 Days** (8th-most-recent day back through 2 days ago — i.e., the days between
   "Yesterday" and a week ago)
4. **Previous 30 Days**
5. **`<Month>`** — e.g. "March": any earlier date still within the **current calendar year**, grouped
   and titled by its month, most recent month first.
6. **`<Year>`** — e.g. "2025", "2024": any date in a **prior calendar year**, grouped and titled by
   its year, most recent year first.

Empty buckets are omitted. (This is the Apple Notes/Mail scheme; it replaces today's
Today/Yesterday/This Week/Earlier grouping, which had only four buckets.)

---

## 3. Search

Search no longer has its own screen. It filters the Meetings list in place.

- **Entry point:** the existing toolbar search field (`.searchable`) remains the single search input.
- **Typing a query:**
  1. Routes to the **Meetings** screen (if not already there).
  2. Puts the meeting list into **search mode**: a flat, ranked result list (existing
    `DataStore.searchHits` matching on title / people / transcript / notes, same debounce as today).
  3. **Auto-selects and renders the top result** in the right pane, but only after the debounce
    settles — not per keystroke (**D1** — start with Notes-style auto-render, not Mail's empty pane;
    revisable). Refinement: if the **currently-selected meeting is still present** in the new result
    set, the selection is kept (no yank); otherwise the top result is auto-selected. Zero results →
    placeholder.
- **Clearing the query** (empty field): the list returns to **browse mode** (full grouped list). The
  right pane keeps whatever meeting is currently selected; if nothing is selected, the placeholder.
  (Clearing restores the *list*, it does not change the selection.)
- **Selecting a search result:** updates the right pane to that meeting. The list **stays in search
  mode** showing the results (the dedicated column means selecting a result no longer destroys the
  result list — this resolves the old `TODO(nav-stack)` about push-vs-replace).
- **No standalone search screen/route.** The old full-pane `SearchView` takeover, its Back button, and
  the separate search route are removed; their behavior is absorbed into the Meetings list.

### 3.1 Search states

| State | Left bar | Right pane |
|---|---|---|
| Query non-empty, searching | progress indicator (or stale-free spinner as today) | last selection or placeholder |
| Query non-empty, ≥1 result | flat ranked results | top result auto-rendered (until user picks another) |
| Query non-empty, 0 results | "No meetings match '`<query>`'." | placeholder |
| Query empty | full grouped list | current selection, else placeholder |

---

## 4. Far-left app sidebar changes

The far-left app sidebar (the existing collapsible `NavigationSplitView` sidebar) is updated:

- **Removed:** the embedded scrollable list of past meetings (today rendered by `MeetingListView`
  under a "PAST" header).
- **Added:** a single **Past Meetings** navigation row, placed directly under **Home**. Selecting it
  opens the Meetings screen with no meeting selected (browse mode), revealing the full list in the
  dedicated left bar.
- **Unchanged:** Record button, recording indicator, Home row, the Upcoming events section, and the
  pinned Settings row at the bottom.

Resulting sidebar order (top → bottom): Record button → (recording indicator when recording) → Home →
**Past Meetings** → Upcoming section (when calendar authorized & non-empty) → Spacer → Settings.

"Past Meetings" shows a selected/active state when the content area is on the Meetings screen
(consistent with how Home and Settings show active state today).

---

## 5. Toolbar changes (app navigability with sidebar collapsed)

- **Add a Home button to the window toolbar** — a house icon that routes the content area to Home.
  Placed in the toolbar's leading/navigation area, after the system sidebar-toggle control and before
  the search field (i.e., where the window title sits today).
- **Remove the "Biscotti" window title** from the toolbar/title area so the Home button occupies that
  space (the app is still named Biscotti everywhere else; only the in-window title text is dropped).
- **Rationale:** the Home screen is the app's hub (it can navigate anywhere), so a always-present Home
  button makes the app fully usable even when the far-left sidebar is collapsed.
- The toolbar search field is unchanged in placement (it now drives the Meetings-list search per §3).

---

## 6. Home screen change

- **Recent Meetings → add a "See all" affordance.** A "See all" control placed **at the bottom of the
  Recent Meetings section** (a row/button under the listed recent meetings) routes to the **Meetings**
  screen (browse mode), where the full grouped list is shown. Recent Meetings itself still shows its
  capped preview (max 4) and tapping a recent meeting still opens it (now in the Meetings screen,
  §1.2).
- No other Home changes.

---

## 7. Edge cases & states

- **No meetings at all:** Meetings screen left bar shows the existing "No recordings yet" empty text;
  right pane shows the "No Meeting Selected" placeholder. "Past Meetings" and "See all" still navigate
  there (showing the empty state).
- **Selected meeting deleted:** auto-select the next meeting (Mail-style, §2.2). If the selection
  becomes invalid for some *other* reason (e.g. the list reloads without it), the right pane falls back
  to the placeholder and selection clears.
- **Search cleared while a search result is selected:** the selected meeting remains in the right pane;
  the list returns to the full grouped browse list (the selected row is highlighted in its date group
  if present). (§3.)
- **Switching away and back:** leaving the Meetings screen and returning restores the prior selection
  and search query (§1.2 / **D4**).
- **Window too narrow for three columns:** the window's minimum width is raised enough to host the app
  sidebar + list + detail without clipping; below that the OS prevents further shrink. (Exact value is
  a UI-design detail; today's min is 640×400.) With the far-left sidebar collapsed, only two columns
  show and more room is available.
- **Keyboard:** ↑/↓ in the focused list moves selection and updates the detail pane; the toolbar search
  field focus/typing behaves as today (no separate search screen to dismiss).
- **Recording in progress:** Record/indicator behavior in the far-left sidebar is unchanged; navigating
  to Meetings while recording is allowed (the recording continues; the indicator remains in the
  sidebar).

---

## 8. What is reused unchanged

- **Meeting detail** view + view model (right pane content).
- **Search engine:** `DataStore.searchHits` (ranking, matched-field reporting, debounce).
- **Meeting summaries source** and the meeting-row content (title + date·duration second line).
- **Upcoming-event preview**, Recording, Settings, Onboarding screens, and the menu bar.

## 9. What is removed or substantially changed

- **Removed:** the standalone search screen (`SearchView` full-pane takeover + its Back button + the
  dedicated search route). Search becomes a mode of the Meetings list.
- **Removed:** the past-meetings list embedded in the far-left sidebar.
- **Changed:** the meeting-detail and search destinations merge into a single two-pane **Meetings**
  screen with persistent list + selection state.
- **Changed:** date-grouping buckets (4 → the Notes/Mail scheme, §2.4).
- **Changed:** post-delete navigation (Home → stay on Meetings, auto-select next, §2.2 / **D7**).
- **Changed:** the toolbar (Home button added, window title removed, §5).

---

## 10. Out of scope (deliberately deferred)

- **Custom pagination / infinite-scroll machinery (D8).** The Meetings list shows the *full*
  recorded-meeting set using the standard SwiftData fetch + SwiftUI `List` lazy rendering — the
  artificial 50-summary cap used by today's sidebar list is lifted for this list. We do **not** build
  custom paging/virtualization beyond what SwiftData + `List` give out of the box. (Home's "Recent
  Meetings" preview keeps its small cap.)
- **Cross-launch persistence of the divider position.** Draggable within a session is required;
  remembering the width across app launches is a best-effort nice-to-have, not required (**D6**).
- **Any change to search ranking, matched-field logic, or what fields are searched.**
- **Recording, transcription, calendar, notifications, detection, settings, onboarding behavior.**
- **Menu-bar redesign** (including the existing `TODO(see-all)` for an upcoming/recent list in the
  menu) — untouched here.
- **Sorting/filtering controls** on the meeting list beyond date grouping + search (e.g. sort by
  duration, filter by person). Not in this project.

---

## 11. Decisions resolved during review

- **"See all" placement (§6):** resolved — a row/button **at the bottom of** the "Recent Meetings"
  section (user choice).
- **List size (§2.3 / D8):** resolved — full list via standard SwiftData/`List`, no custom paging.
- **Search auto-render (§3 / D1):** resolved — try Notes-style auto-render (after debounce, keeping a
  still-present selection); revisable later.

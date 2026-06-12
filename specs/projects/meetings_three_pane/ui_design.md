---
status: complete
---

# UI Design: Meetings — 3-Pane Layout

Apple-native restructuring of the browse/search/detail surfaces into a Mail/Notes-style master-detail.
Reuses the existing `NavigationSplitView` app shell, `DesignSystem` tokens, the meeting-detail view,
and the search engine. Strongly prefers **native controls** (`List` with pinned `Section` headers,
`List(selection:)`, `HSplitView`, `ContentUnavailableView`, toolbar items) over hand-rolled UI.

References the functional spec (`functional_spec.md`) for behavior; this doc is the **visual/interaction
layer** and the **changed/new/removed view inventory**. Concrete view-model APIs and module placement
are the architecture step's job.

---

## 1. Design principles

- **Native master-detail.** The Meetings screen is the standard macOS two-pane list+detail (think
  Mail). Use the platform primitives so behavior (selection highlight, keyboard nav, sticky headers,
  empty states) comes for free and matches the OS.
- **Reuse, don't reinvent.** Right pane = the existing `MeetingDetailView`. Search = existing
  `DataStore.searchHits`. Rows = existing title + "date · duration" second line. Tokens from
  `DesignSystem`.
- **Calm hierarchy.** The far-left app sidebar is navigation chrome (Record, Home, Past Meetings,
  Upcoming, Settings). The Meetings list is content. Detail is focus.
- **One search field.** The toolbar `.searchable` is the only search input; it filters the list in
  place — no separate screen, no Back button.

---

## 2. Window & navigation structure

The outer shell is unchanged in *kind*: a `NavigationSplitView` with the collapsible far-left **app
sidebar** and a **content region** routed by `AppCore.route`. Only the content for the *meetings*
destination changes — it becomes a non-collapsing, resizable two-pane.

```
┌── window toolbar ─────────────────────────────────────────────────────────┐
│ [⧉ sidebar]  [🏠 Home]                                   [🔍 Search……]     │   ← title text removed
├───────────────┬───────────────────────────────────────────────────────────┤
│ APP SIDEBAR   │  CONTENT REGION (routed)                                    │
│ (collapsible) │                                                             │
│  ⏺ Record     │   ── when route = Meetings: the two-pane below ──           │
│  🏠 Home       │  ┌──────────────── HSplitView (resizable) ─────────────┐   │
│  🕘 Past Mtgs  │  │ MEETING LIST          ║  MEETING DETAIL / PLACEHOLDER │  │
│               │  │ (always visible)      ║                              │  │
│  UPCOMING     │  │  ▸ Today              ║   <MeetingDetailView>        │  │
│   • 3pm Sync  │  │     Standup           ║    or                        │  │
│   • 4pm 1:1   │  │     Design review ◀───║   "No Meeting Selected"      │  │
│               │  │  ▸ Yesterday          ║                              │  │
│               │  │     Budget call       ║                              │  │
│  ⚙︎ Settings   │  │  ▸ Previous 7 Days …  ║                              │  │
│  (pinned)     │  └───────────────────────╨──────────────────────────────┘  │
└───────────────┴───────────────────────────────────────────────────────────┘
       ↑ collapsible sidebar          ↑ never collapses; divider draggable (║)
```

- **Outer:** `NavigationSplitView { appSidebar } detail: { routedContent }` (as today).
- **Meetings content:** an **`HSplitView`** containing the **list pane** (left) and the **detail pane**
  (right). `HSplitView` gives a native, always-visible, draggable divider — it does **not** collapse
  like a `NavigationSplitView` sidebar, which is exactly the requested behavior. Other routes (Home,
  Recording, Event preview, Settings) render full-width in the content region as today.
- **Three columns appear only on Meetings**, only when the app sidebar is expanded. Collapse the app
  sidebar → two columns (list + detail). The list pane is never an app-wide column.

> **Why `HSplitView`, not a nested `NavigationSplitView`:** a nested split view's leading column is
> collapsible (system toggle) and we explicitly want the list always visible; `HSplitView` is the
> right native primitive for a fixed, resizable two-pane.

---

## 3. The Meetings list pane (left bar)

A native **`List`** (not a hand-built `ScrollView`), so we get pinned section headers, full-row
selection highlight, and keyboard navigation for free.

### 3.1 Structure & selection
- `List(selection: $selectedMeetingID)` where the binding is the screen's selected meeting (`UUID?`).
  Rows carry `.tag(meeting.id)`. This yields the native accent-highlighted selected row and ↑/↓
  keyboard selection that drives the detail pane.
- Row content (reused): line 1 = meeting title (`.body`, 1 line); line 2 = "date · duration"
  (`Tokens.metadataFont`, secondary) via the existing `TimeFormatting.meetingSecondLine`.
- List style: `.inset` (Mail-like content list). **Sticky/pinned section headers** are native on macOS
  for sectioned `List`s — *verify the chosen style pins headers on device* (see §9).

### 3.2 Browse mode — sticky date sections (D2)
`Section`s in first-match order, empty sections omitted:

```
▸ Today
▸ Yesterday
▸ Previous 7 Days
▸ Previous 30 Days
▸ March                 ← months, earlier-this-year, most-recent first
▸ February
▸ 2025                  ← years, prior years, most-recent first
▸ 2024
```

Header text uses `Tokens.sectionHeaderFont` / secondary color (or the native section header styling —
prefer native). The grouping/titling is pure logic (new bucketing replacing the current 4-bucket
`groupByEffectiveDate`).

### 3.3 Search mode — flat results
- When the query is non-empty: a single, **header-less** `List` of ranked results (same selection
  binding). Rows may optionally show the matched-fields caption that exists today
  (`matches: title, transcript`) — keep it, it's useful and already built.
- Searching spinner: a centered `ProgressView` while a query is in flight (reuse today's
  stale-results-cleared-then-spinner behavior).

### 3.4 Empty states (native `ContentUnavailableView`)
- **No recordings at all** (browse, empty store): `ContentUnavailableView("No Recordings", systemImage:
  "waveform", description: Text("Recorded meetings will appear here."))` in the list pane.
- **No search results**: `ContentUnavailableView.search(text: query)` — the native "No Results for
  '…'" treatment.
- These replace today's plain `Text` empty strings.

### 3.5 Sizing
- List pane: `minWidth ≈ 220`, `idealWidth ≈ 280`, `maxWidth ≈ 420`. (Tunable on device, §9.)

---

## 4. The detail pane (right)

- **Selected meeting:** `MeetingDetailView(viewModel: …)` reused unchanged, with `.id(selectedMeetingID)`
  so SwiftUI rebuilds detail state on selection change (mirrors today's `.id(meetingID)`). The existing
  per-ID view-model cache (`AppShellViewModel.meetingDetailViewModel(for:)`) is reused.
- **No selection — placeholder (D5):** native
  `ContentUnavailableView("No Meeting Selected", systemImage: "quote.bubble", description: Text("Select
  a meeting from the list to see its transcript and details."))`, centered, Mail-style.
- Detail pane: `minWidth ≈ 360`, fills remaining width.

---

## 5. Far-left app sidebar (D9)

Reworked from today's hand-built `VStack` of rows. **Remove** the `"PAST"` header + `ScrollView` +
embedded `MeetingListView`. **Add** a single **Past Meetings** row styled exactly like the existing
`homeRow`/`settingsRow` (icon + label + active-state background).

```
⏺  Record                (RecordButton — unchanged)
   ● Recording… 0:42      (indicator — unchanged, only while recording)
──────────────────────
🏠 Home                   (active when route = Home)
🕘 Past Meetings          (NEW — active when route = Meetings)   ← icon: "clock" / "tray.full"
──────────────────────
UPCOMING                  (section — unchanged)
   • 3:00 Sync
   • 4:00 1:1
        ⋮  (Spacer)
⚙︎ Settings               (pinned bottom — unchanged)
```

- "Past Meetings" tap → `core.showMeetings()` (browse mode, keep selection per D4).
- Active highlight: same `accentColor.opacity(0.15)` rounded background pattern used by Home/Settings,
  shown when the content route is the Meetings screen.
- The sidebar's `frame(minWidth: 180, idealWidth: 220)` is unchanged.

---

## 6. Toolbar

- **Home button (new):** a `ToolbarItem(placement: .navigation)` `Button { core.showHome() } label: {
  Image(systemName: "house") }`, appearing in the leading area **after** the system sidebar-toggle and
  **before** the search field — i.e., where the "Biscotti" title sits today.
- **Remove the window title text:** hide the title so the Home button occupies that space. Recommended
  robust path: set the main `NSWindow.titleVisibility = .hidden` from the app target (the AppDelegate
  already holds the window for its will-close handling). Keep traffic lights + toolbar + the draggable
  title bar region. (SwiftUI-only alternatives like an empty `navigationTitle` are less reliable on
  macOS — pick during build, verify on device, §9.) The app/menu name stays "Biscotti".
- **Search field:** the existing `.searchable(text:placement:.toolbar)` stays in place; its text now
  drives the list's search mode (§3.3, §7) instead of the removed `.search` route.
- Home button + search are present on all normal routes (Home/Meetings/Recording/Event/Settings); the
  onboarding full-window takeover has no toolbar (unchanged).

---

## 7. Search wiring (UI level)

- Typing (non-empty) → route to Meetings (if needed) + push the query into the list's search state →
  list shows ranked results, detail auto-renders the top result after the debounce settles (keeping a
  still-present selection — D1).
- Clearing (empty) → list returns to browse (grouped) mode; **stays on the Meetings screen** (no
  return-to-previous-route; the old `searchReturnRoute`/`dismissSearch` machinery and the `SearchView`
  Back button are removed). Detail keeps the current selection (else placeholder).
- The toolbar field's focus management (today's `dismissFocusCount` → `@FocusState`) is no longer tied
  to a search screen; only what's needed to keep the field behaving natively is retained.

---

## 8. Home screen — "See all"

- Add a **"See all"** affordance at the **bottom of the Recent Meetings section** (a trailing row/link
  under the (max 4) recent rows), routing to the Meetings screen (browse mode).

```
RECENT MEETINGS
  Design review          Jun 11, 2026 · 34m
  Budget call            Jun 10, 2026 · 28m
  Standup                Jun 10, 2026 · 9m
  1:1 with Sam           Jun 9, 2026 · 22m
  ──────────────────────────────────────
  See all →                                   ← NEW (plain link-style button, full-row tappable)
```

- Styled as a subtle full-width plain button (chevron affordance), consistent with the card. Hidden
  when there are zero recordings (the section already shows its "No recordings yet" state).

---

## 9. Sizing, styling, and on-device verification

- **Window minimum width:** raise from today's `640` to ≈ **`720`** so the three-column case
  (sidebar + list + detail) is usable; collapsing the app sidebar frees space. Min height unchanged
  (`400`). (Tunable.)
- **Divider position persistence:** session-only is fine (D6); cross-launch persistence is out of
  scope.
- **Verify on device (Apple-silicon hardware), per the repo's SwiftUI caution:**
  1. The chosen `List` style pins section headers (sticky) on macOS.
  2. `NSWindow.titleVisibility = .hidden` removes the title cleanly while keeping the toolbar/Home
     button and traffic lights.
  3. `HSplitView` divider drag + min/ideal/max frames behave (no clipping of `MeetingDetailView`).
  4. `List(selection:)` ↑/↓ keyboard selection updates the detail pane.

---

## 10. View inventory — new / changed / removed

**New**
- **Meetings screen container** — composes the `HSplitView` (list pane + detail/placeholder). Module
  placement (a new `MeetingsUI` module vs. inside `AppShellUI`) is decided in the architecture step.
- **No-selection placeholder** + **empty/no-result** states via `ContentUnavailableView`.

**Changed**
- **`MeetingListView` / `MeetingListViewModel`** → redesigned into the dedicated list pane: native
  `List` with pinned sections, `List(selection:)`, the new date buckets (§3.2), and a search mode
  (§3.3). (Today's sidebar-oriented `ScrollView` + manual highlight is replaced.)
- **`AppShellView` / `AppShellViewModel`** → sidebar loses the embedded list, gains the Past Meetings
  row; content routing renders the Meetings two-pane for the meetings destination; toolbar gains the
  Home button; search wiring re-pointed at the list (§7).
- **`HomeView`** → "See all" row in Recent Meetings (§8).
- **`AppCore` routing** → meetings destination + selection/search state; post-delete select-next;
  remove `.search`/`searchReturnRoute`. (Exact shape: architecture step.)
- **App target** → hide the main window title (§6).

**Removed**
- **`SearchView`** (full-pane takeover) and its Back button; the standalone search route. Search logic
  folds into the list's view model (reusing `DataStore.searchHits`).

---

## 11. Open UI items (deferred, low-risk)

- Exact pane widths, window min width, and Past-Meetings icon glyph — finalize during build/on-device.
- Whether search-mode rows keep the "matches: …" caption (lean **yes**, it's already built and
  informative).

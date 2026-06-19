---
status: complete
---

# Architecture: Meetings — 3-Pane Layout

Technical design, deep enough to code from. This is a **UI/navigation restructuring** within the
existing `BiscottiKit` UI modules + `AppCore` + the app target. It introduces no new persistence, no
new services, and no new ML. The static topology is fixed by the repo `../../../architecture.md`; this
doc records the **deltas** to that topology and the **concrete app-level APIs** for the change.

Builds on the existing app shell (`NavigationSplitView` + `Route`-driven content), the `@MainActor
@Observable` AppCore-as-single-surface pattern, child-view-models-cached-in-`AppShellViewModel`, and
`DesignSystem` tokens. **Read `AppCore.swift`, `AppShellView(Model).swift`, `MeetingListView(Model)`,
and `SearchView(Model)` first.**

Single-doc project — **no `components/` files** (≈3 modules + app target; not enough internal
complexity to warrant per-component docs).

---

## 0. Topology delta (vs. repo `architecture.md`)

| Module | Change |
|---|---|
| **AppCore** | Owns the **Meetings-screen model**: `route = .meetings`, `meetingsSelection`, `meetingsQuery`, `meetingsResults`, `isSearchingMeetings`, full `summaries`; the debounced search (moved out of `SearchViewModel`), auto-select-top, and select-next-on-delete. `Route` loses `.meeting(UUID)`/`.search`; gains `.meetings`. |
| **MeetingListUI** | `MeetingListView` becomes the **dedicated left-bar list**: native `List` with pinned `Section` headers, `List(selection:)`, new 6-bucket grouping, **and** a flat search-results mode. `MeetingListViewModel` becomes a thin presenter over AppCore. |
| **AppShellUI** | Hosts the **Meetings two-pane** (`HSplitView`) in its content routing; sidebar drops the embedded list + gains a **Past Meetings** row; toolbar gains a **Home** button; search field re-pointed at `AppCore.meetingsQuery`. |
| **SearchUI** | **Removed** (module + tests). The full-pane takeover and `SearchViewModel` are deleted; the search engine call (`DataStore.searchHits`) moves into AppCore. (`SearchHit`/`SearchField` already live in `DataStore` — unaffected.) |
| **DataStore** | `meetingSummaries(limit:)` gains an **all** path (lift the 50 cap for the Meetings list). |
| **Biscotti (app target)** | Hide the main window **title text** (`NSWindow.titleVisibility = .hidden`). |
| **MenuBarUI** | **No change** — its `core.select(id)` / `showHome()` / `selectEvent(key)` calls resolve to the new destinations. |

**Repo `architecture.md` edits (done in the final phase):** rewrite #19 *MeetingListUI* ("the
Meetings-screen list: grouped past meetings + in-place search results, native selection"); **delete**
#20 *SearchUI*; remove `SRCH` from the dependency graph (and `SHELL --> … & SRCH`). These are doc
edits; the build truth is below.

---

## 1. Route & AppCore Meetings-screen model

### 1.1 `Route` (in `AppCore`)

```swift
public enum Route: Sendable, Equatable {
    case home
    case recording
    case meetings              // NEW — the two-pane Meetings screen
    case event(String)         // unchanged (upcoming-event preview, full width)
    case settings
    case onboarding
    // REMOVED: case meeting(UUID)   → folded into `.meetings` + `meetingsSelection`
    // REMOVED: case search          → folded into `.meetings` + `meetingsQuery`
}
```

Selection is **not** encoded in the route (so it survives navigating away and back — D4). The route
just says "show the Meetings screen"; `meetingsSelection` says which meeting (or none).

### 1.2 New AppCore state (single source of truth)

```swift
// MARK: Meetings screen
public private(set) var meetingsSelection: UUID?      // selected meeting, or nil → placeholder
public private(set) var meetingsQuery: String = ""    // "" → browse mode, else search mode
public private(set) var meetingsResults: [SearchHit] = []
public private(set) var isSearchingMeetings = false
// `summaries: [MeetingSummary]` already exists — now loaded UNCAPPED (see §3).
private var meetingsSearchTask: Task<Void, Never>?
```

Why AppCore owns all of it (not a screen view-model): every entry point that opens a meeting
(`select` from the menu bar / Home / `stopRecording`, search-result taps, Past Meetings) and the
delete flow (originating in `MeetingDetailViewModel → core.deleteMeeting`) must mutate selection/query
**without** a UI module in the call path. Centralizing here keeps one source of truth, makes
select-next + auto-select-top + query-clearing consistent, and makes the whole state machine
**unit-testable with no SwiftUI** (injected `store` + `scheduler`).

### 1.3 Navigation / selection API (replaces `select`, `presentSearch`, `dismissSearch`)

```swift
/// Open a specific meeting from OUTSIDE the list (menu bar, Home recent,
/// stopRecording, "open this meeting"). Clears any active search → browse.
public func select(_ meetingID: UUID) {
    cancelMeetingsSearch()
    meetingsQuery = ""; meetingsResults = []
    meetingsSelection = meetingID
    route = .meetings
}

/// Row selection from WITHIN the list (List(selection:) setter). Preserves the
/// current mode (keeps the query if searching). nil → placeholder.
public func selectFromList(_ meetingID: UUID?) {
    meetingsSelection = meetingID
    // route is already .meetings; query untouched.
}

/// "Past Meetings" (sidebar) and "See all" (Home): browse mode, KEEP selection (D4).
public func showMeetings() {
    cancelMeetingsSearch()
    meetingsQuery = ""; meetingsResults = []
    route = .meetings           // meetingsSelection unchanged
}
```

`navigateToRecording()`, `showHome()`, `showSettings()`, `selectEvent(_:)`, `showOnboardingReplay()`
are unchanged. `presentSearch()` / `dismissSearch()` / `searchReturnRoute` are **removed**.

### 1.4 Search (moved from `SearchViewModel`, debounced via the `scheduler` seam)

```swift
/// Called when the toolbar query changes (bound from AppShellViewModel).
public func setMeetingsQuery(_ query: String) {
    meetingsQuery = query
    cancelMeetingsSearch()
    guard !query.isEmpty else {                 // cleared → browse
        meetingsResults = []; isSearchingMeetings = false
        return
    }
    route = .meetings                           // typing jumps to Meetings
    isSearchingMeetings = true
    meetingsResults = []                        // clear stale before debounce
    meetingsSearchTask = Task { [weak self, scheduler] in
        try? await scheduler.sleep(for: .milliseconds(300))
        guard let self, !Task.isCancelled, meetingsQuery == query else { return }
        let hits = (try? await store.searchHits(query, limit: 50)) ?? []
        guard !Task.isCancelled, meetingsQuery == query else { return }
        meetingsResults = hits
        isSearchingMeetings = false
        autoSelectTopResult()                   // D1
    }
}

private func autoSelectTopResult() {
    // Keep the current selection if it survived into the new results; else top hit.
    if let sel = meetingsSelection,
       meetingsResults.contains(where: { $0.id == sel }) { return }
    meetingsSelection = meetingsResults.first?.id     // nil if no results → placeholder
}

private func cancelMeetingsSearch() {
    meetingsSearchTask?.cancel(); meetingsSearchTask = nil; isSearchingMeetings = false
}
```

Routing the 300ms debounce through the existing `scheduler` (an `AppScheduler` seam) — instead of
`SearchViewModel`'s raw `Task.sleep` — makes search deterministic in tests.

### 1.5 Select-next on delete (D7, Mail-style)

`deleteMeeting(meetingID:)` no longer sets `route = .home`. Instead it computes the neighbor in the
**currently-displayed order**, deletes, reloads, and selects the neighbor:

```swift
// inside deleteMeeting, replacing `route = .home`:
let activeOrder: [UUID] = meetingsQuery.isEmpty
    ? summaries.map(\.id)                 // browse order == summaries order (invariant §4.2)
    : meetingsResults.map(\.id)           // search order == ranked results
let neighbor = Self.neighborID(in: activeOrder, removing: meetingID)

// … existing file delete + store.delete …
await reloadSummaries()
if !meetingsQuery.isEmpty { await rerunMeetingsSearchNow() }   // refresh results post-delete

// validate neighbor still exists in the refreshed active list, else nil → placeholder
let refreshed = meetingsQuery.isEmpty ? summaries.map(\.id) : meetingsResults.map(\.id)
meetingsSelection = neighbor.flatMap { refreshed.contains($0) ? $0 : nil }
route = .meetings
```

```swift
/// The element AFTER `id` (older), or the one BEFORE if `id` was last,
/// or nil if `id` was the only element / not found. Pure + unit-tested.
static func neighborID(in ordered: [UUID], removing id: UUID) -> UUID? {
    guard let i = ordered.firstIndex(of: id) else { return nil }
    if i + 1 < ordered.count { return ordered[i + 1] }
    if i - 1 >= 0 { return ordered[i - 1] }
    return nil
}
```

`rerunMeetingsSearchNow()` is the non-debounced variant of §1.4's fetch (reused by delete; mirrors the
old `searchImmediately`). The "refuse to delete an actively-recording meeting" guard is unchanged.

### 1.6 `stopRecording` change

Replace `route = .meeting(meetingID)` with `select(meetingID)` (→ `.meetings` + selection + search
cleared). All other `stopRecording` behavior (reload, transcription enqueue) is unchanged.

---

## 2. Detail-pane selection wiring (AppShellViewModel)

The per-ID `MeetingDetailViewModel` cache stays. The container reads `core.meetingsSelection`:

```swift
// AppShellViewModel
public var meetingsSelection: UUID? { core.meetingsSelection }
public func selectFromList(_ id: UUID?) { core.selectFromList(id) }
public func showMeetings() { core.showMeetings() }
// detail VM for the selected meeting (existing cache, keyed by id):
public func meetingDetailViewModel(for id: UUID) -> MeetingDetailViewModel { /* unchanged */ }
```

Toolbar/search field two-way sync (guarded to avoid a feedback loop), in `AppShellView`:

```swift
@State private var searchText = ""   // bound to .searchable
// .onChange(of: searchText)            { if $0 != core.meetingsQuery { vm.setMeetingsQuery($0) } }
// .onChange(of: vm.meetingsQuery)      { if $0 != searchText { searchText = $0 } }
```

This keeps the field authoritative for typing while letting AppCore clear it (e.g. `select(_:)` sets
`meetingsQuery = ""` → the field clears). `AppShellViewModel.setMeetingsQuery` forwards to
`core.setMeetingsQuery`. The old `searchViewModel`, `dismissFocusCount`/`@FocusState` plumbing, and
`onSearchSubmit`/`onSearchFieldFocused`/`clearSearch` are removed.

---

## 3. DataStore — full summaries

Lift the cap for the Meetings list (D8). Make the limit optional (nil → all), preserving the existing
in-memory effective-date sort:

```swift
func meetingSummaries(limit: Int? = nil) throws -> [MeetingSummary] {
    let all = try context.fetch(FetchDescriptor<Meeting>())
    let sorted = all.sorted { ($0.startDate ?? $0.createdAt) > ($1.startDate ?? $1.createdAt) }
    let capped = limit.map { Array(sorted.prefix($0)) } ?? sorted
    return capped.map { /* → MeetingSummary, unchanged */ }
}
```

`AppCore.reloadSummaries()` calls `meetingSummaries()` (no limit) → `summaries` holds all meetings,
newest-first. Home still takes `prefix(4)`; the menu bar still takes its small slice. The existing
`summaryLimit` init param is removed (or defaulted to nil). The `TODO` about a denormalized
`effectiveDate` column for >1000 meetings stays valid (out of scope here). SwiftUI's `List` renders
rows lazily, so a long list is fine without custom paging.

---

## 4. MeetingListUI — the left-bar list

### 4.1 View (`MeetingListView`)

A native `List` driven by the VM's mode, with the selection binding built from AppCore:

```swift
List(selection: Binding(get: { viewModel.selectedID },
                        set: { viewModel.select($0) })) {
    switch viewModel.mode {
    case .browse:
        if viewModel.groups.isEmpty {
            ContentUnavailableView("No Recordings", systemImage: "waveform",
                description: Text("Recorded meetings will appear here."))
        } else {
            ForEach(viewModel.groups) { group in
                Section(group.title) {
                    ForEach(group.meetings) { meetingRow($0).tag($0.id) }
                }
            }
        }
    case .search:
        if viewModel.isSearching { ProgressRow() }
        else if viewModel.results.isEmpty {
            ContentUnavailableView.search(text: viewModel.query)
        } else {
            ForEach(viewModel.results) { searchRow($0).tag($0.id) }   // optional matched-fields caption
        }
    }
}
.listStyle(.inset)   // verify pinned headers on device (§8)
```

- `meetingRow` = today's title + `TimeFormatting.meetingSecondLine` (date · duration).
- `searchRow` = title + date + the existing "matches: …" caption (kept — already built).
- Native `List(selection:)` gives the accent highlight + ↑/↓ keyboard nav for free (replaces today's
  hand-rolled `accentColor.opacity(0.15)` background).

### 4.2 View model (`MeetingListViewModel`) — thin presenter

```swift
@MainActor @Observable public final class MeetingListViewModel {
    private let core: AppCore
    public enum Mode { case browse, search }
    public var mode: Mode { core.meetingsQuery.isEmpty ? .browse : .search }
    public var groups: [MeetingGroup] { Self.groupByDateBuckets(core.summaries) }
    public var results: [SearchHit] { core.meetingsResults }
    public var isSearching: Bool { core.isSearchingMeetings }
    public var query: String { core.meetingsQuery }
    public var selectedID: UUID? { core.meetingsSelection }
    public func select(_ id: UUID?) { core.selectFromList(id) }
}
```

**Grouping (pure, unit-tested)** — replaces `groupByEffectiveDate`'s 4 buckets with 6, first-match,
contiguous descending ranges so empty buckets drop out:

```swift
public static func groupByDateBuckets(
    _ meetings: [MeetingSummary],
    relativeTo now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
) -> [MeetingGroup]
```

Boundaries (using `startOfDay`):
| Bucket | Predicate (on `meeting.date`) | Title |
|---|---|---|
| Today | `>= startOfToday` | "Today" |
| Yesterday | `>= startOfToday-1d` | "Yesterday" |
| Previous 7 Days | `>= startOfToday-7d` | "Previous 7 Days" |
| Previous 30 Days | `>= startOfToday-30d` | "Previous 30 Days" |
| `<Month>` | older, `year == year(now)` | localized month name ("March") |
| `<Year>` | `year < year(now)` | "2025" |

Months grouped by month (most-recent first); years grouped by year (most-recent first). Empty groups
omitted. **Invariant:** because the buckets are contiguous and time-descending and `summaries` is
globally newest-first, the flattened group order **equals** `summaries` order — which §1.5's
browse-mode select-next relies on. (Unit test asserts this.)

`MeetingGroup` (id/title/meetings) and `secondLineText` are reused. `MeetingListViewModel+Preview`
gains browse/search/empty preview fixtures.

---

## 5. AppShellUI — shell, two-pane, sidebar, toolbar

### 5.1 Content routing → Meetings two-pane

```swift
@ViewBuilder private var detailContent: some View {
    switch viewModel.route {
    case .home:      HomeView(viewModel: viewModel.homeViewModel)
    case .recording: RecordingView(viewModel: viewModel.recordingViewModel)
    case .meetings:  meetingsSplit                       // NEW
    case let .event(key): EventPreviewView(...).id(key)
    case .settings:  SettingsView(viewModel: viewModel.settingsViewModel)
    case .onboarding: EmptyView()
    }
}

private var meetingsSplit: some View {
    HSplitView {
        MeetingListView(viewModel: viewModel.meetingListViewModel)
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
        Group {
            if let id = viewModel.meetingsSelection {
                MeetingDetailView(viewModel: viewModel.meetingDetailViewModel(for: id)).id(id)
            } else {
                ContentUnavailableView("No Meeting Selected", systemImage: "quote.bubble",
                    description: Text("Select a meeting to see its transcript and details."))
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity)
    }
}
```

`HSplitView` (not a nested `NavigationSplitView`) gives a non-collapsing, draggable, resizable divider
— the list is always visible while on this screen, per the spec. Session-only divider position; no
cross-launch persistence (D6).

### 5.2 Sidebar (D9)

Remove the `"PAST"` header + `ScrollView { MeetingListView(...) }`. Add a `pastMeetingsRow` styled like
the existing `homeRow`/`settingsRow`:

```swift
private var pastMeetingsRow: some View {
    Button { viewModel.showMeetings() } label: {
        Label("Past Meetings", systemImage: "clock")   // active when route == .meetings
    } …
    .background(viewModel.route == .meetings ? accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
}
```

Order: Record → (indicator) → Home → **Past Meetings** → Upcoming (when authorized & non-empty) →
Spacer → Settings. The `meetingListViewModel` is no longer in the sidebar — it now backs the content
two-pane (still created once in `AppShellViewModel`).

### 5.3 Toolbar (Home button + title hidden)

```swift
.toolbar {
    ToolbarItem(placement: .navigation) {
        Button { viewModel.showHome() } label: { Image(systemName: "house") }
            .help("Home")
    }
}
```

The `.searchable(text: $searchText, placement: .toolbar, prompt: "Search meetings…")` stays (drives
§2's sync). The window **title text** is removed in the app target (§6), so the Home button occupies
that leading slot.

---

## 6. App target — hide window title

In `AppDelegate` (it already captures the main `NSWindow` for its will-close handler), set
`window.titleVisibility = .hidden` on the main content window (keeping the toolbar, traffic lights,
and draggable title bar). The SwiftUI `Window("Biscotti", id: "main")` scene title stays (drives the
macOS Window menu / app name); only the in-toolbar **title text** is hidden. Pick the exact hook
(on first show / via the existing window reference) during build; **verify on device** (§8).

---

## 7. Removed code

- `SearchUI` module: `SearchView`, `SearchViewModel`, `SearchUITests` → deleted; the `SearchUI` +
  `SearchUITests` targets removed from `Package.swift`; `AppShellUI`/`AppShellView(Model)` drop the
  `import SearchUI` and the `searchViewModel`/`dismissFocusCount`/`onSearch*`/`clearSearch` members.
- `AppCore`: `Route.meeting`, `Route.search`, `searchReturnRoute`, `presentSearch`, `dismissSearch`.
- `AppShellView`: the unused `emptyPlaceholder` (superseded by the `ContentUnavailableView`).

---

## 8. Error handling, edge cases, on-device verification

- **Search failure** → empty results (today's behavior); the list shows
  `ContentUnavailableView.search` (no error surfaced — search is best-effort).
- **Invalid `meetingsSelection`** (selection no longer in `summaries`, e.g. reload without it, not via
  delete) → the container falls back to the placeholder; `MeetingDetailViewModel` already tolerates a
  missing meeting.
- **Delete the only / last meeting** → `neighborID` returns the previous, or nil when none →
  placeholder (covered by §1.5 + unit tests).
- **Typing then clearing fast** → `meetingsSearchTask` cancellation + the `meetingsQuery == query`
  guard prevent stale results (mirrors today's debounce guards).
- **Verify on Apple-silicon hardware (per the repo's SwiftUI caution):** (1) `.inset` `List` pins
  section headers; (2) `NSWindow.titleVisibility = .hidden` hides the title cleanly while keeping the
  toolbar/Home button; (3) `HSplitView` drag + min/ideal/max frames don't clip `MeetingDetailView`;
  (4) `List(selection:)` ↑/↓ updates the detail pane.

---

## 9. Testing strategy

- **AppCore (unit, no SwiftUI — the bulk):** `select` / `selectFromList` / `showMeetings` set
  route+selection+query as specified; `setMeetingsQuery` runs the debounced search via the injected
  `scheduler` (deterministic) and `autoSelectTopResult` keeps a surviving selection else picks the top
  / nil; `neighborID` table tests; `deleteMeeting` select-next in **both** browse and search order,
  incl. last-item and only-item; `stopRecording` → `.meetings` + selection.
- **MeetingListViewModel (unit, pure):** `groupByDateBuckets` boundaries (today/yesterday/7/30/month/
  year, year & month boundaries, empty-bucket omission) and the **flattened-order == summaries-order**
  invariant; `mode` derivation.
- **DataStore (unit):** `meetingSummaries()` (no limit) returns all, still effective-date-desc;
  `meetingSummaries(limit:)` still caps.
- **AppShellViewModel (unit):** query two-way sync forwards/guards; `showMeetings`/`select` effects;
  Past-Meetings/Home active-state.
- **Previews:** Meetings two-pane (selected / placeholder), list browse / search / empty / no-results,
  Home with "See all".
- **App target:** window-title hiding is app-tier/manual (non-gating), per repo convention.
- Migrate the useful assertions from `SearchViewModelTests` into the AppCore search tests; delete the
  rest.

**Manual-test staleness:** this project touches UI modules + `AppCore` only — **not**
`Packages/AudioCapture` or `Packages/Transcription` — so the `ac_*`/`tx_*` staleness rule is **not**
triggered; `manual_test_results.json` is untouched.

---

## 10. Why these choices (pushback applied)

- **`HSplitView` over nested `NavigationSplitView`:** the requirement is an *always-visible*,
  resizable list; a nested split view's column is collapsible and fights the outer one. `HSplitView`
  is the native fixed-two-pane primitive.
- **State in AppCore, not a screen VM:** external entry points + the delete path can't reach a UI
  view-model; one source of truth makes select-next / auto-select / query-clearing consistent and
  unit-testable without SwiftUI. The cost (a fatter AppCore) is contained in an `AppCore+Meetings.swift`
  extension and matches AppCore's existing role (route + async store ops).
- **Remove `SearchUI` rather than keep an empty module:** search is no longer a screen; its only real
  logic (debounced `searchHits`) belongs with the rest of the Meetings state in AppCore. Honest
  topology beats a vestigial module.
- **Lift the cap, no custom paging:** standard SwiftData fetch + lazy `List` (D8); a denormalized
  `effectiveDate` sort column is the right lever *if* counts ever exceed ~1000 — deferred.
```

---
status: complete
---

# Phase 7: Home, Library & Search

## Overview

This phase delivers the full in-window browsing experience: a Home screen with welcome/start/upcoming
preview, live search with ranked results and debounce, and completes the AppShellUI routing so the
detail pane renders Home and Search views (not just a placeholder). The MeetingListUI grouping was
delivered early in Phase 3 and is already complete; Phase 7 verifies it and leaves it as-is.

## What already exists (reuse, don't recreate)

- `MeetingListViewModel.groupByEffectiveDate` -- fully implemented and tested in Phase 3.
- `MeetingListView` -- grouped sidebar past list, complete.
- `AppShellViewModel` -- has `searchText`, `onSearchTextChange`, `clearSearch`, `showHome`,
  `showSettings`, `selectEvent`, `upcomingEvents`, `hasCalendarAccess`, `timeText(for:)`.
- `AppShellView` -- sidebar with Home/Upcoming/Past/Settings, `.searchable` toolbar, detail routing
  (but `.home` and `.search` currently render `emptyPlaceholder`).
- `AppCore.presentSearch` / `dismissSearch` / `searchReturnRoute` -- wired and tested.
- `DataStore.searchHits(_:limit:)` -- weighted search across title/people/transcript, tested.
- `SearchHit`, `SearchField` DTOs -- defined in DataStore+ReadModels.
- `DesignSystem.UpcomingEventRow`, `RecordButton` -- reusable components.
- `CalendarEvent`, `CalendarAuthStatus` -- from Calendar module.
- `PreviewAppCore`, `CoreFixture` / `makeCoreFixture` -- test and preview infrastructure.

## Steps

### 1. Create `HomeUI` module (new target in Package.swift)

Add `HomeUI` target with dependencies: `AppCore`, `Calendar`, `DataStore`, `DesignSystem`.
Add `HomeUITests` test target.

### 2. Implement `HomeViewModel`

File: `Sources/HomeUI/HomeViewModel.swift`

```swift
@MainActor @Observable
public final class HomeViewModel {
    private let core: AppCore

    public init(core: AppCore) { self.core = core }

    public var upcomingPreview: [CalendarEvent] { Array(core.upcoming.prefix(3)) }
    public var startDisabled: Bool { core.runState != .idle }
    public var calendarAccess: CalendarAuthStatus { core.calendar.auth }
    public var showNoUpcoming: Bool { calendarAccess == .authorized && upcomingPreview.isEmpty }
    public var showConnectCalendar: Bool { calendarAccess != .authorized }

    public func startRecording() async { await core.startRecording() }
    public func requestCalendarAccess() async { _ = await core.calendar.requestAccess() }
    public func selectEvent(_ key: String) { core.selectEvent(key) }

    public static func timeText(for event: CalendarEvent, relativeTo now: Date = Date()) -> String
    // same logic as AppShellViewModel.timeText -- extract to shared or call it
}
```

### 3. Implement `HomeView`

File: `Sources/HomeUI/HomeView.swift`

Centered layout: Welcome text, RecordButton, upcoming preview or empty states.

### 4. Create `SearchUI` module (new target in Package.swift)

Add `SearchUI` target with dependencies: `AppCore`, `DataStore`, `DesignSystem`.
Add `SearchUITests` test target.

### 5. Implement `SearchViewModel`

File: `Sources/SearchUI/SearchViewModel.swift`

```swift
@MainActor @Observable
public final class SearchViewModel {
    private let core: AppCore
    public var query: String = ""
    public private(set) var results: [SearchHit] = []
    public private(set) var isSearching: Bool = false
    private var searchTask: Task<Void, Never>?

    public var showNoResults: Bool { !query.isEmpty && results.isEmpty && !isSearching }
    public var noResultsMessage: String { "No meetings match '\(query)'." }

    public func updateQuery(_ newQuery: String)  // debounce 300ms
    public func selectResult(_ meetingID: UUID)   // core.select(meetingID)
    public func dismiss()                          // core.dismissSearch()
    public static func matchedFieldsText(_ fields: [SearchField]) -> String
}
```

### 6. Implement `SearchView`

File: `Sources/SearchUI/SearchView.swift`

Back button + results list or empty state, styled with DesignSystem tokens.

### 7. Wire `AppShellUI` to render `HomeView` and `SearchView`

- Add `HomeUI` and `SearchUI` as dependencies of `AppShellUI`.
- Add `homeViewModel: HomeViewModel` and `searchViewModel: SearchViewModel` to `AppShellViewModel`.
- Update `AppShellView.detailContent`: `.home` renders `HomeView`, `.search` renders `SearchView`.
- Wire `onSearchTextChange` to also update `searchViewModel.updateQuery`.

### 8. Write unit tests

#### HomeUITests
- `homeShowsUpcomingPreview` -- 3 events, shows first 3.
- `homeEmptyWhenNoCalendarAccess` -- `showConnectCalendar == true` when denied.
- `homeNoUpcomingWhenAuthorizedButEmpty` -- `showNoUpcoming == true`.
- `homeStartDisabledWhileRecording` -- `startDisabled == true` when recording.
- `homeTimeTextFormatsRelative` -- static formatting tests.

#### SearchUITests
- `searchReturnsRankedResults` -- after `updateQuery`, results populated.
- `searchDebouncesCancelsPrior` -- rapid calls cancel prior.
- `searchNoResultsShowsMessage` -- empty results state.
- `searchBackRestoresRoute` -- `dismiss()` restores route.
- `searchMatchedFieldsTextFormats` -- formatting helper.
- `searchEmptyQueryClearsResults` -- empty query sets results = [].

#### AppShellUITests (additions)
- `searchTextUpdatesSearchVM` -- verify search VM receives query.

## Tests

- `homeShowsUpcomingPreview`: HomeVM with 5 upcoming events returns 3 in `upcomingPreview`.
- `homeEmptyWhenNoCalendarAccess`: `showConnectCalendar` true when calendar denied.
- `homeNoUpcomingWhenAuthorizedButEmpty`: `showNoUpcoming` true when authorized, no events.
- `homeStartDisabledWhileRecording`: `startDisabled` true during recording.
- `homeTimeTextFormatsRelative`: "in 12m", "in 1h 30m", "now" for various intervals.
- `searchReturnsRankedResults`: updateQuery -> results from store.
- `searchDebouncesCancelsPrior`: rapid calls -> only final query runs.
- `searchNoResultsShowsMessage`: `showNoResults` and message text correct.
- `searchBackRestoresRoute`: dismiss restores pre-search route.
- `searchMatchedFieldsTextFormats`: [.title, .transcript] -> "title, transcript".
- `searchEmptyQueryClearsResults`: updateQuery("") -> results empty.
- `searchTextUpdatesSearchVM`: AppShellVM search text changes propagated to SearchVM.

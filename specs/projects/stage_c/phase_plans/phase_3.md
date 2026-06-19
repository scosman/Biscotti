---
status: complete
---

# Phase 3: Calendar UX + Association (Completes Project 5)

## Overview

This phase wires the Phase 2 `CalendarService` into the UI and coordination layers. It grows
`AppCore` with calendar-aware recording (auto-association via C4), extends the sidebar with
Upcoming events, adds a read-only event preview, enriches Meeting Detail with calendar context
and association correction, and delivers the first slice of Settings (calendar include/exclude).
New DesignSystem components (`UpcomingEventRow`, `CalendarContextBlock`) support the UI additions.

Phase scope is deliberately **UI + coordination** -- the Calendar module (Phase 2) and DataStore
DTOs/methods (Phase 1) are consumed, not extended.

## Steps

### 1. AppCore: add CalendarService dependency and calendar-aware API

**File:** `Sources/AppCore/AppCore.swift`

- Add `Calendar` import and `public let calendar: CalendarService` property.
- Add `public private(set) var upcoming: [CalendarEvent]` (mirrored from calendar.upcoming).
- Add `public private(set) var searchReturnRoute: Route?`.
- Extend `init` to accept `calendar: CalendarService`.
- Change `startRecording()` to `startRecording(eventKey: String? = nil)` with C4 auto-association:
  resolve event via explicit key or `calendar.bestMatch(at:)`, start recording, then associate
  snapshot + participants if a match was found.
- Add navigation: `selectEvent(_:)`, `showHome()`, `showSettings()`, `presentSearch()`,
  `dismissSearch()`, `showOnboardingReplay()`, `completeOnboarding()`.
- Add private `associateEvent(_:with:)` helper for snapshot + participant persistence.
- Extend `onLaunch()` to check `settings().onboardingComplete`, refresh upcoming, start observing.

**File:** `Sources/AppCore/AppCore+Live.swift`

- Build `CalendarService` in the `live()` factory and pass it to `AppCore`.

**File:** `Sources/AppCore/PreviewAppCore.swift`

- Create a `CalendarService` with in-memory store and `FakeEventStoreProviding` for previews.

### 2. DesignSystem: new components

**File:** `Sources/DesignSystem/UpcomingEventRow.swift` (new)

- `UpcomingEventRow(title:timeText:platformBadge:)` -- compact row for sidebar/home/menu upcoming lists.

**File:** `Sources/DesignSystem/CalendarContextBlock.swift` (new)

- `CalendarContextBlock` -- displays conference platform/join link, calendar name+color, organizer,
  attendees, stale indicator, and Change button. Value-type inputs only.

### 3. MeetingListUI: grouped past list

**File:** `Sources/MeetingListUI/MeetingListViewModel.swift`

- Add `MeetingGroup` struct, `groupedMeetings` computed property, and
  `static func groupByEffectiveDate(_:relativeTo:calendar:)`.

**File:** `Sources/MeetingListUI/MeetingListView.swift`

- Replace flat `ForEach` with grouped sections (Today/Yesterday/This Week/Earlier).

### 4. AppShellUI: sidebar Upcoming + Settings + routing

**File:** `Sources/AppShellUI/AppShellViewModel.swift`

- Add `searchText`, `upcomingEvents`, `hasCalendarAccess`, computed state and actions:
  `showHome()`, `showSettings()`, `selectEvent(_:)`, `onSearchTextChange(_:)`, `clearSearch()`.

**File:** `Sources/AppShellUI/AppShellView.swift`

- Extend sidebar: Home row, Upcoming section, Settings row (pinned bottom).
- Wire detail pane: `.home` -> placeholder (HomeUI in Phase 7), `.event(key)` -> `EventPreviewView`,
  `.settings` -> `SettingsView`.
- Add `.searchable` toolbar modifier.

### 5. MeetingDetailUI: calendar context block + association correction

**File:** `Sources/MeetingDetailUI/MeetingDetailViewModel.swift`

- Add `calendarContext`, `showEventPicker`, `showReTranscribeAfterCorrection` state.
- Add `presentAssociationCorrection()`, `correctAssociation(eventKey:)`, `removeAssociation()` actions.

**File:** `Sources/MeetingDetailUI/MeetingDetailView.swift`

- Insert `CalendarContextBlock` section after header (when associated).
- Add quiet "Link a calendar event..." affordance (when unassociated).
- Add `EventPickerSheet` as `.sheet`.

**File:** `Sources/MeetingDetailUI/EventPreviewView.swift` (new)

- Read-only preview of an upcoming calendar event with a Record action.

### 6. SettingsUI: first slice (calendar include/exclude)

**File:** `Sources/SettingsUI/SettingsViewModel.swift` (new, new module)

- Calendar groups, enabled IDs, toggle, permission status, load.

**File:** `Sources/SettingsUI/SettingsView.swift` (new)

- Form with calendar section (grouped by source, toggles with color dot), permissions section.

### 7. Package.swift updates

- Add `Calendar` dependency to `AppCore` target.
- Add `SettingsUI` target with deps: `AppCore`, `Calendar`, `Permissions`, `DesignSystem`.
- Add `SettingsUI` to `AppShellUI` deps.
- Add `Calendar` to `MeetingDetailUI` deps.
- Add `Calendar` to `MeetingListUI` deps (for `CalendarEvent` type in upcoming).
- Add test targets for `SettingsUI` and `MeetingListUI` updates.
- Add `Calendar` and `MeetingCatalog` to `BiscottiTestSupport`.

### 8. BiscottiTestSupport updates

**File:** `Tests/BiscottiTestSupport/CoreFixture.swift`

- Extend `CoreFixture` / `makeCoreFixture` to create and inject `CalendarService`.
- Add `FakeEventStoreProviding` if not already available for test targets.

## Tests

### AppCoreTests (new tests)
- `startRecordingAutoAssociatesBestMatch` -- bestMatch returns event, verify snapshot+participants set.
- `startRecordingExplicitKeyOverridesBestMatch` -- explicit eventKey used over bestMatch.
- `startRecordingNoMatchProceedsUnlinked` -- no match, recording starts without association.
- `selectEventRoutesToEventPreview` -- `selectEvent("key")` sets `route = .event("key")`.
- `searchReturnRouteRestores` -- presentSearch saves, dismissSearch restores.
- `showHome_showSettings_routing` -- navigation method updates route correctly.

### MeetingListUITests
- `pastListGroupsByEffectiveDate` -- meetings across Today/Yesterday/This Week/Earlier grouped correctly.
- `pastListOmitsEmptyGroups` -- only non-empty groups returned.
- `pastListSortsNewestFirst` -- within-group ordering newest first.
- `groupingUsesEffectiveDate` -- startDate used when present, createdAt as fallback.

### MeetingDetailUITests
- `detailShowsCalendarContext` -- after load, calendarContext populated from store.
- `associationCorrectionClearsAndReloads` -- correctAssociation updates snapshot.
- `removeAssociationClearsContext` -- removeAssociation clears calendarContext.

### SettingsUITests (new test target)
- `calendarGroupsBySource` -- calendars grouped by sourceTitle.
- `calendarAllEnabledWhenNil` -- nil enabledCalendarIDs means all enabled.
- `calendarTogglePersistsEnabledIDs` -- toggle updates and persists settings.

### AppShellUITests
- `upcomingEventsReflectsCore` -- upcomingEvents returns core.upcoming.
- `searchTextTriggersPresentSearch` -- non-empty text triggers presentSearch.

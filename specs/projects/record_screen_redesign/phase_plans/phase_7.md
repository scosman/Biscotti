---
status: complete
---

# Phase 7: Recording Pane Event Link/Unlink

## Overview

Add "Link event" and "Unlink event" affordances to the recording pane's submeta
line. The "Link event" flow reuses the existing `EventPickerSheet` from
`MeetingDetailView` and the `correctAssociation`/`removeAssociation` logic from
`MeetingDetailViewModel`. Extract the shared picker + association VM logic so
both the meeting-detail screen and the recording pane use the same code without
duplication. After linking, the submeta switches from ad-hoc to event mode;
after unlinking, it reverts to ad-hoc.

## Steps

1. **Extract shared event-picker protocol/capabilities into `RecordingViewModel`.**
   Add to `RecordingViewModel`:
   - `showEventPicker: Bool` (bindable, drives the `.sheet`)
   - `availableEvents: [CalendarEvent]` (populated by `loadNearbyEvents()`)
   - `hasCalendarAccess: Bool` (reads `core.calendar.auth`)
   - `func presentLinkEvent() async` -- sets `showEventPicker = true` and calls
     `loadNearbyEvents()`
   - `func loadNearbyEvents() async` -- calls `core.eventsNear(detail.date)`
   - `func correctAssociation(eventKey: String?) async` -- delegates to
     `core.correctAssociation(meetingID:eventKey:)`, reloads detail + summaries
   - `func removeAssociation() async` -- calls `correctAssociation(eventKey: nil)`

2. **Extract `EventPickerSheet` into a shared, generic form.**
   Move `EventPickerSheet` out of `MeetingDetailView.swift` into a new file
   `DesignSystem/EventPickerSheet.swift` (or keep in `MeetingDetailUI` and have
   RecordingUI import it -- actually, since RecordingUI does NOT currently import
   MeetingDetailUI, a cleaner approach is to extract the sheet into DesignSystem
   which both modules already import). Define a protocol `EventPickerDataSource`
   that the sheet reads from, implemented by both `MeetingDetailViewModel` and
   `RecordingViewModel`.

   Actually, simpler: use a closure-based sheet view that takes the data it needs
   as parameters rather than binding to a specific VM type. The sheet needs:
   `availableEvents`, `hasCalendarAccess`, `hasCalendarContext`, and action
   closures for `correctAssociation(eventKey:)`, `removeAssociation()`, and
   dismiss.

3. **Update `RecordingView` submeta.**
   - **Ad-hoc submeta**: replace the static "No calendar event" text with a
     "Link event" sage text link (same style as "Open in calendar") that calls
     `viewModel.presentLinkEvent()`.
   - **Event submeta**: add an "Unlink event" link after "Open in calendar"
     (same dot-separator + sage text link style) that calls
     `viewModel.removeAssociation()`.
   - Add `.sheet(isPresented: $viewModel.showEventPicker)` presenting the shared
     `EventPickerSheet`.

4. **Wire reloadDetail to pick up linked/unlinked state.**
   The existing `summariesVersion` observer already calls `reloadDetail()` which
   refreshes `detail`. Since `correctAssociation` calls `reloadSummaries()`, the
   submeta will switch modes automatically when the detail reloads.

5. **Update `MeetingDetailView` to use the extracted `EventPickerSheet`.**
   Refactor `MeetingDetailView`'s inline `EventPickerSheet` to use the shared
   version.

## Tests

- **`testLinkEventSwitchesSubmetaToEvent`**: start recording ad-hoc, verify
  `hasEvent == false`, call `correctAssociation(eventKey:)`, reload, verify
  `hasEvent == true` and calendar fields populated.
- **`testUnlinkEventSwitchesSubmetaToAdHoc`**: start recording with event
  linked, verify `hasEvent == true`, call `removeAssociation()`, reload, verify
  `hasEvent == false`.
- **`testPresentLinkEventSetsShowPickerAndLoadsEvents`**: call
  `presentLinkEvent()`, verify `showEventPicker == true` and `availableEvents`
  is populated.
- **`testHasCalendarAccessDelegates`**: verify `hasCalendarAccess` reflects
  `core.calendar.auth`.

---
status: complete
---

# Phase 7: EventKitLab (E2)

## Overview

Build a disposable macOS SwiftUI reference app at `/experiments/EventKitLab/` that exercises the EventKit research recommendation from R2. The app requests full calendar access, lists calendars with include/exclude toggles, reads events from selected calendars over a date range, displays all useful fields including regex-extracted conferencing URLs, snapshots event data into our own types, and provides a "Dump data report" that outputs every useful field EventKit exposes. Additionally, integrates the Contacts framework to measure the enrichment gain over EKParticipant alone, surfacing a side-by-side comparison.

## Steps

### 1. Project scaffold
- Create `project.yml` for XcodeGen matching AudioLab's pattern: macOS 15+, arm64, ad-hoc signing, non-sandboxed, Swift 6.2.
- Info.plist with `NSCalendarsFullAccessUsageDescription` and `NSContactsUsageDescription`.
- App entry point (`EventKitLabApp.swift`) with a multi-tab SwiftUI layout: Permission, Calendars, Events, Data Report.
- Bundle ID: `com.biscotti.experiments.eventkitlab`.

### 2. Snapshot model types
- `CalendarEventSnapshot`: our own Codable struct capturing all useful EKEvent/EKCalendarItem fields.
- `AttendeeSnapshot`: our own Codable struct for each attendee.
- `EventLinkKey`: composite key (eventIdentifier + calendarItemIdentifier + occurrenceStartDate) for re-linking.
- Mapping functions from EKEvent/EKParticipant to snapshot types.

### 3. Conference URL extraction
- `ConferenceDetector`: scans event url, notes, and location fields with regex patterns for Zoom, Google Meet, Teams, Webex, Slack Huddle.
- Returns optional `ConferenceInfo` (url + platform name).

### 4. Calendar access manager
- `CalendarAccessManager`: ObservableObject wrapping EKEventStore.
- Check/request full access via `requestFullAccessToEvents()`.
- Handle all authorization states including deprecated `.authorized`.
- Expose calendars, events, and status to SwiftUI.

### 5. Calendar filtering
- List all calendars from `calendars(for: .event)`.
- Toggle include/exclude per calendar, persisted in UserDefaults as a Set of calendarIdentifier strings.
- Default all enabled.

### 6. Event fetching and display
- Date range picker (start/end).
- Fetch events with `predicateForEvents(withStart:end:calendars:)` passing filtered calendars.
- Display: title, start/end, isAllDay, attendees, organizer, notes, location, structuredLocation, url, conferencing info.

### 7. Contacts enrichment comparison
- `ContactsEnricher`: uses CNContactStore + EKParticipant.contactPredicate to look up full contact details.
- `EnrichedAttendee`: struct combining EKParticipant-only data with Contacts-enriched data.
- Side-by-side UI showing "EKParticipant only" vs "enriched with Contacts" for each attendee.
- Request Contacts access, handle denial gracefully.

### 8. Data dump report
- "Dump data report" action: iterates selected events and outputs every field from the snapshot model plus raw EKEvent properties.
- Output as formatted text, copyable to clipboard.

### 9. SwiftUI views
- `PermissionView`: shows current auth status, request button, System Settings link for denied.
- `CalendarsView`: grouped list of calendars by source with toggles.
- `EventsView`: date range picker, event list with detail expansion, Contacts enrichment comparison.
- `DataReportView`: dump report output with copy button.

### 10. VALIDATION.md
- Write the V2 manual test script.

### 11. Unit tests
- Snapshot mapping: EKEvent-like data mapped correctly to CalendarEventSnapshot.
- Conference URL regex: test each platform pattern against known URLs.
- Composite key generation and equality.
- Calendar filter logic (include/exclude).
- Contacts enrichment merge logic.

## Tests

| Test | What it validates |
|------|-------------------|
| `testConferenceURLDetection` | Zoom, Meet, Teams, Webex, Slack URLs correctly extracted from notes/location/url |
| `testConferenceURLNoMatch` | Non-conference text returns nil |
| `testCompositeKeyEquality` | Same identifiers + date produce equal keys; different dates produce different keys |
| `testCompositeKeyHashing` | Keys work correctly in sets |
| `testAttendeeSnapshotMapping` | EKParticipant-like data maps correctly to AttendeeSnapshot |
| `testEventSnapshotMapping` | Full event data maps correctly to CalendarEventSnapshot |
| `testCalendarFilterLogic` | Enabled/disabled calendars correctly filter event lists |
| `testEnrichedAttendeeComparison` | Enriched vs non-enriched attendees correctly compared |
| `testEmailParsingFromURL` | mailto: URL parsing extracts email correctly |

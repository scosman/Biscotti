---
status: complete
---

# Phase 11 G5: Upcoming / Event Detail Page

## Overview

Enriches the event preview page (route `.event(key)`) to show full event details, adds time-based action buttons (Open Link vs Join and Record), and fixes conference platform display names in BundledMeetingCatalog.

## Steps

1. **Enrich `CalendarEvent` DTO** with `attendees: [AttendeeInfo]`, `organizer: AttendeeInfo?`, `notes: String?`, `location: String?` fields. Add `AttendeeInfo` value type (name + email). Update `CalendarService.refreshUpcoming` mapping from `EKEventDTO` to populate these new fields.

2. **Fix conference platform display names** in `BundledMeetingCatalog`: change the `compiledPatterns` platform strings from lowercase abbreviations to human-friendly names: "meet" -> "Google Meet", "zoom" -> "Zoom", "teams" -> "Microsoft Teams", "webex" -> "Cisco Webex", "slack" -> "Slack Huddle". Update existing tests.

3. **Extend `EventPreviewViewModel`** with:
   - Injectable `currentDate: () -> Date` for deterministic tests
   - Injectable `urlOpener: (URL) -> Void` seam (defaults to `NSWorkspace.shared.open`)
   - `ActionButton` enum: `.openLink`, `.joinAndRecord`, `.record`
   - `primaryAction` computed property: >15min before start -> `.openLink` (only if URL); within +/-15min -> `.joinAndRecord` (only if URL); fallback -> `.record`
   - `showSecondaryRecord: Bool` — show manual Record when primary is `.openLink` or `.joinAndRecord`
   - `openLink()` method
   - `joinAndRecord()` method — opens URL AND starts recording with event key

4. **Redesign `EventPreviewView`** to display all event details: title, date range, calendar badge, platform, location, organizer, attendees list, notes, meeting URL. Add time-based action buttons from VM.

5. **Update ripple sites**: any existing consumers of `CalendarEvent.conferencePlatform` that `.capitalized` the platform name should be checked (now the platform is already human-friendly).

## Tests

- `platformNameIsGoogleMeet`: BundledMeetingCatalog returns "Google Meet" for meet.google.com links
- `platformNameIsZoom`: returns "Zoom" for zoom.us links
- `platformNameIsTeams`: returns "Microsoft Teams" for teams.microsoft.com links
- `platformNameIsWebex`: returns "Cisco Webex" for webex.com links
- `platformNameIsSlackHuddle`: returns "Slack Huddle" for slack huddle links
- `primaryActionOpenLinkWhenFarFuture`: >15min before start with URL -> `.openLink`
- `primaryActionJoinAndRecordWhenNearStart`: within +/-15min with URL -> `.joinAndRecord`
- `primaryActionRecordWhenNoURL`: any time without URL -> `.record`
- `primaryActionRecordWhenFarFutureNoURL`: >15min before start without URL -> `.record`
- `primaryActionJoinAndRecordAtExactBoundary`: at exactly 15min before -> `.joinAndRecord`
- `secondaryRecordShownWithOpenLink`: secondary record shown when primary is openLink
- `secondaryRecordShownWithJoinAndRecord`: secondary record shown when primary is joinAndRecord
- `noSecondaryRecordWhenPrimaryIsRecord`: no secondary when primary is record
- `joinAndRecordOpensURLAndStartsRecording`: triggers both URL open and startRecording(eventKey:)
- `openLinkOpensURL`: triggers URL open only
- `eventDetailsExposed`: VM exposes attendees, organizer, notes, location from enriched CalendarEvent

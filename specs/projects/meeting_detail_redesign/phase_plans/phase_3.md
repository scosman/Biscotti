---
status: complete
---

# Phase 3: Calendar card + data

## Overview

Add `eventNotes` to the DataStore read model, build the `SourcePill` and
`CalendarInfoCard` views in DesignSystem, and expose a `calendarCard`
computed property on the view model with testable helpers for `whenText`
and `invitedText`. This prepares the building blocks for the Phase 4
screen assembly.

## Steps

1. **Add `eventNotes` to `CalendarContextData`** (`DataStore/DataStore+ReadModels.swift`):
   - Add `public let eventNotes: String?` property and update the `init`.
   - In `DataStore.calendarContext(meetingID:)`, pass
     `snapshot.eventNotes` (empty string maps to nil).

2. **Add `SourcePill` view** (`DesignSystem/SourcePill.swift`, new file):
   - `Label(platform, systemImage: "video.fill")`, `.font(.system(size: 11, weight: .medium))`,
     icon `.foregroundStyle(.sage)`, text `.inkSecondary`,
     `Tokens.neutralChip` background, `Capsule()` clip, height 19,
     `.padding(.horizontal, 7)`.

3. **Add `CalendarCardData` struct** (`DesignSystem/CalendarInfoCard.swift`, new file):
   - `CalendarCardData` with fields: `attendees: [AvatarPerson]`,
     `attendeeTotal: Int`, `summary: AttributedString`,
     `whenText: String?`, `platform: String?`, `conferenceURL: URL?`,
     `location: String?`, `eventNotes: String?`, `invitedText: String?`.

4. **Add `CalendarInfoCard` view** (`DesignSystem/CalendarInfoCard.swift`):
   - Row A: `AvatarCluster` + summary text + Spacer + "Open in Calendar"
     soft secondary button.
   - Divider (`.hairline`).
   - Row B: `DisclosureGroup("Description")` with collapsed preview line
     and expanded definition list Grid (WHEN / WHERE / DESCRIPTION / INVITED).
   - Card styling: `RoundedRectangle(cornerRadius: 12)`, `Tokens.cardFill`,
     0.5pt `Color.cardStroke`, inner padding `spacingMD`.

5. **Add `calendarCard` computed property to `MeetingDetailViewModel`**
   (`MeetingDetailUI/MeetingDetailViewModel.swift`):
   - `public var calendarCard: CalendarCardData?` that maps `calendarContext`
     to `CalendarCardData`.
   - Pure helpers: `whenText(start:end:)` and `invitedText(organizer:attendees:)`.

6. **Add `hasAudioFiles` and `revealInFinder()` to `MeetingDetailViewModel`**:
   - `public var hasAudioFiles: Bool` from loaded audio refs.
   - `public func revealInFinder()` using `NSWorkspace.shared.activateFileViewerSelecting`.

## Tests

New file: `MeetingDetailUITests/CalendarCardTests.swift`

- `whenText formats date range`: verify correct format for same-day events.
- `whenText returns nil when no dates`: verify nil output.
- `invitedText includes organizer tag and attendees`: verify format like
  "Steve (organizer) \u{00B7} Alex \u{00B7} Jay".
- `invitedText shows +N overflow for many attendees`: verify overflow count.
- `invitedText returns nil when no attendees and no organizer`: verify nil.
- `calendarCard returns nil when no calendar context`: verify nil mapping.
- `calendarCard populates all fields from context`: verify correct mapping.
- `eventNotes populated from snapshot`: verify the DataStore wiring.
- `hasAudioFiles reflects audio refs state`: verify true/false.

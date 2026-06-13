---
status: in-progress
---

# Phase 2: Home rebuild (ViewModel + View + wiring)

## Overview

Assemble the Phase 1 foundations (DesignSystem tokens/views, MeetingTiming,
DataStore participants) into the redesigned Home screen. Extends HomeViewModel
with greeting, stat chips, hero detection, avatar mapping, and actions; rebuilds
HomeView to the agent_spec design; wires urlOpener in AppShellViewModel.

## Steps

### 1. HomeViewModel — add urlOpener injection

Update `HomeViewModel.init` to accept a `urlOpener: @escaping (URL) -> Void`
closure, defaulting to `{ _ in }`. Store as a private property.

### 2. HomeViewModel — greeting and date text

Add computed properties:
- `greeting: String` — "Good morning" / "Good afternoon" / "Good evening"
  based on `core.minuteTick` hour
- `dateText: String` — formatted as "EEEE, MMMM d" from `core.minuteTick`

### 3. HomeViewModel — stat chip derivations

Add:
- `private var todaysMeetings: [CalendarEvent]` — filters
  `core.displayedUpcoming` to meeting-like events on the same calendar day
- `meetingsLeftText: String?` — "{n} meetings left today", nil when no access
- `nextInText: String?` — coarse relative time of first upcoming, nil when none
- `showStatChips: Bool` — `calendarAccess == .authorized`

### 4. HomeViewModel — hero detection

Add:
- `heroEvent: CalendarEvent?` — first upcoming event within
  `MeetingTiming.joinWindowSeconds`
- `heroIsRecordOnly: Bool` — `heroEvent?.conferenceURL == nil`
- `recordDisabled: Bool` — `core.recording.state.isRecording`

### 5. HomeViewModel — actions

Add:
- `func joinAndRecord(_ e: CalendarEvent) async` — open URL via urlOpener
  if present, start recording with event key
- `func openInCalendar(_ e: CalendarEvent)` — open Calendar.app at event date
  via urlOpener

### 6. HomeViewModel — avatar and names mapping

Add:
- `func avatarData(for e: CalendarEvent) -> (people: [AvatarPerson], total: Int)`
- `func avatarData(for m: MeetingSummary) -> (people: [AvatarPerson], total: Int)`
- `func pastSecondLine(for m: MeetingSummary) -> String` — existing
  meetingSecondLine + participant names

### 7. HomeView — rebuild

Complete rebuild of `HomeView.swift`:
- `#FBFBFC` content background
- Vertically-centered 800-wide column via GeometryReader
- Greeting block + stat chips row
- "UPCOMING" group label + card with hero/ordinary rows
- "PAST MEETINGS" group label with "See all" link + card
- All using Phase 1 components (AvatarCluster, StatChip, MeetingPlatformChip,
  homeCard, InsetDivider, JoinRecordButtonStyle)
- Empty/permission states restyled into cards

### 8. AppShellViewModel — inject urlOpener

Change `HomeViewModel(core: core)` to
`HomeViewModel(core: core, urlOpener: { NSWorkspace.shared.open($0) })`.

### 9. Tests — HomeViewModelTests extensions

Add test suites:
- Greeting boundaries (09:00/14:00/20:00), dateText format
- Stat chips: meetingsLeftText with same-day/other-day events,
  nextInText present/absent (coarse tiers), showStatChips false when not authorized
- Hero: heroEvent non-nil at <=15m, nil at >15m, nil when empty;
  heroIsRecordOnly; recordDisabled
- Actions: joinAndRecord opens URL + starts recording; record-only skips URL;
  openInCalendar produces ical:// URL
- Mapping: avatarData dedup + total; pastSecondLine with/without names

## Tests

- `HomeViewModelGreetingTests`: greeting for morning/afternoon/evening; dateText
  format validation
- `HomeViewModelStatChipTests`: meetingsLeftText, nextInText derivations
  (coarse tiers); showStatChips false when not authorized
- `HomeViewModelHeroTests`: heroEvent within/outside window; heroIsRecordOnly;
  recordDisabled
- `HomeViewModelActionTests` (extended): joinAndRecord, openInCalendar
- `HomeViewModelMappingTests`: avatarData dedup, pastSecondLine formatting

---
status: built; real-tenant check pending
---

# Phase 3: Integration — Microsoft 365 as the calendar source

## Overview

Microsoft 365 calendars feed `CalendarService`, so Home's upcoming list,
the meeting prompt, the event picker, meeting links and speaker naming all
use Graph events. `GraphEventStore` serves `EventStoreProviding` from
memory, `GraphCalendarPoller` fills it, and AppCore's
`Microsoft365CalendarSync` ties both to the Phase 2 account. With an app
registration, Microsoft 365 replaces Apple Calendar in Settings, Home and
onboarding. Without one, the app is upstream's (see Deviations).

## Steps

1. **`GraphEventStore` (GraphCalendar):** `EventStoreProviding` over a
   `Mutex`-guarded snapshot (calendars, events, the window read, the fetch
   time) plus the events around one past date for the picker.
   - `events(in:calendars:)` returns overlapping events, zero-length ones
     included, filtered by calendar (`nil` is all, `[]` is none). It merges
     the picker's events (the snapshot wins on a clash) and sorts by start.
   - `refreshEvent` answers from memory.
   - `authorizationStatus` is whatever `setAccess` last set; `requestAccess`
     prompts for nothing and returns whether that is `.authorized`.
   - `replace(with:)` reports whether anything changed and clears the stale
     flag; `markStale()` and `clear()`.
2. **`GraphCalendarPoller` (actor, GraphCalendar):**
   - polls every 5 min, and 1 min before each timed event (at least 15 s
     apart);
   - reads every calendar over the last day and the next 8 days, which
     covers the 7-day upcoming window and the picker around a recent
     recording;
   - reads `/me` once per account;
   - concurrent `refresh()` calls share one poll, and `start()` begins its
     first poll at once so a `refresh()` right after joins it;
   - `stop()` keeps the snapshot. `reset()` clears it and bumps a
     generation, so a poll from before the reset reports `.superseded` and
     writes nothing;
   - a failed poll keeps the snapshot and marks it stale;
   - `loadNearby(around:)` reads ±1.5 h around an older date the snapshot
     doesn't cover;
   - each poll's `GraphSyncOutcome` (`.synced(changed:)`, `.failed`,
     `.superseded`) goes to an outcome handler.
3. **`CalendarService` (Calendar):** `Notification.Name.calendarProviderDidChange`,
   declared beside `EventStoreProviding`. `startObserving()` observes it as
   well as `.EKEventStoreChanged`. `refreshUpcoming` re-reads `auth` from the
   provider, since signing in or out changes it without `requestAccess()`.
4. **`Microsoft365CalendarSync` (`@MainActor @Observable`, AppCore):**
   - owns the store and poller, and follows `GraphAccountController.state`
     through observation tracking. Transitions run in order:
     - signed in: for a new account, reset and clear the calendar
       selection; then report `.authorized` and start polling;
     - sign-in expired: stop polling and keep the snapshot;
     - signed out: reset, and report `.notDetermined`;
   - posts `.calendarProviderDidChange` on each change and each poll that
     changed something;
   - polls again on wake (`NSWorkspace.didWakeNotification`) and when the
     network comes back (`NWPathMonitor`);
   - `prepare(around:)` runs `loadNearby` for the picker, up to 5 s;
   - `lastSynced`, `lastSyncFailure` and `syncErrorMessage` for Settings.
5. **Composition:** `AppCore+Live` builds the sync when
   `GraphAccountController.live()` is configured and gives `CalendarService`
   its `GraphEventStore`; otherwise `LiveEventStore`. `AppCore` owns it as
   `microsoft365Calendar`, starts it in `onLaunch()`, and
   `AppCore.eventsNear` prepares it before reading.
6. **SettingsUI:**
   - the account's calendars (shared ones added in Outlook included) are
     listed under the Microsoft 365 row, with the existing include/exclude
     toggles;
   - "Reading your calendars…" until the first poll, "No calendars found in
     this account." when there are none;
   - the row shows "Synced just now" or "Synced <relative time>";
   - poll failures show in red under the row;
   - without a registration, the Apple list is back, as upstream.
7. **OnboardingUI:** with a registration, the permissions step shows a
   Microsoft 365 Connect row in place of Calendar access, and "granted" means
   signed in. `proceed()` polls before the calendar step, which lists the
   Graph calendars, with a Microsoft 365 empty state and read error.
8. **ManualTestKit:** the "M365 Calendar" script (`m365_calendar`,
   `m365_*` steps), registered in `allScripts`. Its recordable steps are
   `not-run` in `ManualTestApp/Results/manual_test_results.json`.
9. **Tests:**
   - `GraphEventStoreTests` and `GraphCalendarPollerTests` (fake transport,
     recorded sleeper);
   - `Microsoft365CalendarSyncTests` (AppCore) against `StubGraphTenant`
     through `BiscottiTestSupport`'s `Microsoft365CalendarHarness`. It covers
     sign-in, sign-out, the per-account selection reset, offline, the picker
     on an older date, and invitee emails reaching speaker naming (below);
   - `OnboardingMicrosoft365Tests`, `SettingsMicrosoft365CalendarTests`, and
     `CalendarServiceTests`' provider-change suite;
   - `ScriptShapeTests` for the new script.

## Attendee emails → speaker naming

`inviteeEmailsReachSpeakerNaming` covers the whole path:
1. A Graph event has an organizer and an attendee with mixed-case emails.
2. A meeting links to it through `eventsNear` and `correctAssociation`.
3. Both appear as "Name <email>" in the speaker prompt's meeting details.
4. Both emails, lowercased, are in `VoiceprintEvidence`'s invitee emails,
   which drive the voiceprint invitee boost.

## Deviations and decisions

- **EventKit stays without a registration.** The plan removed the Apple
  Calendar fallback outright. The registration is per tenant and set with
  `defaults write` or MDM, not compiled in. A build without it would
  otherwise have no calendar at all: CI, upstream contributors, or a Mac that
  hasn't been set up. So `AppCore+Live` picks the source once at launch:
  - with a registration, Microsoft 365 only (Settings, Home and onboarding
    show no Apple Calendar);
  - without one, upstream's EventKit, unchanged.
- **Calendar selection kept and reset per account.** The plan dropped the
  Apple calendar selection from `SettingsViewModel`. Instead, the same
  `enabledCalendarIDs` holds Graph calendar IDs, so a shared or noisy
  calendar can still be excluded. EventKit's or another account's IDs would
  hide every Graph calendar, so the selection is cleared the first time each
  account signs in. The `microsoft365CalendarSelectionAccount` default
  records which account the selection belongs to. Signing out and back in
  to the same account keeps it.
- **The picker reads on demand.** The snapshot reaches back one day. For an
  older recording, `eventsNear` waits up to 5 s while the poller reads
  ±1.5 h around it, then shows what it has. Only the latest such window is
  kept.
- **"Before the record prompt" is a scheduled poll.** It runs 1 min before
  each timed event, so the upstream prompt path is untouched.
- **`refreshEvent` answers from memory.** A linked event is at most one poll
  old, which saves a Graph request per link.
- **No polling while the sign-in has expired.** The last snapshot keeps the
  upcoming list until Reconnect.
- **Functional spec §8:** Q1 has a debug log (`All-day bounds:`, category
  `GraphCalendar`) with the raw wire form. Q4: unreadable calendars (403,
  404) are skipped with `Skipping calendar …` in the log. Both are settled
  by the `m365_all_day` and `m365_shared_calendar` manual steps.

## Real-tenant check

Tracked as the ManualTestApp "M365 Calendar" steps; record results there.
`m365_relaunch` and `m365_disconnect` also cover Phase 2's outstanding
checks.

- [ ] `m365_connect`: sign-in, calendar list, sync time
- [ ] `m365_upcoming`: Home's list and the calendar toggles
- [ ] `m365_new_event`: a new Outlook meeting appears within 5 min
- [ ] `m365_all_day`: Q1
- [ ] `m365_shared_calendar`: Q4
- [ ] `m365_picker`: an older recording links to a Graph event
- [ ] `m365_speaker_names`: attendees drive speaker names
- [ ] `m365_onboarding`
- [ ] `m365_relaunch`: restore without signing in; keychain prompt
- [ ] `m365_offline`
- [ ] `m365_disconnect`

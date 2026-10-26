---
status: in-progress
---

# Implementation Plan: Microsoft 365 Calendar (Graph)

Three phases, matching the overview. Each ends green on
`make precommit-checks` (format + lint + test) and is reviewable on its own.

## Phases

- [x] **Phase 1 — `GraphCalendar` module: client, mapping, fixture tests**
  The `GraphCalendar` product/target and `GraphCalendarTests` in
  `Packages/BiscottiKit`. Wire types, `GraphClient` (paging, trusted
  nextLink, 401 refresh, Retry-After/backoff, 4-request cap), date and zone
  parsing, HTML → text, `GraphEventMapper` (functional spec §4) and
  `GraphCalendarReader`. No sign-in: the token is injected through
  `GraphAccessTokenProviding`. Tests run against recorded-shape JSON fixtures
  and a fake transport (architecture §3).
  *Status:* complete. `make precommit-checks` (format, lint and all package
  tests, `GraphCalendarTests` included) passed on 2026-10-23.

- [ ] **Phase 2 — Sign-in**
  A `GraphAuth` target: OAuth 2.0 authorization code + PKCE against Entra
  ID's v2 endpoints, in `ASWebAuthenticationSession`. No MSAL; see
  `phase_plans/phase_2.md`. `GraphTokenProvider` caches the access token,
  refreshes silently and rotates the refresh token, which lives in the login
  keychain. `GraphAccountController` is owned by `AppCore`. The client and
  tenant IDs come from user defaults or `Info.plist` keys. Adds the
  Settings → Calendars "Microsoft 365" row, the Home reconnect banner and
  `docs/entra_app_registration.md`. The Apple calendar list was removed
  from Settings (Microsoft 365 replaces Apple Calendar; functional spec §7).
  *Status:* built; `make precommit-checks` green. A real sign-in against the
  Synderys tenant worked on 2026-10-26. Restore on relaunch and Disconnect
  are still to check (`m365_relaunch` and `m365_disconnect` in the Phase 3
  manual test).

- [ ] **Phase 3 — Integration**
  `GraphEventStore` (snapshot-backed sync seam), `GraphCalendarPoller`, a
  provider-agnostic change signal in `CalendarService.startObserving`, and
  `AppCore+Live` composition with `GraphEventStore` replacing EventKit (no
  `CompositeEventStore`, no dedupe). Replaces the Apple Calendar permission
  row and onboarding step with a "Connect Microsoft 365" step, removes the
  Apple calendar selection state from `SettingsViewModel`, and adds the
  ManualTestApp "M365 Calendar" tab. Adds a test that Graph attendee emails
  reach speaker identification: the invitee list in the speaker prompt and
  the voiceprint invitee boost (functional spec §7). Settles the open questions in
  functional spec §8 on a real tenant.
  *Status:* built; see `phase_plans/phase_3.md`. As built:
  - EventKit stays the source when no app registration is configured;
  - the calendar selection is kept for Graph calendars, reset once per
    account;
  - `AppCore.Microsoft365CalendarSync` ties the poller to the account.
  Awaiting the "M365 Calendar" manual test on the Synderys tenant, which
  also settles §8 Q1 and Q4.

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
  MSAL (SPM) in a `GraphAuth` target, an `MSALGraphTokenProvider` with the
  keychain cache and silent refresh, and interactive sign-in from the
  Settings window. Client and tenant IDs go in `Info.plist`; the
  `msauth.com.synderys.biscotti` redirect scheme in `App/project.yml`. Adds
  the Settings → Calendar "Microsoft 365" row and the reconnect banner.
  `docs/` gets an Entra registration guide for IT. Prerequisite: the Entra app
  registration for bundle ID `com.synderys.biscotti`.

- [ ] **Phase 3 — Integration**
  `GraphEventStore` (snapshot-backed sync seam), `GraphCalendarPoller`,
  `CompositeEventStore` with iCalUID dedupe, a provider-agnostic change
  signal in `CalendarService.startObserving`, `AppCore+Live` composition,
  the onboarding step, the "Also read Apple Calendar" setting, and the
  ManualTestApp "M365 Calendar" tab. Settles the open questions in
  functional spec §8 on a real tenant.

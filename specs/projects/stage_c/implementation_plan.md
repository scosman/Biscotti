---
status: complete
---

# Implementation Plan: Stage C — V1 Feature Layering

Dependency-ordered phases. **Built autonomously** — each phase runs as: coding agent (writes a
`phase_plans/phase_N.md`, implements, adds tests) → green `precommit_checks` (lint+test) → spec-aware
code review → commit. **No human stop between phases.** The **final phase is the human review** pass.
Details live in `functional_spec.md`, `ui_design.md`, `architecture.md`, and `components/`; this file
is the ordered checklist. Confirmed core decisions: `review_for_human.md` (C1–C8).

**Manual-test staleness:** Stage C consumes but does **not edit** `Packages/AudioCapture` /
`Packages/Transcription` source, so the `ac_*`/`tx_*` staleness rule is not triggered. If a phase must
touch those packages, mark the affected manual tests `not-run` per the repo rule.

**Gating per phase:** `make ci` (lint + test + build) stays green. Module/service/VM phases are fully
unit-tested (gating). UI/app-target phases also rely on `build_app` (non-gating) to prove the app +
`MenuBarExtra` + XPC compile/link.

## Phases

- [x] **Phase 1 — Foundation deltas.** `DataStoreSchemaV2` (additive: `AppSettings.onboardingComplete`,
  `enabledCalendarIDs`) + migration stage; settings read/write (`settings()`/`updateSettings`); new
  read DTOs (`AppSettingsData`, `CalendarContextData`, `PersonData`, `TranscriptVersionData`,
  `SearchHit`) + their query methods incl. transcript-text `searchHits`; effective-date sort; the
  `MeetingCatalog` tiny L0 target + `BundledMeetingCatalog` (watchlist + conference regexes
  productionized from EventKitLab, cached); `Permissions` calendar+notifications seams/state; `Route`
  extension. *(arch §4, §7, §9; unblocks everything.)*

- [x] **Phase 2 — Calendar module.** `CalendarService` + `EventStoreProviding` seam + `EKEventDTO`
  mapping, auth/status mapping, enabled-calendar filtering, meeting-like filter, conference detection
  (via catalog), composite key, snapshot mapping (`CalendarSnapshotInput`→`CalendarSnapshot`+`Person`),
  `bestMatch(at:)`, `startObserving`/staleness. Full unit tests. *(components/calendar.md; Project 5
  core. Depends on Phase 1.)*

- [x] **Phase 3 — Calendar UX + association (completes Project 5).** `AppCore` grows:
  `calendar` service, `upcoming` mirror, `startRecording(eventKey:)` auto-association (C4),
  `selectEvent`, calendar permission relay. `MeetingListUI`/`AppShellUI` sidebar **Upcoming** list;
  `.event(key)` read-only preview with Record; `MeetingDetailUI` calendar-context block + association
  correction; `SettingsUI` first slice (calendar include/exclude). *(functional §1; ui_design §1–5;
  components/ui_modules.md, app_core.md. Depends on Phase 2.)*

- [x] **Phase 4 — MeetingDetection module.** `MeetingDetector` + `ActivitySource` seam + per-app
  in-call state machine + helper→parent mapping + debounce + `events()` stream. Unit tests over
  synthetic activity. *(components/meeting_detection.md; Project 6 part 1. Depends on Phase 1.)*

- [x] **Phase 5 — Notifications module.** `NotificationService` + `NotificationCenterProviding` seam +
  categories/actions per kind + content + countdown lifecycle + `actions()` stream + auth (relayed to
  Permissions). Unit tests over the seam. *(components/notifications.md; Project 6 part 2. Depends on
  Phase 1.)*

- [x] **Phase 6 — Background coordination + menu bar (completes Project 6).** `AppCore` background
  slice: `AppScheduler` clock seam, calendar-start timers + reschedule, detection consumption + de-dup,
  auto-stop countdown, notification-action dispatch, `RunState`, onboarding gate. `MenuBarUI`
  (icon/body states). App target: `MenuBarExtra`, `SMAppService` launch-at-login (default on),
  don't-quit-on-close + quit-while-recording, `UNUserNotificationCenterDelegate` glue,
  `NSCalendarsFullAccessUsageDescription`. *(functional §2; ui_design §7–8; components/app_core.md,
  ui_modules.md. Depends on Phases 2, 4, 5.)*

- [x] **Phase 7 — Home, Library & Search.** `HomeUI` (welcome + Start + upcoming preview + empty
  states); `SearchUI` (live takeover, ranked hits, back-restore, debounce); `MeetingListUI` rich
  grouping (Today/Yesterday/This Week/Earlier — grouping delivered early in Phase 3);
  `AppShellUI` full sidebar + toolbar search + routing.
  (Transcript-text search landed in Phase 1.) *(functional §3; ui_design §1,2,4; components/ui_modules.md.
  Depends on Phase 3.)*

- [x] **Phase 8 — Rich Meeting Detail (completes Project 7).** Audio playback (`AudioPlaybackProviding`
  seam + transport, disabled when audio missing); transcript-version picker; notes autosave;
  association-correction full flow (+ offer re-transcribe). *(functional §3.5; ui_design §3;
  components/ui_modules.md. Depends on Phases 3, 7.)*

- [ ] **Phase 9 — Vocabulary + TranscriptionService.** **Important -- deferred for now, The SDK can't use vocabulary as discovered in main. Skip this phase. A fix is planned to SDK, but this is blocked for now.** `VocabularyService` (app-wide read/write,
  per-meeting merge, dedup/cap); `TranscriptionService` init `(store:engine:vocabulary:)`, consume
  effective vocab in `runEngine`, `ensureModelsReady`/`modelsReady`. Update all callers
  (`AppCore.live`, previews, tests). Unit tests. *(functional §4.4; arch §10. Depends on Phase 1.)*

- [x] **Phase 10 — Onboarding & Settings (completes Project 8 = feature-complete V1).** `OnboardingUI`
  wizard (Welcome → Microphone → System Audio → Calendar+selection → Notifications → Model download
  (skippable, disk check + progress) → Done; everything-up-front, skippable — C3/C8); `SettingsUI`
  full (custom vocab, launch-at-login, consolidated calendar, permissions overview); onboarding gate +
  `completeOnboarding` wiring; `SMAppService` toggle. *(functional §4; ui_design §5–6;
  components/ui_modules.md. Depends on Phases 3, 6, 9.)*

- [ ] **Phase 11 — Human review, feedback & bug fixing.** User reviews the feature-complete V1 on real
  Apple-silicon hardware; we work through `review_for_human.md` (C1–C8 + the autonomous calls), fix
  bugs, and tune interaction/UX details together. The only phase with a human in the loop.

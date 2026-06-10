# Stage C — Review for Human

Running log of decisions for the final **human review, feedback & bug-fixing** phase. The top section records the **core decisions confirmed during specing** (Option 1). The lower section records **smaller calls made autonomously during development** (Option 2) — review these and flag anything to change.

---

## Core decisions confirmed during specing (Option 1)

| # | Decision | Choice | Notes / implication |
|---|----------|--------|---------------------|
| C1 | **RemoteConfig sourcing** | **Hardcoded, no RemoteConfig module** | Keep the meeting-app bundle-ID watchlist and conference-URL regexes compiled into the app for V1. Diverges from `architecture.md` (which gives RemoteConfig its own module). We keep a clean seam (a config-provider type backed by bundled constants) so a real RemoteConfig module can slot in later without re-topology. OTA deferred. |
| C2 | **Auto-record policy** | **Always notify, never auto-record** | Detection only ever fires a notification with a Record action. Recording starts solely on explicit user action. No auto-record setting in V1. |
| C3 | **Onboarding permissions** | **Wizard requests everything up front** | Onboarding requests calendar, microphone, system-audio, and notifications (each with a pre-permission explainer), plus model download. Diverges from the research's "audio is contextual" recommendation — accepted for a complete first-run setup. |
| C4 | **Event ↔ recording association** | **Auto-attach best match, allow correction** | On record start, auto-attach the in-progress/imminent calendar event (prefer conference-link events); user can correct/clear it in Meeting Detail and re-transcribe. |
| C5 | **Settings & Onboarding presentation** | **All in the main window** | No separate macOS Settings scene; Settings and Onboarding are in-window (onboarding = first-launch full-window takeover; settings = an in-window route). |
| C6 | **'Upcoming' list scope** | **Meeting-like events only** | Upcoming shows timed events that look like meetings: those with a detected conference link, plus multi-attendee events. Exclude all-day and solo appointments. |
| C7 | **App runtime presence** | **Dock + window + menu bar** | Regular app (Dock icon + main window) plus a `MenuBarExtra`. Closing the last window does NOT quit — app keeps running in the tray. |
| C8 | **Model download in onboarding** | **Skippable, with disk check** | Offer download with progress + disk check, but allow Skip; if skipped, models download on first transcription. |

---

## Smaller decisions made autonomously (Option 2)

> Appended as development proceeds. Each is a call I made without stopping; review and flag any to revisit.

- **Conference-link detection**: productionize `experiments/EventKitLab/ConferenceDetector` into the `Calendar` module; regex patterns hardcoded (per C1), with compiled `NSRegularExpression` instances cached. Detect from `event.url` → `event.location` → `event.notes` (priority order). URL-only — **no phone dial-in detection** in V1.
- **Meeting-app watchlist**: source of truth stays the existing `AudioCapture.AudioProcess.knownMeetingBundleIDs` seed list (per C1), consumed by `MeetingDetection` via a small config-provider seam. Includes helper-process bundle IDs (WebKit GPU, avconferenced, Slack helper) per `research/audio/meeting_app_bundle_ids.md`.
- **All-day events**: excluded from upcoming/detection/notifications. No "include all-day" setting in V1.
- **Auto-stop**: 15s countdown, applies to detection-driven recordings when the detected app's audio stops; manual recordings do not auto-stop. Tapping the notification keeps recording. Countdown duration is a single named constant.
- **System-audio permission status**: keep Stage B's silence-detection inference; do **not** adopt the private TCC preflight API.
- **Transcript-text search**: SwiftData term matching (split terms, case-insensitive `contains`/LIKE) across title / participant names / transcript segment text; title weighted higher than transcript; sort by score. No FTS (Project 13 if warranted).
- **Calendar snapshot refresh**: re-sync on `.EKEventStoreChanged` + app launch; mark snapshot stale if the source event is deleted.
- **Recurring-series grouping**: deferred (P2).
- **Onboarding demo step**: deferred (P2).
- **Per-recording manual vocab additions**: deferred (P3).
- **Audio file-usage view + deletion in Settings**: deferred (P3).

### Phase 1 implementation decisions

- **Schema V2 abandoned in favor of staying on V1**: SwiftData's `VersionedSchema` requires distinct model snapshots per version, but in SPM both V1 and V2 schemas reference the same live `@Model` classes. This caused a CoreData checksum crash during test discovery. Since the new `AppSettings` properties (`onboardingComplete`, `enabledCalendarIDsData`) have defaults, SwiftData handles them automatically without any explicit migration stage. Reverted to V1-only; the migration plan remains as scaffolding for future breaking changes.
- **`audioFileRefs` return type**: replaced a 3-member tuple `(mic: URL?, system: URL?, present: Bool)` with a dedicated `AudioFileRefsResult` struct to satisfy SwiftLint's `large_tuple` rule.
- **`Permissions.refresh()` became async**: `NotificationAuthorizing.status()` is async (UNUserNotificationCenter's API is async), so `Permissions.refresh()` must be async to call it. All callers updated. Backward-compatible: existing callers that don't inject `cal`/`notif` seams get the same sync behavior for mic, just wrapped in an `async` signature.
- **MeetingCatalog target is L0 (no dependencies)**: it compiles stand-alone watchlist data and regex patterns. No target depends on it yet in Phase 1; Calendar and MeetingDetection will consume it in later phases.
- **`searchHits` refactored for lint compliance**: extracted per-meeting scoring into a private `scoreMeeting(_:terms:)` helper to stay within the 50-line function body limit.
- **Conference-link detection placed in MeetingCatalog, not Calendar**: per the spec, both Calendar and MeetingDetection need conference detection. Placing it in MeetingCatalog (an L0 module) avoids a circular dependency and follows the spec's "config-provider seam" intent from C1.

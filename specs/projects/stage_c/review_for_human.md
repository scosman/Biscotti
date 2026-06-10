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

### Phase 2 implementation decisions

- **`EKEventDTO` is public**: made the DTO public (not module-internal) so that tests can construct scripted DTOs for the `EventStoreProviding` fake. The seam protocol requires returning `[EKEventDTO]`, so test targets must be able to create them.
- **`CalendarService.loadEnabledCalendarIDs` is async**: the spec shows it loading from settings at init, but `DataStore` is an actor, so reading settings requires an `await`. Instead of a semaphore bridge (which causes Swift 6 sendability errors), the load happens in `refreshUpcoming` before each fetch. The enabled-IDs cache is `nil` (all calendars) until the first refresh.
- **ObservationBox for deinit cleanup**: Swift 6 makes `deinit` nonisolated, so `CalendarService` cannot access `@MainActor`-isolated stored properties in deinit. Used a plain class wrapper (`ObservationBox`) to hold the NotificationCenter observer token so deinit can clean it up.
- **`markSnapshotStale` and `recentMeetingsWithSnapshots` added to DataStore**: the spec mentions staleness checking but didn't specify DataStore methods for it. Added two methods to `DataStore+Phase3_2.swift` plus a `SnapshotStalenessEntry` DTO for the query result.

### Phase 3 implementation decisions

- **Extracted `persistSnapshot` helper in AppCore**: the snapshot-building and participant-persistence logic was duplicated between `associateEvent` and `correctAssociation`. Extracted into a private `persistSnapshot(_:for:)` method to satisfy swiftlint body-length limits and DRY the code.
- **Onboarding gate in `onLaunch`**: when `onboardingComplete` is false, `onLaunch` routes to `.onboarding` and returns early without starting calendar observation. Pre-existing tests that called `onLaunch` expecting `.home` were updated to mark onboarding complete first.
- **`Color(hex:)` made public**: the hex-color initializer in DesignSystem needed to be public for SettingsUI (which imports DesignSystem) to use it for calendar color dots.
- **SettingsUI depends on AppKit**: both `SettingsView` and `SettingsViewModel` use `NSWorkspace.shared.open(url)` for deep-linking to System Settings privacy panes; requires `import AppKit`.
- **`CalendarContextBlock` uses value-type inputs only**: no view model; all data flows in via init parameters. This keeps the component reusable across MeetingDetail and EventPreview without coupling to a specific VM.
- **`MeetingGroup` grouping is a pure static function**: `MeetingListViewModel.groupByEffectiveDate` takes `[MeetingSummary]` and returns `[MeetingGroup]` with no service dependencies, enabling direct unit testing without fixtures.
- **`makeCoreFixture` swiftlint disable**: the factory function grew to 55 lines with the calendar service wiring; added a targeted `swiftlint:disable:next function_body_length` rather than splitting the function, since it's a test fixture factory where all setup is logically related.

### Phase 4 implementation decisions

- **`AnyClock` type-erased wrapper instead of generic `MeetingDetector<C: Clock>`**: the component spec calls for an injectable clock, but making `MeetingDetector` generic over a clock type would force all consumers to parameterize it. Used a small `AnyClock` struct that wraps any `Clock` with `Duration == Swift.Duration` via closure-based type erasure. Simpler API surface, same deterministic-test benefit.
- **`EventCollector` test helper pattern**: directly calling `for await event in stream` on the `@MainActor` blocks the MainActor and prevents the detector's snapshot processing task from running, causing deadlocks. Created an `EventCollector` class that iterates the stream in a separate `Task` and provides `waitForEvents(count:timeout:)` / `settle()` methods that yield the MainActor.
- **Two test clocks (`ImmediateClock` + `NeverClock`)**: `ImmediateClock` completes `sleep` immediately (for tests that want debounce to fire), `NeverClock` never returns from `sleep` (for tests that verify behavior during the debounce window). Both conform to `Clock` protocol; cancellation-aware.
- **Test split into 4 files**: the original single test file exceeded SwiftLint's type body length limit (~350 lines). Split into `TestHelpers.swift`, `MeetingDetectionTests.swift` (heuristic tests), `HelperResolutionTests.swift`, and `DebounceAndLifecycleTests.swift`.
- **Cold-build cache warming**: Phase 4's full cold rebuild approached the hooks-mcp 60s per-call timeout; worked around by warming the build cache across successive calls. Human: consider raising the hooks-mcp timeout if this recurs in later phases.
- **Stabilized flaky CalendarServiceTests** (out of Phase 4 scope, fixed to keep the gate green): pinned file-scope date constants and `makeDTO` defaults to a fixed reference instant (`Date(timeIntervalSince1970: 1_700_000_000)`) instead of `Date()`, eliminating time-of-day dependence in `bestMatch` and window assertions.

### Phase 5 implementation decisions

- **`makeRequest` extracted as a free function**: `UNMutableNotificationContent` created inside `@MainActor` methods cannot be sent to the nonisolated `NotificationCenterProviding.add(_:)` protocol method without a Swift 6 "sending risks data race" error. Extracted request building into a private module-level free function (nonisolated) so the returned `UNNotificationRequest` can cross the isolation boundary cleanly.
- **`handleResponseValues` public testable bridge**: `UNNotificationResponse` has no public initializer, making it untestable directly. Added `handleResponseValues(categoryID:actionID:userInfo:)` as a public entry point that the tests drive. `handleResponse(_:)` (taking the real `UNNotificationResponse`) is a thin wrapper that extracts the three values and delegates.
- **`FakeNotificationCenter` uses `@unchecked Sendable` backing**: Swift 6 strict concurrency makes it difficult to have a `Sendable` protocol conformance that stores state on `@MainActor`. Used an `@unchecked Sendable` reference-type backing store (safe because all tests run on `@MainActor`).
- **`FakeNotificationCoder` for `UNNotification` in foreground tests**: `UNNotification` requires an `NSCoder` to construct. Created a minimal `NSCoder` subclass that encodes a `UNNotificationRequest` and a date, sufficient for `foregroundPresentationOptions(for:)` to read the category identifier.

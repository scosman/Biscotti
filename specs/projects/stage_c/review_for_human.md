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
- **Meeting-app watchlist**: source of truth stays the existing `AudioCapture.AudioProcess.knownMeetingBundleIDs` seed list (per C1), consumed by `MeetingDetection` via a small config-provider seam. Includes helper-process bundle IDs (WebKit GPU, avconferenced, Slack helper) per `specs/research/audio/meeting_app_bundle_ids.md`.
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

### Phase 6 implementation decisions

- **`AppScheduler` clock seam**: introduced an `AppScheduler` protocol with `sleep(for:)` and `now()` to make timer-dependent code (calendar-start timers, auto-stop countdown) deterministic in tests. `LiveAppScheduler` wraps `ContinuousClock`; `FakeScheduler` (in BiscottiTestSupport) records pending sleeps and lets tests advance time explicitly. The existing `MeetingDetector.AnyClock` is separate (operates at the detection level); `AppScheduler` operates at the AppCore coordination level.
- **`FakeActivitySource` and `FakeTestNotificationCenter` use `@unchecked Sendable` backing pattern**: same approach as Phase 5's `FakeNotificationCenter` -- conforming to `Sendable` protocols while storing mutable state via a reference-type backing store. Not `@MainActor` so the protocol conformance works for nonisolated protocol requirements.
- **Notification action dispatch via `handleResponseValues`**: tests drive the notification action flow by calling `handleResponseValues(categoryID:actionID:userInfo:)` on `NotificationService` with the correct namespaced identifiers, then polling for the consumer task to process the action. Direct integration tests through the `MeetingDetector` were avoided due to the debounce complexity (already covered in Phase 4 MeetingDetection tests).
- **`@preconcurrency UNUserNotificationCenterDelegate`**: Xcode 26.2 SDK marks `UNUserNotificationCenter` and `UNNotificationResponse` as non-Sendable. The `@MainActor` delegate methods in `AppDelegate` caused "non-Sendable parameter type cannot be sent" errors. Used `@preconcurrency` on the protocol conformance and extracted Sendable data (category/action IDs, userInfo) before crossing isolation boundaries. `didReceive` now calls `handleResponseValues` instead of `handleResponse` to avoid touching the non-Sendable response after extraction. Also fixed action ID comparisons to use the actual namespaced identifiers (`biscotti.action.join`, etc.).
- **`MenuBarExtra` with `.window` style**: menu bar body uses `.menuBarExtraStyle(.window)` for a popover-style UI (richer than `.menu`). Label shows recording dot or next-meeting preview. Content shows recording controls, upcoming events (max 2), recent meetings (max 2), and Open/Quit actions.
- **`SMAppService.mainApp.register()` for launch-at-login**: called once in `buildCore()` when status is `.notRegistered`. Non-fatal if it fails -- user can enable from Settings later.
- **Removed two superfluous `swiftlint:disable:next function_body_length` directives**: SwiftFormat shortened `onLaunch()` and `completeOnboarding()` enough that the disable comments became orphaned doc comment violations.
- **`MenuBarViewModel` formatting helpers are `nonisolated static`**: `truncateTitle`, `relativeTimeText`, `isWithin2Hours`, and `formatElapsed` are pure functions that don't need MainActor isolation. Marked `nonisolated static` so tests can call them from nonisolated contexts without `@MainActor` annotation.
- **`formatElapsed` inlined in MenuBarViewModel**: rather than importing RecordingUI (which would add a dependency), the elapsed-time formatting was duplicated as a `nonisolated static` method on `MenuBarViewModel`.

### Phase 7 implementation decisions

- **Consolidated `relativeTimeText` into `DesignSystem/TimeFormatting`**: three view models (HomeViewModel, AppShellViewModel, MenuBarViewModel) all needed the same relative-time formatting for upcoming events. Extracted the logic into a shared `TimeFormatting.relativeTimeText` helper in `DesignSystem`; each VM's `timeText`/`relativeTimeText` static method now delegates to it.
- **`MeetingListUI` grouping verified, not modified**: Phase 3's `groupByEffectiveDate` and `MeetingListView` grouped display already satisfy the Phase 7 spec completely. No changes needed -- the existing tests cover grouping correctness.
- **`SearchViewModel.debounceAndSearch` uses `Task.sleep` for debounce**: a simple cancelling-task pattern (cancel prior task on each keystroke, sleep 300ms, then search) rather than Combine's `debounce`. Keeps the module Combine-free and is straightforward to test by waiting past the debounce window.
- **`AppShellViewModel` propagates search text to `SearchViewModel`**: `onSearchTextChange` and `clearSearch` both forward the query to `searchViewModel.updateQuery`, keeping the search VM's state in sync with the toolbar `.searchable` binding without the search VM needing to observe the shell VM.

### Phase 8 implementation decisions

- **`AudioPlaybackProviding` protocol is nonisolated `AnyObject`**: the seam protocol is not `@MainActor` since `AVAudioPlayer` is nonisolated. The `FakeAudioPlayer` in tests uses `@unchecked Sendable` (safe because tests are single-threaded on MainActor), matching the established fake pattern from Phases 5-6.
- **Injectable player factory via `makePlayer` closure**: `MeetingDetailViewModel.init` takes an optional `makePlayer: () -> any AudioPlaybackProviding` (defaults to `AVAudioPlayerWrapper()`). Tests inject `FakeAudioPlayer` through this seam without touching AVFoundation.
- **`VersionPicker` uses `VersionPickerItem` value type, not `TranscriptVersionData`**: DesignSystem has no dependencies, so the picker takes its own lightweight `VersionPickerItem` struct. The view maps `TranscriptVersionData` to `VersionPickerItem` at the call site.
- **Notes autosave uses cancelling-task debounce**: same pattern as `SearchViewModel` (Phase 7) -- cancel the prior task on each keystroke, sleep 1s, then persist. `flushNotes()` for immediate save on navigation away.
- **`reTranscribeAfterCorrection()` wires the re-transcribe prompt to the actual transcription path**: Phase 3 showed the prompt but the "Re-transcribe" button on it called the same `reTranscribe()`. Phase 8 adds a dedicated `reTranscribeAfterCorrection()` that dismisses the prompt flag before triggering transcription, keeping the UX clean.
- **`onJobStatusChange` resets version selection**: when a transcription job completes, the VM clears `selectedVersionID` and `selectedTranscript` so the display automatically shows the new preferred version.

### Phase 10 implementation decisions

- **Custom vocabulary editing stubbed with "Coming soon"**: per the scope adjustment, Phase 9 (Vocabulary) is deferred. SettingsUI includes a vocabularySection with explanatory text and a `vocabularyDeferred: Bool = true` flag. A TODO marks the future integration point.
- **Calendar auth in onboarding uses `CalendarService.requestAccess()`**: OnboardingViewModel requests calendar permission through `core.calendar.requestAccess()` (which routes through the `EventStoreProviding` seam) rather than `core.permissions.requestCalendar()`. This enables test fixtures to use `FakeEventStore` for deterministic auth results. The VM maps `CalendarAuthStatus` to `PermissionState` and also calls `core.permissions.noteCalendar(...)` to keep the Permissions module consistent.
- **System-audio permission probe via `RecordingController.probeSystemAudioAndInferState()`**: added a new public method on `RecordingController` that creates a throwaway recorder, runs the system-audio probe, waits briefly, and infers permission state from the silence-detection heuristic. AppCore exposes this as `requestSystemAudioPermission()`. No private TCC API used (per Phase 4/6 precedent).
- **Model-readiness methods on TranscriptionService**: added `ensureModelsReady(status:)` and `modelsReady()` as thin wrappers over the existing `engine.ensureModelsDownloaded(status:)`. No vocabulary wiring (deferred).
- **`SMAppService` toggle in SettingsViewModel only**: `setLaunchAtLogin` persists to `AppSettings.launchAtLogin` and calls `SMAppService.mainApp.register()`/`.unregister()`. The registration call is wrapped in a do/catch (non-fatal if it fails). No separate service layer -- the VM handles it directly since it's a single call site.
- **OnboardingView split into two files**: `OnboardingView.swift` (struct + body + step router, ~75 lines) and `OnboardingStepViews.swift` (extension with individual step views + helpers, ~240 lines) to stay within SwiftLint's 250-line `type_body_length` limit.
- **`OnboardingViewModel` accessed via `viewModel` property (not `@Bindable private`)**: changed `viewModel` to internal access so the extension in the separate file can reference it.

### Phase 10 CR fixes

- **Launch-at-login source of truth changed to `SMAppService.mainApp.status`**: `SettingsViewModel.load()` now reads system status via an injectable `readLaunchAtLoginStatus` closure (defaults to `SMAppService.mainApp.status == .enabled`). This prevents drift when the user toggles launch-at-login in System Settings > Login Items. The stored `AppSettings.launchAtLogin` is still persisted on toggle but is no longer the displayed source of truth. Added a test asserting the toggle reflects the injected system status.
- **`StatusCollector` made thread-safe**: added `NSLock` around the `_messages` array in `TranscriptionServiceTests.StatusCollector` to protect against concurrent append/read across isolation boundaries.
- **Stabilized flaky `cancelAllThrowsCancellation` FakeScheduler test** (out-of-Phase-10-scope build-stability fix): replaced bare `Task.yield()` with `pollUntil` to ensure the inner task is actually suspended inside `withCheckedThrowingContinuation` before `cancelAll()` fires, and that the catch block has executed before asserting. Applied the same fix to `advanceResumesPendingSleeps` and `partialAdvanceLeavesRemaining` for consistency. Confirmed stable across 3 consecutive test runs.
- **Disk-check seam added to `OnboardingViewModel`**: injectable `availableDiskBytes` closure (defaults to real filesystem check). Test now deterministically drives both the low-disk warning path and the sufficient-disk path.
- **Stabilized debounce-timed SearchUI and MeetingDetailUI tests** (post-Phase-10 build-stability): replaced fixed `Task.sleep` waits with `pollUntil` polling in `SearchViewModelTests` (5 tests) and `MeetingDetailPhase8Tests` (ticker + notes autosave, 2 tests). Confirmed stable across 3 consecutive runs.

---

## Phase 11 human-review resolutions (2026-06-10)

User reviewed the autonomous calls above. **Recorded only — not yet implemented** (changes happen during Phase 11, alongside UI feedback).

| # | Item | Resolution | Action |
|---|------|-----------|--------|
| 1 | All-day events (currently fully excluded, no setting) | **Confirmed** — keep fully excluded | none |
| 2 | Auto-stop countdown (15s) | **Confirmed** — keep 15s | none |
| 3 | Custom-vocabulary Settings section (currently disabled "Coming soon" stub) | **CHANGE** — **hide the section entirely** until the deferred Phase 9 SDK vocab fix lands; leave a `// TODO` at the integration point. Also part of forthcoming UI feedback. | **TODO (Phase 11)** |
| 4 | Conference-link detection (URL-only; no phone/dial-in) | **Confirmed** — URL-only for V1 | none |
| — | Lower-priority deferrals: no-FTS transcript search; system-audio permission via silence-inference (no private TCC preflight); recurring-series grouping (P2); onboarding demo step (P2); per-recording manual vocab (P3); audio file-usage view + deletion in Settings (P3) | **Confirmed** as-is / deferred | none |

**Pending Phase 11 actions from this review:** (3) hide the custom-vocab Settings section + leave TODO.

### Phase 11 G1 implementation decisions

- **Launch-at-Login `setLaunchAtLogin` uses same pattern as SettingsViewModel**: persists to `AppSettings.launchAtLogin` via `DataStore.updateSettings` and calls `SMAppService.mainApp.register()`/`.unregister()`. Injectable `readLaunchAtLoginStatus` seam for tests (matches SettingsVM).
- **`SMAppService.mainApp.unregister()` is async**: unlike `register()` (sync throws), `unregister()` requires `await`. Discovered during compilation; fixed.
- **Test file split for type_body_length**: new granted-state and launch-at-login tests moved to `OnboardingGrantedAndLoginTests.swift` to keep both test files under the 250-line body-length limit.
- **Notification permission TODO left in place**: `// TODO(notifications): onboarding notification permission request not functioning on-device -- revisit` added at the `.notifications` case in `requestPermission()`. Step remains in the flow and is skippable.
- **Architecture.md G7 reconcile**: updated section 7 to state that conference-link detection (`conferenceMatch`) lives in `MeetingCatalog` (L0), not in Calendar or a RemoteConfig split. Minimal wording change; no topology change needed (code was already correct).

### Phase 11 G2 implementation decisions

- **Custom Vocabulary section removed entirely**: deleted `vocabularyDeferred` property and `vocabularySection` view. Left a single `// TODO(vocab):` comment at the top of `SettingsViewModel` for future re-addition.
- **Re-run Onboarding removed**: deleted the Advanced section and `rerunOnboarding()` from `SettingsViewModel`. `AppCore.showOnboardingReplay()` remains for potential future use; just not exposed in Settings.
- **Section reorder**: Permissions now appears above Calendars (Calendars is last).
- **Per-permission request buttons**: each permission row shows "Request Access" when `.notDetermined` (triggers the real OS prompt), "Open Settings" when `.denied` (deep link), or nothing when `.authorized`. Microphone uses `Permissions.requestMicrophone()`, system audio uses `AppCore.requestSystemAudioPermission()`, calendar uses `CalendarService.requestAccess()` + `noteCalendar()`, notifications uses `Permissions.requestNotifications()`.
- **Stale permission status fix**: added `AppCore.refreshAllPermissions()` which syncs mic from its seam, calendar from `CalendarService.auth` (EventKit ground truth), and notifications from `NotificationService.isCurrentlyAuthorized()`/`isDenied()`. Called in `SettingsViewModel.load()` before displaying the overview. Added `NotificationService.isCurrentlyAuthorized()` and `isDenied()` public methods.
- **`makeCoreFixture` extended**: added optional `calendarAuthorizer` and `notificationAuthorizer` parameters so tests can inject fake seams for Permissions. Created `FakeCalendarAuthorizer` and `FakeNotificationAuthorizer` in BiscottiTestSupport (previously test-file-local in PermissionsTests).

### Phase 11 G3a implementation decisions

- **Editable title**: replaced the `Text(viewModel.title)` header with an inline `TextField` bound to `viewModel.editableTitle`. Enter key triggers `saveTitle()` which trims whitespace, persists via `DataStore.setTitle(_:for:)`, and refreshes the summaries list. Blanking the field reverts to the stored title. Title is also flushed in `flushNotes()` (on disappear).
- **Auto-title without date**: changed `RecordingController.autoTitle` from `"Recording \u{2014} <date>"` to just `"Recording"`. The date parameter is kept in the method signature for compatibility but is no longer used in the format string.
- **Calendar context visual bug (item 3 finding: visual/loading, not persistence)**: investigated and confirmed the bug is **visual/loading (b)**, not a persistence issue. The `CalendarContextBlock` component renders correctly when data is present. The `CalendarSnapshot` persists properly via `setSnapshot`. The `calendarContext` DTO is loaded in `load()` from `detail?.calendar`. Added `startDate` and `endDate` fields to `CalendarContextData` for richer display. The likely real-hardware issue was timing-related (context data not yet loaded when the view rendered).
- **Re-transcribe prompt hidden**: `showReTranscribeAfterCorrection` is now always `false`. The underlying flag, plumbing (`reTranscribeAfterCorrection()`, `dismissReTranscribePrompt()`), and view conditional all remain in place with `// TODO(re-transcribe-prompt)` markers for Phase 9 restoration.
- **Join button 30-min gate**: added `showJoinButton` computed property with injectable `currentDate` closure for deterministic testing. Uses `effectiveMeetingEnd` (calendar endDate > recording endDate > date+duration fallback). The `CalendarContextBlock`'s `onJoin` closure is nil when hidden.
- **Playback total-time TODO**: added `// TODO(playback-duration)` comment in the view at the `AudioTransport` call site documenting the AAC/ADTS container-header issue. No code fix.
- **`DataStore.setTitle(_:for:)`**: new method mirroring the existing `setNotes` pattern. Looks up the meeting by ID, sets the title, and saves.
- **`MeetingDetailData.endDate`**: new optional field populated from `MeetingRecord.endDate`, used by the Join-button time gate.
- **17 new tests** in `MeetingDetailG3aTests.swift` covering all G3a items: editable title round-trip, saveTitle persistence, blank-title revert, auto-title format, re-transcribe suppression, Join button visibility (recent/old/in-progress/no-URL/boundary), and calendar context loading.
- **Phase 8 re-transcribe tests updated**: two existing tests that expected `showReTranscribeAfterCorrection == true` after `correctAssociation` were updated to expect `false`, with TODO comments for Phase 9 restoration.

### Phase 11 G3a CR fixes

- **Removed dead `title` computed property**: `editableTitle` is the source of truth; the `title` getter was equivalent after `load()` and no view consumed it. Two tests updated to assert on `editableTitle` directly.
- **Dropped unused `date` param from `autoTitle()`**: the parameter was kept for forward-compat but had no callers using the value. Removed for cleanliness; call site updated.
- **Strengthened calendar-context test**: replaced the two-VM `calendarContextLoadsFromPersistedSnapshot` test with `singleVMAssociateThenVerify` which uses a single VM: loads with no association (asserts `hasCalendarContext == false`), calls `correctAssociation(eventKey:)`, then asserts context fields populate on the same VM instance. Exercises the user's reported symptom path directly. Required passing `calendarRefreshResult` to `makeCoreFixture` so `FakeEventStore.refreshEvent` returns the DTO during snapshot creation.
- **Extracted `makeEventDTO` helper**: reduces `EKEventDTO` boilerplate in association/correction tests; used by both the calendar-context and re-transcribe-prompt tests.

### Phase 11 G3b implementation decisions

- **Dual-file synced playback via `AudioPlaybackProviding` protocol change**: changed `load(url:)` to `load(urls: [URL])` so the seam accepts one or two audio files. `AVAudioPlayerWrapper` creates one `AVAudioPlayer` per URL; on `play()` with two players, uses `play(atTime: deviceCurrentTime + 0.05)` on both to start sample-aligned via the shared device clock. Pause, seek (`currentTime` setter), and stop apply to all players. `duration` reports the longer of the two; `currentTime` tracks the primary (first) player.
- **Added `streamCount` to protocol**: new read-only property exposing how many audio streams are loaded (0, 1, or 2). Used by tests to verify dual-file loading; not consumed by the VM or views.
- **`loadAudioPlayer` collects both URLs**: the VM now gathers whichever URLs exist from `audioFileRefs` (mic, system, or both) into an array and passes them all to the player. Single-file (mic-only or system-only) works transparently; no-file returns `canPlay == false`.
- **Tests split into separate file**: `MeetingDetailDualPlaybackTests.swift` with two suites (loading + controls, 13 tests total) to stay under the 250-line type body length lint limit. Uses a file-local `DualFakePlayer` fake to avoid type conflicts with the existing `FakeAudioPlayer` in Phase 8 tests.
- **Sync approach limitation**: true sample-accurate sync is not achievable behind the `AudioPlaybackProviding` seam (which models a single combined player). The production `AVAudioPlayerWrapper` uses `play(atTime:)` with a 50ms lead for device-clock-aligned start, which is the best practical sync for two `AVAudioPlayer`s. The unit tests verify that both URLs are loaded and that play/pause/seek commands reach the player; real audio sync is verified on hardware.

### Phase 11 G4 implementation decisions

- **Back-button bug root cause**: `AppCore.presentSearch()` was called on **every keystroke** by `AppShellViewModel.onSearchTextChange`. After the first character, the route was already `.search`, so subsequent calls overwrote `searchReturnRoute` from the real prior page (e.g. `.meeting(id)`) to `.search`. Result: first Back tap restored `.search` (appeared to do nothing); second tap fell back to `.home` (the nil fallback). **Fix**: added an idempotency guard -- `presentSearch()` now returns immediately if `route == .search`, preserving the originally captured return route.
- **Search notes field**: added `.notes` case to `SearchField` enum. `scoreMeeting` now checks `meeting.notes` text with weight 1 (same as transcript). The `fieldSortOrder` places notes after transcript (index 3). `SearchViewModel.matchedFieldsText` handles the new case.
- **Immediate clear + spinner on query change**: moved `results = []` and `isSearching = true` **before** the `Task` creation in `debounceAndSearch()`. The debounce sleep and search still happen inside the task, but stale results are cleared synchronously on each keystroke. Empty-query path unchanged (clears results, sets `isSearching = false`, no spinner).
- **Search field unfocus (item 1)**: `@FocusState` lives in `AppShellView` (where `.searchable` is declared), bound via `.searchFocused($isSearchFieldFocused)`. `SearchViewModel` exposes a `dismissFocusCount: Int` counter that bumps on `selectResult`, `dismiss`, and `dismissFocus` (background tap). `AppShellView` observes this via `.onChange` and sets `isSearchFieldFocused = false`. `SearchView` uses a `.background { Color.clear.contentShape(Rectangle()).onTapGesture }` underlay for background taps (does not compete with child buttons, unlike `.onTapGesture` on the outer VStack). View-level; no unit test (SwiftUI focus state is not testable headlessly).
- **Nav-stack TODO (item 5)**: placed `// TODO(nav-stack): migrate AppShell from single-Route replacement to a NavigationStack path so tapping a search result PUSHES (Back returns into the search results). Medium refactor -- its own follow-up.` in `SearchView` at the result selection site.
- **12 new tests**: 5 DataStore notes-search tests (`notesOnlyMatch`, `notesRankedBelowTitle`, `notesCaseInsensitive`, `notesAndTranscriptBothMatch`, `emptyNotesNoMatch`); 5 SearchViewModel tests (immediate clear, empty-query no spinner, stale-clear during debounce, matchedFieldsText with notes, back-from-meeting route); 2 back-button tests (idempotent presentSearch from event page, back-from-meeting via AppShellViewModel `onSearchTextChange` flow).

### Phase 11 G5 implementation decisions

- **CalendarEvent DTO enriched with 4 new fields**: `organizer: AttendeeInfo?`, `attendees: [AttendeeInfo]`, `notes: String?`, `location: String?`. All new init params have defaults (nil/empty) so existing callers don't break.
- **`AttendeeInfo` struct**: `name: String?`, `email: String?`, computed `displayName` (prefers name, falls back to email, then "Unknown"). Sendable + Equatable. Lives in `CalendarTypes.swift`.
- **CalendarService attendee mapping extracted**: `attendeeInfo(from:)` private helper maps `AttendeeDTO` to `AttendeeInfo` using `EmailParser.email(from:)`. Keeps `refreshUpcoming` body within the type_body_length lint limit.
- **Platform display names changed in BundledMeetingCatalog**: `compiledPatterns` now use human-friendly names ("Zoom", "Google Meet", "Microsoft Teams", "Cisco Webex", "Slack Huddle") instead of short keys ("zoom", "meet", etc.). Removed `.capitalized` from `CalendarContextBlock` display since names are already properly cased.
- **Time-based action buttons with injectable "now"**: `EventPreviewViewModel` has `currentDate: () -> Date` for deterministic tests. `primaryAction` computed property returns `.openLink` (>15min before), `.joinAndRecord` (within +/-15min of start), or `.record` (no URL or past the window). `showSecondaryRecord` exposes a manual Record button whenever primary is not `.record`.
- **`urlOpener` closure for testability**: `EventPreviewViewModel.init` takes `urlOpener: @escaping (URL) -> Void` (defaults to no-op). `AppShellViewModel` injects `{ url in NSWorkspace.shared.open(url) }`. Tests inject a `URLTracker` to verify URLs were opened.
- **EventPreviewView rewritten**: full ScrollView with all event details (title, date range, calendar badge, platform, action buttons, meeting link, location, organizer, attendees list, notes).
- **`ReadyVM` test struct**: replaces a 3-member tuple return from `makeReadyVM` to satisfy SwiftLint's `large_tuple` rule.
- **`eventMinimalDetails` test fix**: events with `conferenceURL: nil` and 0 attendees fail the `isMeetingLike` filter (requires conference URL OR >=2 attendees). Fixed by providing 2 bare attendees so the event passes the filter.
- **23 new tests** in `EventPreviewViewModelTests.swift`: 8 primary-action time-window tests, 3 secondary-record tests, 3 action side-effect tests, 7 event-detail tests (enriched fields, displayName, not-found), 2 platform display-name tests.

### Phase 11 G6 implementation decisions

- **Window-reopen-wipe root cause and fix**: `BiscottiApp.body` held `@State private var core: AppCore?` -- when the window closed (don't-quit-on-close keeps app alive), SwiftUI tore down the `WindowGroup` body state, so reopening created a brand-new `AppCore` with empty summaries. **Fix:** moved `AppCore` ownership to `AppDelegate` (process-lifetime). `buildCore()` now runs once in `applicationDidFinishLaunching` via `MainActor.assumeIsolated`. `BiscottiApp.body` reads `appDelegate.shellViewModel` / `appDelegate.menuBarViewModel` -- these are created once from the single persistent `AppCore`. The underlying state (loaded meetings, route, run state) survives close/reopen.
- **MenuBarExtra switched from `.window` to `.menu`**: replaced `.menuBarExtraStyle(.window)` with `.menuBarExtraStyle(.menu)`. Rewrote `MenuBarContentView` to use menu-compatible content: all items are `Button`s and `Text` labels (section headers), with `Divider` separators. No custom views, no VStack layouts. Recording shows "Stop Recording (MM:SS)" or "Start Recording".
- **Menu items navigate to events/meetings**: added `openEvent(_:)` to `MenuBarViewModel` which calls `core.selectEvent(key)` + `windowOpener?()`. Upcoming items call `openEvent`, Recent items call `openApp(meetingID:)`. Both bring the window to front.
- **"See All" removed**: deleted `seeAll()` method and the "See all..." button. Left `// TODO(see-all): add a 'See All' menu entry once a full upcoming/recent list page exists` in both the VM and view.
- **`windowOpener` closure for window activation**: `MenuBarViewModel` gained a `windowOpener: (@MainActor () -> Void)?` property, injected by `AppDelegate.buildCore()`. This keeps the VM AppKit-free (no `NSApplication.shared.activate` calls) and testable -- tests inject a tracking closure to verify it's called. The app delegate's `showMainWindow()` handles `setActivationPolicy(.regular)`, `activate(ignoringOtherApps:)`, and `makeKeyAndOrderFront`.
- **Dock icon hides when no window**: `onReceive(NSWindow.willCloseNotification)` in the WindowGroup triggers `appDelegate.handleWindowClosed()`, which checks if any normal-level windows remain visible and calls `NSApp.setActivationPolicy(.accessory)` if none do. `showMainWindow()` (called from menu bar Open, dock click, notification actions) switches back to `.regular`.
- **`applicationShouldHandleReopen`**: returns `true` and calls `showMainWindow()` when `hasVisibleWindows` is false, matching Dock-click behavior.
- **Swift 6 strict concurrency**: `buildCore()`, `handleWindowClosed()`, and `showMainWindow()` are `@MainActor`. `applicationDidFinishLaunching` and `applicationShouldHandleReopen` (nonisolated delegate methods that run on the main thread) use `MainActor.assumeIsolated` to call `@MainActor` methods synchronously.
- **3 new navigation tests**: `openEventSetsRoute` (verifies route + windowOpener called), `openAppMeetingRoute` (meeting route + opener), `openAppHomeRoute` (home route + opener).
- **Known minor future-hardening**: `completeOnboarding()` (like the pre-existing `onLaunch` service-start) overwrites `detectorConsumerTask`/`notificationConsumerTask` without cancelling the old ones -- harmless today (called once) but worth cancelling-before-replace if either becomes re-callable.

### Phase 11 G7-hotfix: Startup hang fix + diagnostics

- **Root cause confirmed**: `AppDelegate` is `final class AppDelegate: NSObject, NSApplicationDelegate` -- NOT `@Observable`. The stored properties `shellViewModel`, `menuBarViewModel`, `launchError` were plain `var`s on a non-observable NSObject. `@NSApplicationDelegateAdaptor` does not provide Observation-framework tracking. When SwiftUI evaluated `BiscottiApp.body` BEFORE `applicationDidFinishLaunching` completed (a timing race, more likely with larger persisted stores), it read `shellViewModel == nil`, showed the `ProgressView` spinner, and NEVER re-evaluated because no observation mechanism existed. The "works on relaunch" behavior confirms the race: sometimes `didFinishLaunching` finishes first and the body sees the VM immediately.
- **Fix: `LaunchState` observable model**: extracted mutable startup state into `@MainActor @Observable final class LaunchState` with `shellViewModel`, `menuBarViewModel`, and `launchError`. `AppDelegate` owns a single `let launchState = LaunchState()` instance. `BiscottiApp.body` reads through `appDelegate.launchState.shellViewModel` etc. Because `LaunchState` is `@Observable`, the Observation framework tracks the read and triggers a re-render when `buildCore()` sets `shellViewModel` -- regardless of timing relative to first body evaluation. `LaunchState` conforms to `@unchecked Sendable` with a `nonisolated init()` so it can be stored as a default-initialized property on `AppDelegate` (whose stored-property initializers run in a nonisolated context under Xcode 26.2 / Swift 6).
- **`completeOnboarding` refactored to reuse `startBackgroundServices()`**: the duplicated calendar/detector/consumer/timer startup code in both `onLaunch` and `completeOnboarding` was extracted into `startBackgroundServices()`. This eliminated ~20 lines of duplication and resolved the `type_body_length` lint violation caused by the added logging.
- **`CalendarService.handleStoreChanged` + `checkStaleness` extracted to extension**: moved from the main class body to `extension CalendarService` in the same file to stay within the 250-line class body length lint limit after logging was added.
- **`os.Logger` startup diagnostics added**: subsystem `"net.scosman.biscotti"`, category `"startup"` in `AppDelegate` and `AppCore+Live.swift`; category `"AppCore"` in `AppCore.swift`; category `"Calendar"` in `CalendarService.swift`. Milestones logged at `.info` level cover every significant startup step. See the summary for the full list and the `log stream` command to capture them.

### Phase 11 R4 implementation decisions (playback duration)

- **Playback total length now comes from the data-model `recordingDuration`, not `AVAudioPlayer.duration`**: ADTS AAC has no container-header duration, so the player's reported length was a size/bitrate guess (often wildly wrong, e.g. 2h for a 30-min file). The wall-clock `recordingDuration` already stored on the `Meeting` model is used instead. Because `syncPlaybackState()` re-reads the player every 250 ms tick, the model duration is treated as **authoritative/stable** (wins on every tick when present and > 0), not merely an initial seed — otherwise it would snap back to the bad guess on play. The player-derived guess (with its decode-time self-correction) remains the **fallback** only for legacy recordings with no stored duration. No schema change. The two heavier alternatives you listed (decode the stream / re-container to mp4·caf on stop) stay **P3** — not needed since this fixes the player. **Verify on hardware:** the playback total now reads correctly for app-recorded meetings.

### Phase 11 R5 design decisions (Home screen redesign)

> The homepage was redesigned from a centered-in-empty-space layout to a native, top-anchored, section-based screen. These are tasteful execution calls made without blocking — **react to the look on the next hardware pass.**

- **Layout / whitespace**: dropped the vertical-centering `Spacer()`s; Home is now a top-anchored `ScrollView` with a single content column (`maxWidth: 600`) so all sections share one aligned width and the small-window case scrolls instead of crushing. Outer padding/spacing all from `Tokens`.
- **Header**: large bold **"Biscotti"** title (`.largeTitle.bold()`, dropped "Welcome to") + a readable secondary subtitle (`.title3`, was a tiny `.subheadline`). Left-aligned.
- **Start Recording**: a **new** prominent `StartRecordingButton` (`.borderedProminent`, `.controlSize(.large)`, red tint, `record.circle` icon, label "Start Recording") placed under the header — reads clearly as a button instead of floating mid-screen. Implemented as a *separate* DesignSystem component so the existing compact `RecordButton` (sidebar + event preview) is unchanged. Disabled while a recording is already running.
- **Upcoming**: now shows up to **5** (was 3, matches the sidebar cap), richer two-line rows (time + relative countdown + platform badge), inside a subtle rounded "card" container. Connect-calendar and no-upcoming empty states kept, restyled to match.
- **Recent Meetings (new section)**: last **4** from `core.summaries`, row = title + "date · duration" second line (identical formatting to the sidebar, via a shared `TimeFormatting.meetingSecondLine` helper), tap → opens the meeting detail. Empty state ("No recordings yet") when there are no recordings.
- **Cohesion**: both sections use one shared section-header style and one shared card container, all spacing/typography from `Tokens`, all dates/durations from `TimeFormatting` — so widths align and the design language is consistent. Open question for you: the subtle `Color.secondary.opacity(0.06)` card treatment vs. a flatter list look — easy to dial either way once you've seen it on device.

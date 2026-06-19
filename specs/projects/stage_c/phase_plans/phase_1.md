---
status: complete
---

# Phase 1: Foundation Deltas

## Overview

Phase 1 adds the foundational schema, services, DTOs, and seams that all subsequent phases depend on.
No UI. Everything is module/service/schema only. It unblocks Calendar, MeetingDetection, Notifications,
Vocabulary, and AppCore extensions.

## Steps

### 1. DataStoreSchemaV2 + migration

- Add `onboardingComplete: Bool = false` and `enabledCalendarIDsData: Data = Data()` (JSON-encoded
  `[String]?`, same Data-backed pattern as `customVocabularyData`) to `AppSettings`.
- Create `DataStoreSchemaV2` versioned schema listing all model types.
- Add a lightweight migration stage `v1toV2` in `DataStoreMigrationPlan`.
- Update `DataStore.init` to reference `DataStoreSchemaV2`.

### 2. Settings read/write (`AppSettingsData`, `settings()`, `updateSettings`)

- Define `AppSettingsData` Sendable DTO in `DataStore+ReadModels.swift`.
- Implement `DataStore.settings() -> AppSettingsData` (creates singleton on first read).
- Implement `DataStore.updateSettings(_ mutate:)` (read-modify-write pattern).

### 3. New read DTOs

- `CalendarContextData` — mapped from `CalendarSnapshot` + `Person` relationships.
- `PersonData` — from `Person` model.
- `TranscriptVersionData` — from `TranscriptRecord`.
- `SearchHit` + `SearchField` — weighted search result.

### 4. New DataStore query methods

- `calendarContext(meetingID:) -> CalendarContextData?`
- `transcriptVersions(meetingID:) -> [TranscriptVersionData]`
- `transcript(id:) -> TranscriptData?` (specific version)
- `audioFileRefs(meetingID:) -> (mic: URL?, system: URL?, present: Bool)`
- `searchHits(_:limit:) -> [SearchHit]` (transcript-text search with weighting)
- `setNotes(_:for:)` — notes write-back.

### 5. Effective-date sort

- Update `meetingSummaries(limit:)` to sort by effective date (`startDate ?? createdAt`).

### 6. MeetingCatalog target (L0)

- New target `MeetingCatalog` in Package.swift.
- `MeetingCatalog` protocol with: `displayName(forBundleID:)`, `isMeetingApp(bundleID:)`,
  `parentBundleID(forHelperBundleID:)`, `conferenceMatch(inURL:location:notes:)`.
- `BundledMeetingCatalog` implementation:
  - Bundle ID watchlist + display names (productionized from `AudioProcess.knownMeetingBundleIDs`).
  - Helper-to-parent mapping (WebKit.GPU -> Safari, avconferenced -> FaceTime, Slack helper -> Slack).
  - Conference-link regex patterns (productionized from EventKitLab `ConferenceDetector`, compiled
    once and cached).

### 7. Permissions deltas (calendar + notifications seams)

- Add `.calendar` and `.notifications` cases to `PermissionKind`.
- Add `CalendarAuthorizing` and `NotificationAuthorizing` seam protocols in `Permissions`.
- Extend `Permissions` with `calendar: PermissionState` and `notifications: PermissionState` properties.
- Add `noteCalendar(_:)` and `noteNotifications(_:)` methods (mirrors `noteSystemAudio`).
- Add `requestCalendar()` and `requestNotifications()` pass-through methods using seams.
- Extend `settingsURL(for:)` to handle `.calendar` and `.notifications`.

### 8. Route extension

- Extend `Route` enum with `.home`, `.event(String)`, `.search`, `.settings`, `.onboarding`.
- Replace `.empty` with `.home`.
- Update all existing references to `.empty`.

## Tests

### DataStore tests

- **`settingsCreatesSingleton`** — `settings()` returns defaults; second call returns same data.
- **`settingsRoundTrips`** — `updateSettings` modifies fields; `settings()` reads them back.
- **`settingsOnboardingCompleteDefaultsFalse`** — fresh store has `onboardingComplete == false`.
- **`settingsEnabledCalendarIDsDefaultsNil`** — fresh store has `enabledCalendarIDs == nil`.
- **`settingsEnabledCalendarIDsRoundTrips`** — set IDs, read back, verify set equality.
- **`calendarContextReturnsSnapshotData`** — meeting with snapshot + people returns populated DTO.
- **`calendarContextNilWhenNoSnapshot`** — meeting without snapshot returns nil.
- **`transcriptVersionsReturnsSorted`** — multiple transcripts return sorted by createdAt desc.
- **`transcriptByIDReturnsSpecificVersion`** — fetch a non-preferred transcript by ID.
- **`audioFileRefsReturnsPaths`** — meeting with mic+system refs returns correct URLs and present flag.
- **`audioFileRefsNilWhenMissing`** — meeting without refs returns nils.
- **`searchHitsMatchesTitle`** — title match scores higher.
- **`searchHitsMatchesTranscriptText`** — transcript text match included with lower weight.
- **`searchHitsRankedByScore`** — title matches rank above transcript-only matches.
- **`searchHitsMultiTermMatching`** — multi-term query matches meetings containing all terms.
- **`setNotesWritesBack`** — `setNotes` persists; detail read returns updated notes.
- **`effectiveDateSort`** — `meetingSummaries` sorts by `startDate ?? createdAt`.

### MeetingCatalog tests

- **`isMeetingAppReturnsTrueForKnownApps`** — Zoom, Teams, etc. return true.
- **`isMeetingAppReturnsFalseForUnknown`** — random bundle ID returns false.
- **`isMeetingAppRecognizesHelpers`** — WebKit.GPU, avconferenced recognized.
- **`displayNameReturnsHumanName`** — Zoom returns "Zoom".
- **`displayNameReturnsNilForUnknown`** — unknown returns nil.
- **`parentBundleIDResolvesHelpers`** — WebKit.GPU -> Safari, avconferenced -> FaceTime, Slack helper -> Slack.
- **`parentBundleIDReturnsNilForUserFacing`** — Zoom returns nil (already user-facing).
- **`conferenceMatchZoomURL`** — Zoom URL detected with platform "zoom".
- **`conferenceMatchMeetInNotes`** — Google Meet URL in notes detected.
- **`conferenceMatchPrefersURLOverNotes`** — URL field takes priority.
- **`conferenceMatchNilForNoMatch`** — no conference links returns nil.

### Permissions tests

- **`calendarStateInitNotDetermined`** — calendar starts as `.notDetermined`.
- **`notificationsStateInitNotDetermined`** — notifications starts as `.notDetermined`.
- **`noteCalendarUpdatesState`** — `noteCalendar(.authorized)` updates the property.
- **`noteNotificationsUpdatesState`** — `noteNotifications(.authorized)` updates the property.
- **`requestCalendarDelegates`** — `requestCalendar()` calls through seam, updates state.
- **`requestNotificationsDelegates`** — `requestNotifications()` calls through seam, updates state.
- **`settingsURLCalendar`** — `settingsURL(for: .calendar)` returns correct URL.
- **`settingsURLNotifications`** — `settingsURL(for: .notifications)` returns correct URL.

### Route tests (compile-time; verified by existing AppCore/UI tests adapting)

- Existing tests referencing `.empty` are updated to `.home`.

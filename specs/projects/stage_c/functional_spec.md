---
status: complete
---

# Functional Spec: Stage C — V1 Feature Layering

Stage C turns the Stage B MVP (manual Record → Transcribe in a single window) into **feature-complete V1**: calendar-aware, background/tray-first, auto-detecting meetings, with a home/library/search browsing experience, onboarding, settings, and custom vocabulary. All on-device. Distribution/signing (Project 9) is out of scope.

This spec is organized by the four feature areas (Calendar, Detection/Background/Notifications, Home/Library/Search, Onboarding/Settings/Vocabulary), preceded by cross-cutting decisions and followed by edge cases and out-of-scope. Confirmed core decisions are referenced as **C1–C8** (see `review_for_human.md`).

---

## 0. Cross-cutting decisions and conventions

- **Platform**: Apple silicon, macOS 15+. Non-sandboxed, hardened runtime (signing deferred to Project 9). Bundle ID locked `net.scosman.biscotti`.
- **UI**: uber-native SwiftUI, default Apple look, no custom rendering. Interaction design follows Apple HIG and the UX principles in this spec. Details in `ui_design.md`.
- **App presence (C7)**: regular app — Dock icon + main window + `MenuBarExtra`. Closing the last window keeps the app alive in the menu bar; quitting is explicit (menu-bar Quit, or ⌘Q). The recorder and detection keep running with no window open.
- **Privacy (C2)**: the app never records without an explicit user action. Detection produces notifications/prompts only.
- **Permissions (C3)**: requested up front in onboarding with explainer screens; re-requestable inline with denial-recovery deep links. Calendar and notifications are non-blocking (the app records manually without them).
- **RemoteConfig (C1)**: no module in V1. The meeting-app watchlist and conference-URL regexes are bundled/compiled-in behind a small `MeetingCatalog` seam so a future RemoteConfig can replace the backing store.
- **Errors**: no silent failures, especially in capture/transcription. Errors surface to the user-facing surface (UI banner or notification). Each module logs via `os.Logger` with its own subsystem/category.
- **Testing**: swift-testing. View models, orchestration, snapshot mapping, merge logic, search, and detection state machines are unit-tested headlessly. Hardware/permission-prompt paths are validated in the final human phase.

---

## 1. Calendar Integration (Project 5)

### 1.1 What it delivers
The app becomes calendar-aware: it reads the user's calendars (read-only), shows upcoming meeting-like events, lets the user choose which calendars count, enriches recordings with a durable snapshot of their calendar event, and detects conference links.

### 1.2 Calendar access
- Request **full access** via `EKEventStore.requestFullAccessToEvents()`. Info.plist key `NSCalendarsFullAccessUsageDescription`. No entitlement (non-sandboxed, TCC-only).
- Handle all statuses exhaustively: `.notDetermined`, `.fullAccess`/`.authorized`, `.writeOnly`, `.denied`, `.restricted`. `.writeOnly` (a Sonoma+ downgrade) is treated as "not usable" → denial-recovery guidance (deep link to `Privacy_Calendars`).
- Calendar is **non-blocking**: without it, manual recording and the rest of the app work; calendar-dependent UI shows an empty/connect state.
- Keep the `EKEventStore` instance alive (strong ref) so `.EKEventStoreChanged` fires.

### 1.3 Calendar selection (include/exclude)
- Enumerate `calendars(for: .event)`; present grouped by `source.title` (e.g. "iCloud", "Google"), each row showing `title` + color + a toggle.
- Default: **all calendars enabled.** User disables unwanted ones. Persisted as a `Set<String>` of `calendarIdentifier` (using the `@Observable`-safe stored-property pattern from EventKitLab, nil = all-enabled; never a UserDefaults-backed computed property).
- Birthday/subscribed calendars are shown but can be toggled off; they're enabled by default like any other (low risk — they rarely produce meeting-like events).
- Selection surfaces in **two places** that read the same store: the onboarding wizard and Settings.

### 1.4 Events and "meeting-like" filtering (C6)
- Fetch events from **enabled** calendars via a date-range predicate (EventKit filters server-side).
- **Meeting-like** = a timed (non-all-day) event that either (a) has a detected conference link, or (b) has ≥2 attendees. All-day events and solo timed events are excluded from upcoming lists, detection, and notifications. (They remain valid as manual association targets if the user picks them.)
- "Upcoming" surfaces (sidebar, menu bar, home preview) show meeting-like events in the near future (next ~24h for the lists; the menu-bar "next meeting" uses a 2-hour window per app_overview).

### 1.5 Conference-link detection
- Productionize `ConferenceDetector` (from EventKitLab) into the `Calendar` module. Detect a join URL + platform name by regex from `event.url` → `event.location` → `event.notes` (priority order). Platforms: Zoom, Google Meet, Teams, Webex, Slack Huddle (extensible). Compiled regexes cached.
- Patterns are hardcoded in V1 (C1). URL-only — no phone/dial-in detection.

### 1.6 Calendar snapshot (durable context)
- When a recording is associated with an event, snapshot all useful fields into a `CalendarSnapshot` sub-item of the meeting (the model already exists in DataStore): title, start/end, isAllDay, location, url, notes, status, availability, timeZone; organizer + attendees (name, email-if-derivable, role/status/type, isCurrentUser); calendar title + color; extracted conference URL + platform; composite link key; snapshot date; stale flag.
- The snapshot is the **source of truth** — the app must work if the event is later deleted or access revoked. Kept as one sub-item so it can be cleared in a single operation on re-association.
- **Composite link key** = eventIdentifier + calendarItemIdentifier + occurrenceStartDate (recurring events share identifiers; either id can change after sync). `calendarItemExternalIdentifier` stored as supplementary.
- Attendees populate `Person` records (dedup by email where available, else name) and the meeting's `participants`/`organizer`.

### 1.7 Association at record time (C4)
- When a recording starts (manually, or later via detection), the app auto-attaches the **best-match** calendar event: the meeting-like event currently in progress or imminent (within a small window, e.g. starts within ~10 min or is currently spanning now), preferring conference-link events; ties broken by nearest start time.
- If no match, the recording stays unlinked (a real, recordable meeting with an auto title).
- The match is a **suggestion the user can override**: Meeting Detail offers "Change event" / "Remove event association." Changing/clearing updates the snapshot, participants, and the per-meeting vocabulary; the user can then re-transcribe.

### 1.8 Snapshot refresh / staleness
- On `.EKEventStoreChanged` and on app launch, re-validate snapshots for recent/active meetings: re-fetch by composite key, refresh fields if the event still exists, mark `isStale = true` if it was deleted. (Coarse notification → re-fetch + diff; keep the query window small.)

### 1.9 Where calendar shows up in the UI (this project)
- **Settings**: calendar selection (first slice).
- **MenuBarUI / MeetingListUI**: an "Upcoming" list of meeting-like events.
- **MeetingDetailUI**: calendar context block (title, time, location, attendees, join link, calendar name/color) + the association correction entry point.

---

## 2. Meeting Detection, Background Operation & Notifications (Project 6)

### 2.1 What it delivers
The app runs in the background (tray-first), detects meetings starting, notifies with record/stop actions and an auto-stop countdown, and can launch at login. `AppCore` gets its first real coordination slice.

### 2.2 Background operation
- The app runs with no window open (C7). The recorder, detection, calendar watch, and menu bar stay live. Launch-at-login via `SMAppService`, **enabled by default**, toggleable in Settings.
- On launch the app recovers orphaned recordings (existing Stage B behavior) and resumes detection/calendar watching.

### 2.3 Meeting detection — two pathways
1. **Calendar-driven**: when a meeting-like (conference-link) event reaches its start time, fire a meeting-start notification. (Schedule from the upcoming set; reschedule on calendar change.)
2. **Ad-hoc audio**: `MeetingDetection` observes `AudioCapture`'s per-process activity (`AudioActivityMonitor`). When a watchlist app (or its known helper process) transitions to **both input and output running** (the validated "in a call" heuristic), emit "meeting started (app X)". When it transitions back, emit "meeting stopped (app X)". Helper-process → user-facing app name mapping comes from the `MeetingCatalog` seam (bundled watchlist, C1).
- Detection **never auto-records** (C2). It only drives notifications and (for an active recording) auto-stop.
- De-dup: if a calendar-driven notification and an ad-hoc detection refer to the same meeting window, don't double-notify (suppress the ad-hoc prompt while a calendar meeting is active or already prompted, and while already recording).

### 2.4 Notifications (three types)
Request notification authorization in onboarding (C3). Define `UNNotificationCategory` + actions for each:

1. **Meeting-start (calendar)**: title/body from the event; actions **"Open & Record"** (opens window + starts recording) and, if a join link was extracted, **"Join"** (opens the conference URL). Secondary "Record" without opening, if MacOS allows a non-foreground action.
2. **Ad-hoc detected**: "Meeting detected in {App}" with a **"Record"** action.
3. **Stop-recording countdown**: fired when the detected app's audio stops during an active **detection-driven** recording. Indicates it will auto-stop in **15s** and counts down; the default/primary interaction is **"Keep recording"** (cancels auto-stop). If untouched, recording stops automatically at 0. Manual recordings (no detected app) do **not** auto-stop.

Tapping a record/stop action routes through `AppCore` to the Recording/Transcription flow. Notifications **present and report intent only**; `AppCore` performs the action.

### 2.5 AppCore coordination (first real slice)
`AppCore` wires the flows that must work headlessly:
- detection event → (de-dup/policy) → notification → on user action → start recording → on stop → enqueue transcription.
- owns app-wide run state the UIs observe (idle / recording / detected-pending).
- drives auto-stop (countdown timer + cancel).
- provides the recording / upcoming / recent data the menu bar shows.
- remains operational with no window.

### 2.6 Menu bar (MenuBarUI)
- **Icon**: idle = icon only; if a meeting-like event is within 2h = icon + truncated next-meeting text ("1:1 Sam – in 1h52m" — truncate title, never the time); recording = icon + recording indicator.
- **Body**: recording section (not recording → Start; recording → elapsed counting up + Stop); Upcoming (next 2 meeting-like events); Past (last 2, links into the window); Open App; Quit.
- Data-driven by `AppCore`.

---

## 3. Home, Library & Search (Project 7)

### 3.1 What it delivers
The full in-window browsing experience: a home/welcome screen, rich past/upcoming lists, search across all meetings, and a rich Meeting Detail (playback, transcript versions, notes, association correction).

### 3.2 Home screen
- Default content when the window opens (and selectable from the sidebar). Contains: a brief welcome, a **prominent Start Recording** action, and a **preview of upcoming meeting-like meetings**. Empty states when there's no calendar access or no upcoming meetings.

### 3.3 Library (MeetingListUI rich slice)
- Sidebar: Home; recording indicator (when active); **Upcoming** (next meeting-like events); **Past** (scrollable, grouped — e.g. Today / Yesterday / This Week / earlier by date). Selecting a row opens Meeting Detail in the content area.
- Past meetings sort by **effective date** (`startDate ?? createdAt`) — resolves the Stage B TODO now that calendar dates exist.

### 3.4 Search
- A search field at the top of the window. As soon as the user types, search **takes over** the content area with live-filtering results; a back control (top-left of the content area) closes search and restores the previous view.
- **Scope**: title, people (participant/organizer names), and transcript text. Term-split, case-insensitive presence matching across fields; **weight title higher than transcript**; sort by score. Simple SwiftData matching (no FTS) — fine for <1000 docs. Selecting a result opens Meeting Detail.
- Empty query → no takeover (or a recent/empty prompt). No results → a clear empty state.

### 3.5 Meeting Detail (rich slice)
Extends the Stage B detail (transcript + metadata + re-transcribe) with:
- **Audio playback**: play the recording (mic+system) with a standard transport (play/pause, scrub, time). Handles missing/relocated audio gracefully (`AudioFileRef.isPresent`).
- **Transcript-version switching**: meetings can have multiple `TranscriptRecord` versions. Show the preferred (latest) by default with a picker to view older versions; re-transcribe creates a new version and promotes it.
- **Notes editing**: edit the meeting `notes` (autosaved).
- **Calendar context** (from Project 5) + **association correction**: change/clear the linked event; after a change, prompt/allow re-transcribe (vocab may differ).
- **Re-transcribe**: existing action; now also reachable after association/vocab changes.

### 3.6 DataStore additions
- **Transcript-text search**: extend `search` to include segment text with the weighting above (Stage B left a TODO for this).

---

## 4. Onboarding, Settings & Custom Vocabulary (Project 8)

### 4.1 What it delivers
A real first-run wizard, a settings surface, and custom vocabulary wired end-to-end into transcription.

### 4.2 Onboarding wizard (C3, C5, C8)
First-launch, in-window full takeover (not a separate scene). Steps, each with a pre-permission explainer ("why") before the system prompt, and **Skip/Continue** so no step hard-blocks:
1. **Welcome** — what the app does, privacy/on-device framing.
2. **Microphone** — explainer → request. Denial → inline guidance + deep link (`Privacy_Microphone`).
3. **System audio** — explainer → request (request happens by exercising capture; status inferred via silence-detection). Denial guidance + deep link (`Privacy_ScreenCapture`).
4. **Calendar** — explainer → `requestFullAccessToEvents()`. Then **calendar selection** (include/exclude). Denial → guidance + deep link; non-blocking ("Skip" allowed).
5. **Notifications** — explainer → `UNUserNotificationCenter` authorization. Non-blocking.
6. **Model download** — disk-space check, then download with progress. **Skippable (C8)**; if skipped, models download on first transcription.
7. **Done** — enter the app (Home).
- Onboarding completion is persisted (a flag in settings); re-runnable from Settings. (Demo step deferred — P2.)

### 4.3 Settings (in-window route, C5)
- **Calendar**: consolidated include/exclude selection (same store as onboarding).
- **Custom vocabulary**: edit the app-wide term list (add/remove/edit: company name, the user's name, technology names, codewords).
- **Launch at login**: toggle (default on).
- **Permissions overview** (nice-to-have): current status of mic/system-audio/calendar/notifications with re-request/deep-link buttons.
- (Audio file-usage view + deletion deferred — P3.)

### 4.4 Custom vocabulary (Vocabulary module + TranscriptionService)
- **App-wide list**: stored in `AppSettings.customVocabulary` (model exists; wire DataStore read/write — currently unwired). Edited in Settings.
- **Per-meeting merge**: for a transcription job, merge the app-wide list with per-meeting terms derived from the associated event — participant names, organizer name, company/domain names. (Title/description keyword extraction is a later nicety.)
- `TranscriptionService` assembles the **effective vocabulary** from the `Vocabulary` module and passes it to the engine (replacing the hardcoded `customVocabulary: []`). The engine already accepts `customVocabulary` and has `VocabularyFormatter`.
- Each `TranscriptRecord` already records `vocabularyUsed`; re-transcription uses the current effective list (so correcting association → richer vocab → better re-transcribe).
- (Per-recording manual vocab additions deferred — P3.)

---

## 5. Edge cases and error handling

- **Calendar denied / write-only / restricted**: calendar UI shows a connect/empty state with a fix deep link; everything non-calendar keeps working. No upcoming lists, no calendar-driven notifications; ad-hoc detection still works.
- **Notifications denied**: detection still updates menu-bar/app state; no banners. Inline note + deep link in Settings.
- **System audio silent (zero buffers)**: existing Stage B warning surfaces; recording continues (mic only). Onboarding/Settings explain the fix.
- **No models when transcription requested**: download on demand (status surfaced), or fail with a retriable error if download fails / disk full.
- **Detection false positives**: a non-meeting app using mic+output triggers a prompt the user can ignore; never auto-records. De-dup prevents double prompts; suppress while already recording.
- **Recording with no calendar match**: unlinked meeting with an auto title; user can link later.
- **Event deleted after snapshot**: snapshot persists as source of truth; marked stale; detail still renders.
- **Association corrected**: snapshot/participants/vocab updated atomically (snapshot cleared in one op then re-set); re-transcribe offered.
- **Recurring events**: matched by composite key incl. `occurrenceStartDate`; no series grouping in V1.
- **Audio file missing/relocated** (playback/re-transcribe): `isPresent=false` → disable playback/re-transcribe with an explanation.
- **App quit vs window close**: closing the window keeps detection/recording alive; only explicit Quit ends the app. A recording in progress on Quit should stop-and-save (not lose audio).
- **Search performance**: acceptable for <1000 meetings; if a query is slow, it still returns (no FTS in V1).
- **Multiple simultaneous detections**: handle one active recording at a time; additional detections queue as notifications, not concurrent recordings.

---

## 6. Out of scope (Stage C)

- Distribution / signing / notarization / auto-update (Project 9).
- LLM intelligence — summaries, action items, name inference, vocab extraction from invites (Project 10).
- Auto speaker identification — voiceprints, "me" detection (Project 11).
- iCloud sync (Project 12).
- Global start/stop keyboard shortcut; audio file-usage/deletion view; per-recording manual vocab; FTS search (Project 13 / P3).
- Onboarding demo step; recurring-series grouping; Contacts enrichment; phone dial-in detection (P2).
- A real RemoteConfig server / OTA (C1 — bundled/hardcoded for V1).

---

## 7. Success criteria (end of Stage C)

Feature-complete V1, fully autonomous build + final human tuning pass:
1. First-run onboarding requests all permissions with recovery guidance and (optionally) downloads models.
2. The app lives in the menu bar, runs in the background, and shows upcoming meeting-like events.
3. Calendar-driven and ad-hoc meetings fire notifications with record/stop actions; nothing records without user action; auto-stop works for detected meetings.
4. Recordings auto-associate to the right calendar event, carry durable calendar context, and can be corrected + re-transcribed.
5. Home/library/search let the user browse and find any meeting; Meeting Detail supports playback, transcript versions, notes, and association correction.
6. Custom vocabulary (app-wide + per-meeting) flows into transcription and improves results.
7. All green on `lint` + `test` + `build`; view models/orchestration/merge/search/detection covered by unit tests.

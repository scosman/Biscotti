---
status: complete
---

# UI Design: Stage C — V1 Feature Layering

Extends the Stage B window-only app into the full V1 surface: home, library, search, rich meeting
detail, settings, onboarding, and a menu bar. **Exceptionally Apple-native** — `NavigationSplitView`,
standard controls, system highlight color, HIG spacing, default rendering. "Tight design, not light on
design." No custom controls/gradients/corners. Interaction design follows HIG + the UX principles
below. Reuses and grows the Stage B shell, `Route` enum, view-model pattern, and `DesignSystem` tokens.

## UX principles applied here
- **Progressive disclosure**: Home is calm and minimal; depth (versions, association correction,
  permissions) lives in detail/settings, not up front.
- **Discoverability**: standard sidebar + search field + menu bar; nothing hidden behind non-obvious
  gestures. A back affordance always returns from search.
- **Platform conventions**: macOS sidebar navigation, `MenuBarExtra`, system notification actions,
  standard form controls in Settings — no reinvented patterns.
- **Low cognitive load**: one primary action per screen (Record on Home/menu bar; Stop while
  recording); secondary actions are quiet.

---

## 1. Window shell (`AppShellUI`, grown)

```
┌─────────────────────────────────────────────────────────────────────┐
│ Biscotti           [  ⌕ Search…                    ]          ● ◌ ◌ │  title bar + search field
├──────────────────┬──────────────────────────────────────────────────┤
│  ⌂ Home          │                                                  │
│  ◉ Recording…    │                                                  │
│  ───────────     │                Main content area                 │
│  UPCOMING        │     (Home · Recording · MeetingDetail · Search   │
│   ▸ Standup 9:00 │      takeover · Settings)                        │
│   ▸ 1:1 Sam 2:30 │                                                  │
│  PAST            │                                                  │
│   Today          │                                                  │
│    Sync · 10:30  │                                                  │
│   Yesterday      │                                                  │
│    Review · 4:00 │                                                  │
│   …              │                                                  │
│  ───────────     │                                                  │
│  ⚙ Settings      │                                                  │
└──────────────────┴──────────────────────────────────────────────────┘
```

- **Search field** lives at the top of the window (toolbar). Typing takes over the content area
  (§4). Empty → no takeover.
- **Sidebar (top → bottom):**
  - **Home** — selects the Home screen.
  - **Recording indicator** — only while recording (animated dot + elapsed); selects the Recording
    screen.
  - **UPCOMING** — next meeting-like events (conference-link or multi-attendee), each row = title +
    time-until/time. Selecting opens that meeting's detail (creates/links nothing — read-only
    preview of the event context until recorded). Hidden/empty-state when no calendar access.
  - **PAST** — scrollable past meetings, **grouped** (Today / Yesterday / This Week / Earlier),
    newest first, sorted by effective date (`startDate ?? createdAt`). Row = title + relative date.
  - **Settings** — pinned at the bottom; selects the in-window Settings route.
- **Detail pane (`Route`, extended)**: exactly one of `.home | .recording | .meeting(id) |
  .search | .settings | .onboarding`. (Stage B had `.empty | .recording | .meeting`; `.empty`
  becomes `.home`.)
- Closing the window keeps the app alive in the menu bar (§7).

---

## 2. Home screen (`HomeUI`)

```
┌──────────────────────────────────────────────────────┐
│                                                      │
│                  Welcome to Biscotti                 │   calm, centered
│         Private, on-device meeting transcripts       │
│                                                      │
│                 [  ●  Start Recording  ]             │   prominent primary
│                                                      │
│   Upcoming                                           │
│   ┌────────────────────────────────────────────┐    │
│   │ ▸ Standup            in 12m   · Zoom        │    │   meeting-like only
│   │ ▸ 1:1 with Sam       2:30 PM  · Meet        │    │
│   └────────────────────────────────────────────┘    │
│                                                      │
└──────────────────────────────────────────────────────┘
```

- Welcome line + one **Start Recording** primary action + an **Upcoming preview** (a few
  meeting-like events with platform badge + time).
- **Empty states**: no calendar access → a quiet "Connect your calendar to see upcoming meetings"
  with a button that requests/deep-links. No upcoming → "No meetings coming up."

---

## 3. Meeting Detail (`MeetingDetailUI`, rich slice)

Grows the Stage B detail (transcript + metadata + re-transcribe + status/error states) with calendar
context, playback, version switching, notes, and association correction.

```
┌──────────────────────────────────────────────────────────────┐
│ 1:1 with Sam                      [ Version ▾ ] [ Re-transcribe ]│  header
│ Jun 10, 2026 · 2:30 PM · 24m 03s                              │
│ ┌── Calendar ─────────────────────────────────────────────┐  │
│ │ Zoom · Work (●blue)   [ Join ]            [ Change… ]    │  │  calendar context block
│ │ Sam Lee (organizer) · You · Alex Kim                    │  │  + association correction
│ └─────────────────────────────────────────────────────────┘  │
│ ▶︎ ──────────●────────────────  03:11 / 24:03                 │  audio transport
│ ── Notes ──────────────────────────────────────────────────  │
│ [ editable notes field … ]                                   │  autosaved
│ ── Transcript ─────────────────────────────────────────────  │
│ Speaker 0   Hey, thanks for joining today.                   │
│ Speaker 1   No problem, happy to be here.                    │
│ …                                                            │
└──────────────────────────────────────────────────────────────┘
```

- **Header**: title; **Version ▾** picker (preferred/latest default; lists older `TranscriptRecord`
  versions with date/method); **Re-transcribe** (creates + promotes a new version).
- **Calendar block** (when associated): platform + join link, calendar name + color, organizer +
  attendees; **Change…** opens an event picker (pick another meeting-like event or **Remove
  association**). After a change, offer **Re-transcribe** (vocab may differ). When unassociated, a
  quiet "Link a calendar event…" affordance.
- **Audio transport**: standard play/pause + scrubber + time. Disabled with a note if
  `AudioFileRef.isPresent == false`.
- **Notes**: inline editable, autosaved to the meeting.
- **Transcript**: unchanged segment list (speaker chip + selectable text). Reflects the selected
  version. Reuses the Stage B processing/failed states.

---

## 4. Search (`SearchUI`, takeover)

```
┌──────────────────────────────────────────────────────┐
│ [ ‹ Back ]   ⌕ "sam"                                 │  back restores prior view
│ ──────────────────────────────────────────────────   │
│  1:1 with Sam            Jun 10 · matches: title      │   ranked results
│  Planning · Sam, Alex    Jun 3  · matches: people     │
│  Retro                   May 28 · matches: transcript │
│  …                                                    │
└──────────────────────────────────────────────────────┘
```

- Triggered by typing in the toolbar search field; **live-filtering** as the user types.
- Results across **title / people / transcript**, ranked (title weighted higher than transcript),
  each showing the meeting + a small "why it matched" hint. Selecting opens Meeting Detail.
- **Back** (top-left) closes the takeover and restores the previous content (Home / a meeting).
- **No results** → clear empty state ("No meetings match 'sam'.").

---

## 5. Settings (`SettingsUI`, in-window route)

A standard macOS-style settings layout rendered **inside the window** (per decision C5 — no separate
Settings scene). Sectioned `Form`/`List`:

```
┌──────────────────────────────────────────────────────┐
│ Settings                                             │
│ ┌─ General ───────────────────────────────────────┐ │
│ │ ☑ Launch at login                                │ │
│ └──────────────────────────────────────────────────┘ │
│ ┌─ Calendars ─────────────────────────────────────┐ │
│ │ iCloud                                           │ │
│ │   ☑ Work     ●blue                               │ │   grouped by source
│ │   ☐ Family   ●green                              │ │
│ │ Google                                           │ │
│ │   ☑ team@…   ●red                                │ │
│ └──────────────────────────────────────────────────┘ │
│ ┌─ Custom Vocabulary ─────────────────────────────┐ │
│ │ [ Biscotti        ] [ – ]                        │ │   add/edit/remove terms
│ │ [ Parakeet        ] [ – ]                        │ │
│ │ [ + Add term…     ]                              │ │
│ └──────────────────────────────────────────────────┘ │
│ ┌─ Permissions ───────────────────────────────────┐ │
│ │ Microphone   ✓ Granted                           │ │   status + fix deep links
│ │ System Audio ✓ Granted                           │ │
│ │ Calendar     ⚠ Denied   [ Open Settings ]        │ │
│ │ Notifications ✓ Granted                          │ │
│ └──────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

- **General**: Launch at login (default on).
- **Calendars**: include/exclude toggles grouped by source (shared with onboarding).
- **Custom Vocabulary**: editable list (add/remove/edit terms).
- **Permissions**: per-permission status with re-request / "Open Settings" deep links.
- (Audio file-usage/deletion deferred — P3.)

---

## 6. Onboarding wizard (`OnboardingUI`, first-run, in-window takeover)

Full-window takeover on first launch; standard "page + Continue/Skip" wizard. Each permission step
has a plain-language **why** before the system prompt, and never hard-blocks.

```
┌──────────────────────────────────────────────────────┐
│  ●●●○○○○                                              │  step indicator
│                                                      │
│                   Microphone access                  │
│   Biscotti records your voice locally to transcribe  │
│   your meetings. Nothing leaves your Mac.            │
│                                                      │
│            [  Allow Microphone  ]                    │  → system prompt
│   ⚠ Denied? Open System Settings ›                   │  inline recovery (deep link)
│                                                      │
│                     [ Skip ]   [ Continue ]          │
└──────────────────────────────────────────────────────┘
```

Steps: **Welcome → Microphone → System Audio → Calendar (+ calendar selection) → Notifications →
Model Download (skippable, with disk check + progress) → Done**. On finish, persist the
onboarding-complete flag and enter Home. Re-runnable from Settings. (Demo step deferred — P2.)

---

## 7. Menu bar (`MenuBarUI`, `MenuBarExtra`)

```
 idle:        [ ◍ ]
 upcoming:    [ ◍ Standup – in 12m ]          (truncate title, never the time; ≤2h window)
 recording:   [ ◉ ]                           (recording indicator)

 ▼ popover / menu
 ┌───────────────────────────────┐
 │  ● Start Recording            │   (or)  ◉ 04:12   [ ■ Stop ]
 │  ───────────────────────────  │
 │  Upcoming                     │
 │   Standup            in 12m   │
 │   1:1 with Sam       2:30 PM  │
 │  ───────────────────────────  │
 │  Recent                       │
 │   Sync               10:30    │   → opens window to that meeting
 │   Review             Yest.    │
 │   See all…                    │
 │  ───────────────────────────  │
 │  Open Biscotti                │
 │  Quit                         │
 └───────────────────────────────┘
```

- **Icon states**: idle (icon only) · next-meeting text when a meeting-like event is within 2h
  (truncate title, keep time) · recording indicator while recording.
- **Body**: recording section (Start, or elapsed + Stop) · Upcoming (next 2) · Recent (last 2 +
  "See all…") · Open Biscotti · Quit.
- Data-driven by `AppCore`; works with no window open.

---

## 8. Notifications (system, via `Notifications`)

Standard macOS notifications with action buttons (no custom UI):
- **Meeting starting** ("Standup is starting") → **Open & Record** · **Join** (if link).
- **Meeting detected** ("Meeting detected in Zoom") → **Record**.
- **Stop recording?** ("Audio stopped — stopping in 15s") counting down → **Keep recording**
  (default); auto-stops at 0 if untouched (detection-driven recordings only).

---

## 9. Navigation summary

- One window + menu bar. `NavigationSplitView` (sidebar + routed detail), `Route` extended to
  `.home | .recording | .meeting(id) | .search | .settings | .onboarding`.
- First launch → `.onboarding` takeover → Home.
- Sidebar: Home / Recording / Upcoming / Past / Settings select the corresponding route.
- Toolbar search → `.search` takeover; Back restores prior route.
- Menu bar mirrors Start/Stop, Upcoming, Recent; can open the window to any meeting.
- Notifications route through `AppCore` to start/stop recording or open/join.

---

## 10. DesignSystem additions (minimal, native)

Grow Stage B tokens/components only as needed, all standard rendering:
- **CalendarContextBlock** (platform/join/calendar/attendees), **AudioTransport** (play/pause +
  scrubber + time), **VersionPicker** (menu of transcript versions), **VocabularyEditor** (token
  list), **PermissionRow** (status + fix), **WizardStep** scaffold (title/why/action/skip), **menu
  bar rows**. Reuse `Banner`, `StatusRow`, `RecordButton`, `TranscriptSegmentRow`. Previews for each.
  Nothing speculative.

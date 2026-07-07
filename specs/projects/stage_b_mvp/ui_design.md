---
status: complete
---

# UI Design: Stage B — MVP

Window-only, **exceptionally Apple-native** (`NavigationSplitView`, standard controls, system
highlight color, HIG spacing). "Tight design, not light on design." No menu bar, no onboarding, no
home/search/settings. Three screens behind one window shell.

## Window shell (`AppShellUI`)

A standard macOS `NavigationSplitView`:

```
┌───────────────────────────────────────────────────────────┐
│ Biscotti                                            ● ◌ ◌  │  (standard title bar)
├──────────────────┬────────────────────────────────────────┤
│  ●  Record       │                                         │
│  ───────────     │            Main content area            │
│  ◉ Recording…    │   (Recording screen OR Meeting Detail)  │
│                  │                                         │
│  PAST            │                                         │
│   1:1 Sam · 2:30 │                                         │
│   Standup · 9:00 │                                         │
│   Sync · Mon     │                                         │
│   …              │                                         │
└──────────────────┴────────────────────────────────────────┘
   sidebar (list)              detail (routed)
```

- **Sidebar (top → bottom):**
  - **Record** — a prominent primary action (a `● Record` button styled via DesignSystem). Disabled
    while a recording is in progress. Tapping it triggers the just-in-time permission flow then
    starts recording (routes detail to the Recording screen).
  - **Recording indicator** — shown only while recording: an animated red dot + "Recording…" +
    elapsed time; selecting it routes to the Recording screen.
  - **PAST** section — a scrollable list of past meetings (`MeetingListUI`), newest first; each row =
    title + relative date. Selecting a row routes the detail pane to that meeting.
- **Detail pane (routing):** shows exactly one of:
  - **RecordingUI** — while recording (or when the recording indicator is selected).
  - **MeetingDetailUI** — when a past meeting is selected, or immediately after Stop (auto-routes to
    the just-recorded meeting).
  - An empty/placeholder state when nothing is selected (e.g. "Select a meeting, or tap Record").

Routing is a small enum (`.recording | .meeting(id) | .empty`) owned by the shell's view model.

## Recording screen (`RecordingUI`)

```
┌────────────────────────────────────────┐
│                                        │
│            ◉  Recording                 │
│                                        │
│              02:14                      │   ← elapsed time, large monospaced
│         Recording — Jun 9, 2:30 PM      │   ← meeting title
│                                        │
│            [  ■  Stop  ]                │   ← prominent stop
│                                        │
│  ⚠ System audio may be denied — Fix…   │   ← inline banner only if applicable
└────────────────────────────────────────┘
```

- Big, calm, single-purpose. Elapsed time counts up (from `Recording`'s observable state). A blinking
  record dot (opacity pulse — the "VCR LED" option from `specs/app_overview.md`). **No live VU meters** in
  the MVP (engine levels are unwired). One prominent **Stop**. An inline warning banner appears only
  if a permission/denial/write issue is detected, with a "Fix…" deep link.

## Meeting Detail screen (`MeetingDetailUI`)

Drives off the meeting's preferred transcript + the transcription status. Three states:

**(a) Transcribing / downloading models (inline first-run setup):**
```
┌──────────────────────────────────────────────┐
│  Recording — Jun 9, 2:30 PM                    │  title + metadata
│  Jun 9, 2026 · 2:30 PM · 4m 12s                │
│  ──────────────────────────────────────────   │
│                                                │
│        ⟳  Downloading model… 42%               │  ← status (download → compile
│           (or) Transcribing…                   │     → loading → transcribing)
│                                                │
└──────────────────────────────────────────────┘
```

**(b) Transcript ready:**
```
┌──────────────────────────────────────────────┐
│  Recording — Jun 9, 2:30 PM      [ Re-transcribe ] │
│  Jun 9, 2026 · 2:30 PM · 4m 12s                │
│  ──────────────────────────────────────────   │
│  Speaker 0   Hey, thanks for joining today.    │  ← diarized segments,
│  Speaker 1   No problem, happy to be here.     │     speaker-labeled, time order
│  Speaker 0   So the first thing on the agenda… │
│  …                                             │
└──────────────────────────────────────────────┘
```

**(c) Failed:**
```
│  ⚠ Transcription failed — Worker stopped.      │
│     [ Retry ]                                  │   ← typed error + retry
```

- **Header:** title, date, duration; a **Re-transcribe** action (always available once audio exists).
- **Body:** the transcript as a list of speaker-labeled segments (DesignSystem segment row: speaker
  chip + text). Speaker labels are the engine's `"Speaker N"` (no name mapping in the MVP).
- **Status & errors:** the download/transcribe progress and any error banner render here (this is
  where first-run model setup surfaces). Retriable errors show **Retry**.
- MVP shows the **preferred** version only; a version picker is deferred (`// TODO`, Project 7). No
  audio playback (`// TODO`, Project 7).

## DesignSystem (minimal)

Just enough shared styling for the above: color/typography/spacing tokens (system colors, dynamic
type, 8-pt grid); a **RecordButton**, a **StatusRow** (spinner/progress + label), a
**TranscriptSegmentRow** (speaker chip + text), and a **Banner** (warning/error + action). Previews
for each. Nothing speculative.

## Navigation summary

- One window. `NavigationSplitView` (sidebar + detail).
- Record (sidebar) → permission JIT → start → detail = Recording screen.
- Stop → detail = Meeting Detail (auto-selected) → inline model download (first time) → transcript.
- Select past meeting (sidebar) → detail = its Meeting Detail.
- Re-transcribe (detail) → status → updated transcript.

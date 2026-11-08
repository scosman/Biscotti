---
status: draft
---

# Functional Spec: Import Audio

Lets the user bring existing audio or video recordings into Biscotti. Each imported file is converted into Biscotti's standard recording format, becomes its own meeting, and then goes through the same post-recording pipeline as a live recording (transcribe → AI enhancements: speaker names, summary, title).

Design reference: [`design/design_handoff.md`](design/design_handoff.md) and [`design/import_audio_mockups.html`](design/import_audio_mockups.html). Visual details (exact type, color and spacing mapped onto our design system) live in `ui_design.md`. Where this spec and the handoff disagree, this spec wins. Where the handoff and the repo's design system (`DesignSystem` module tokens and fonts) disagree on visual details, the repo wins.

---

## 1. Entry points

There are two ways to start an import. Both feed the same import session (§4) and route to the Import screen (§5).

### 1.1 File > Import Audio File…

- A new **File** menu item, **Import Audio File…**, in the File menu's import/export group.
- Keyboard shortcut **⌘⇧I**. *Priority P3:* if the shortcut proves hard to wire during implementation, ship the menu item without it and leave a `// TODO`.
- Opens a standard macOS open panel:
  - Multiple selection allowed.
  - Filtered to supported types (§3): audio and audiovisual (movie) content.
  - Files only. Directories can't be chosen.
- **Open** adds the chosen files, in the order the panel returns them, to the import session and routes to the Import screen. **Cancel** does nothing.
- If the main window is hidden (menu-bar-only mode), invoking the item shows the main window first.
- **Disabled** while onboarding is showing.

### 1.2 Drag and drop onto the window

- The **whole main window** is a drop target: sidebar, toolbar, main area, on every screen (Home, Meetings, Recording, Event preview, Settings, Import).
- Only drags carrying **files** activate it. Text, web links and images dragged from a browser don't show the overlay and aren't accepted.
- Supported file sources:
  - **File URLs** (Finder, Desktop, most apps).
  - **File promises** (apps like Voice Memos and Photos, which hand over a file only on drop). A promised file is classified by its declared type while hovering and received into a temporary location on drop.
- While a qualifying drag hovers over the window, the **drop overlay** (§2) covers the entire window content.
- The overlay goes away when the drag leaves the window, when files are dropped, or when the drag is cancelled (Esc).
- **On drop:**
  - If at least one dropped item is supported, the supported items, in drag order, are added to the import session and the app routes to the Import screen. Unsupported items are skipped without further notice (the overlay already warned about them).
  - If no dropped item is supported, the drop is refused (the system shows no "+" badge while hovering) and nothing happens.
- **Disabled** while onboarding is showing: no overlay, drop refused.

---

## 2. Drop overlay states

The drop target classifies the hovering items (§3) and shows one of these states. Copy is final.

| State | Condition | Title | Below title | Look |
|---|---|---|---|---|
| Supported, single | exactly 1 item, supported | **Drop to import** | "Biscotti will transcribe and summarize it on your Mac." + format line | sage |
| Supported, multiple | N > 1 items, all supported | **Drop to import N files** | "Each file becomes its own meeting." | sage |
| Mixed | some supported (S ≥ 1), some unsupported (U ≥ 1) | **Drop to import S files** (S = supported count; "Drop to import" when S = 1) | "Each file becomes its own meeting." + skip notice | sage |
| Unsupported | every item unsupported (1 or more) | **Can't import this file** | "Biscotti imports audio and video recordings." + format line | neutral, drop refused |

- **Skip notice** (mixed state): "**U** files are unsupported file types and will be skipped." Singular when U = 1: "1 file is an unsupported file type and will be skipped."
- **Mixed with S = 1:** the title reads "Drop to import" (not "Drop to import 1 files"), and the sub-copy is still "Each file becomes its own meeting." plus the skip notice.
- **Format line** (display only, not the real check): `WAV · MP3 · M4A · AAC · AIFF · CAF · FLAC · MP4 · MOV`.
- **Motion:** fade in and out over ~120–150 ms, ease-out. No scale or bounce.
- The overlay sits above everything, including the sidebar and any open sheet's backdrop, and doesn't take keyboard focus.

---

## 3. Supported files

- **Supported** = a file whose type conforms to **audio** (`public.audio`) or **audiovisual content** (`public.audiovisual-content`, which covers movies). That includes WAV, MP3, M4A, AAC, AIFF, CAF, FLAC, MP4, MOV and M4V, among others.
- **Unsupported:**
  - Any other file type.
  - **Directories** (folders and packages). Folders aren't expanded.
  - Items whose type can't be determined.
- During hover, classification uses only the type from the file extension or the declared type. It's cheap and never opens the file.
- At conversion time a supported-by-type file may still fail (no audio track, damaged, DRM-protected). That becomes a failed row (§5.4), not a rejection at drop time.
- Duplicate files (the same file dropped twice, in one drop or across drops) are allowed. Each becomes its own meeting.

---

## 4. Import session

- The app keeps **one import session** in memory for the life of the process. It is an ordered list of import items.
- Each import action (one drop, or one open-panel confirmation) **appends** its files to the end of the list. Drop 5, then 8: the Import screen lists 13.
- Items are **converted one at a time, in list order** (first in, first out). An item appended while others are converting waits its turn.
- The session isn't persisted. Quitting the app (a real terminate) discards it. Items still waiting are lost, and meetings already created stay.
- **There's no cancel and no remove** for items or the session.
- Each item tracks:
  - **Source file:** its location and display name, the file name with its extension.
  - **Meeting date** (§6.2), filled in asynchronously.
  - **Status:** `waiting` → `converting` → `done(meetingID)` or `failed(reason)`. A promised file starts as `receiving`, named after the promised file name (or "Incoming file" if the source app gives none) until it's delivered.

### 4.1 Runs (for screen copy)

A **run** is a stretch of continuous conversion work:
- It starts when files are added while no item is waiting or converting.
- Files added during a run extend it.
- It ends when its last item finishes (done or failed).

Runs only matter for the Import screen's title and status copy (§5.2).

---

## 5. Import screen

### 5.1 Navigation

- A new main-area screen, **Import** (a new route). The sidebar stays. Search and the Record button stay in the toolbar. The app has no per-screen toolbar titles (the window title is blank), so the mock's "Import" toolbar title is dropped. The screen's serif header is its title.
- Every import action routes here, even if the user was elsewhere, including the Recording screen. The recording keeps going, and the user can return through the sidebar's recording row.
- **Sidebar "Imported" row:**
  - **Appears** the first time anything is added to the import session.
  - **Stays** until the app is restarted.
  - **Sits** in the sidebar footer, directly above Settings.
  - **Selecting it** routes to the Import screen. It shows as selected while the Import screen is showing.
  - **While conversion is in progress**, the row shows a small spinner.
- Leaving the Import screen doesn't affect conversion. It continues in the background.

### 5.2 Header copy

Title (serif) and a status line below it. The words "file"/"files" agree in number everywhere.

| Situation | Title | Status line |
|---|---|---|
| Run in progress, run has 1 item | Importing 1 file | converting audio |
| Run in progress, run has N > 1 items | Importing N files | i of N · converting audio (i = 1-based position in the run of the item now converting) |
| No run in progress, every item in the session succeeded | Imported T files (T = session total; "Imported 1 file" when T = 1) | Transcripts and summaries are being written in each meeting. |
| No run in progress, some items failed | Imported X of T files (X = session done count) | Transcripts and summaries are being written in each meeting. |
| No run in progress, every item failed | Imported 0 of T files | Couldn't convert these files. ("Couldn't convert this file." when T = 1) |

The in-progress counts cover the current run. The completed counts cover the whole session list, since that's what the list shows.

### 5.3 File list

A single card listing **every item in the session**, in session order (oldest at top, new items at the bottom). It's used for single and multi-file imports alike. A single import is a list with one row. The page scrolls when the list is long.

Row anatomy:
1. Icon tile.
2. **Name**: the file name with its extension, one line, truncated in the middle with an ellipsis if too long.
3. **Second line**: the item's **meeting date** (§6.2), or an error message for failed rows.
4. Trailing status.

The second line shows the date rather than the duration, so the user can find the meeting later. It's formatted as the meetings list's short date plus the time, e.g. "Oct 30, 2026 · 2:14 PM", in the monospace meta font. Until the date resolves, the second line is blank (no layout jump: reserve the line height).

### 5.4 Row states

| State | Icon tile | Second line | Trailing |
|---|---|---|---|
| Waiting | neutral | meeting date | "Waiting" (mono, tertiary ink) |
| Receiving (file promise not yet delivered by the source app) | neutral | meeting date once known | "Receiving…" (mono, tertiary ink) |
| Converting | sage | meeting date | small spinner + "Converting…" |
| Done | sage | meeting date | **Go to Meeting** button |
| Failed | red "!" | error message (red) | **Show in Finder** button |

- **Go to Meeting** opens that meeting in the Meetings screen (the same as selecting it from outside the list: clears search, selects that one meeting).
- **Show in Finder** reveals the original source file in Finder. If the source file no longer exists, it opens Finder at the nearest existing parent folder.
- If a Done row's meeting has since been deleted, Go to Meeting does nothing and the row's trailing area shows "Deleted" in tertiary ink.

**Failure messages** (second line of a failed row):

| Cause | Message |
|---|---|
| File has no audio track, or zero-length audio | This file has no audio. |
| Source file missing when its turn comes (moved or deleted) | This file was moved or deleted. |
| Couldn't write the converted audio or create the meeting (e.g. disk full) | Couldn't save the converted audio. |
| Anything else: unreadable, damaged, DRM-protected, unsupported codec | Couldn't convert this file. It may be damaged. |

### 5.5 Auto-navigation (single-file imports)

When an item finishes **successfully**, the app navigates straight to its meeting, with no Go to Meeting step, only if **all** of these hold:
1. The import action that added it contained exactly **one** file.
2. Nothing else in the session is waiting or converting at that moment.
3. The Import screen is currently showing.

Otherwise it doesn't auto-navigate, and the row gets Go to Meeting. If the single file fails, the user stays on the Import screen with the failed row.

---

## 6. Conversion and meeting creation

### 6.1 Conversion

- Uses the standard macOS audio stack (AVFoundation) to read the source and **re-encode** it to Biscotti's standard recording format: ADTS AAC-LC, mono, 24 kHz, 64 kbps (the same encoder preset live recordings use).
- **Always re-encodes**, even when the source already looks like the target format. One code path, guaranteed format.
- **Multi-channel** sources are mixed down to mono. Any sample rate is resampled to 24 kHz.
- **Video files:** only the audio is extracted. Video tracks are ignored. With several audio tracks, the first enabled audio track is used.
- The **original file is never modified or moved**, and no copy of the original is kept. Only the converted audio is stored, in the app's normal recordings location, laid out like a recording.
- Files received through file promises are deleted from their temporary location once their conversion finishes (either way).
- Conversion runs off the main thread. The UI stays responsive.

### 6.2 Meeting date

Each item's meeting date is the first of these that's available:
1. The **creation date embedded in the media** (e.g. the recorded-at date that Voice Memos and iPhone videos write into the file's metadata).
2. The file's **modification date**.
3. The **time of import** (when the item was added to the session).

A date later than the time of import is clamped to the time of import. Otherwise a bad clock would make the meeting show as upcoming.

The meeting's start date is the meeting date, its end date is the start date plus the converted audio's duration, and its recording duration is the converted audio's duration. The meeting sorts and displays by this date, like any other meeting.

### 6.3 Meeting creation

- A meeting is created **only after** its conversion succeeds. A failed conversion leaves no meeting behind.
- An app crash mid-conversion leaves no meeting and no half-written file in the recordings location.
- **Audio:** the meeting has a **single audio track** (stored in the "system" slot, meaning "everyone in the meeting"). It has no microphone track. Playback, Reveal in Finder, deletion, MCP and export all work with one track (§7.1).
- **Title:** **"Imported from ‹file name›"**, e.g. "Imported from Polarity Labs call.m4a".
  - This is a **placeholder title**. It is *not* marked as user-edited, and AI titling treats it exactly like the default "Untitled Meeting" title: when the AI title runs, it replaces it.
  - If AI titling doesn't run (AI off, no model installed), the placeholder stays, which keeps imports distinguishable.
  - If the user renames the meeting, it becomes user-edited, like any rename.
  - If the user later associates a calendar event (event picker), the event title replaces the placeholder (today's association rule for titles that aren't user-edited).
  - Once replaced by the AI title or an event title, the meeting no longer counts as having a placeholder title (re-running AI doesn't re-title it, the same as recorded meetings today).
  - Recorded meetings are unchanged: they still start as "Untitled Meeting".
- **No calendar association** is made automatically. No participants or organizer. The user can attach an event later with the existing event picker, which searches around the meeting date.
- Notes start empty.
- The meeting appears in Past Meetings and on Home (recent meetings) as soon as it's created.
- Its post-processing (§7) is queued **as soon as it's created**, so transcription can start while the next file converts.

---

## 7. Post-processing queue

Today the transcription service and the AI service each run one job at a time, and refuse others: a second transcription fails with "Another transcription is already in progress", and a second AI auto-run is skipped without any message. Multi-file import would hit this immediately. This project adds a **single serial post-processing queue**.

- **One app-wide queue, strictly first in, first out.** Each entry is one meeting's pipeline: transcribe, then the AI auto-enhancements (exactly what a stopped recording runs today, honoring all existing settings and guards).
- **Who uses the queue:**
  - **Stop Recording** enqueues the just-recorded meeting. It no longer runs it directly.
  - **Import** enqueues each meeting as it's created (§6.3).
  - **Re-transcribe** (meeting detail menu, "Transcribe now", the re-transcribe-after-association prompt) and **Retry** (failed transcription) enqueue that meeting. Both run the full pipeline (transcribe, then AI auto-enhancements). For Re-transcribe that matches today. For Retry it's a small fix: today Retry transcribes but never runs the AI step.
- A meeting already queued or running isn't queued a second time. Asking again is a no-op.
- Recordings don't jump the queue. A recording stopped behind ten queued imports waits its turn.
- **Waiting state:** a meeting whose entry is queued but not yet running shows **"Waiting to transcribe…"** in meeting detail, wherever "Transcribing…" shows today (the same processing presentation, different message). Re-transcribe is disabled for it, as it is while transcribing.
- Failure of one entry (transcription or AI) doesn't stop the queue. The next entry runs.
- If a queued meeting is deleted before its turn, its entry is dropped.
- The queue isn't persisted. After a relaunch, meetings that never got their turn show today's "No transcript yet / Transcribe now" state.
- **Not queued (unchanged):** manual AI actions in meeting detail (Generate/Regenerate summary, re-inferring speaker names). They keep today's behavior, including the existing "ignored if the AI service is busy" guard. No special casing.

### 7.1 Single-track meetings

Meetings with only one audio track (imports) work everywhere a two-track recording does:
- **Transcription:** transcribes and diarizes the single track. The speaker count, voiceprint and speaker-name inference behave as they do for a recording, since diarization already runs on the merged mono signal.
- **Playback, Reveal in Finder, delete, MCP tools, export:** use whichever tracks exist. Most of this already tolerates a missing track. Anything that requires both tracks is fixed.
- **Voiceprint backfill** (developer CLI) accepts single-track meetings.

Two-track recordings behave exactly as before.

---

## 8. Edge cases

| Case | Behavior |
|---|---|
| Import while recording | Allowed. The Import screen shows, the recording continues, and the recording's transcription joins the queue when it's stopped. |
| Import while onboarding is showing | Not possible: menu item disabled, drop refused. |
| Drop while the overlay is already up from a previous drag | N/A: one drag at a time (system). |
| Import action while a run is in progress | Files append to the session and extend the run (§4.1). |
| Very long files (hours) | Supported. Conversion takes longer, and the row shows Converting… throughout. No size limit. |
| Disk full during conversion | The row fails with "Couldn't save the converted audio." Partial output is removed. The queue continues. |
| Source on a removable or network volume that disappears | It fails with "This file was moved or deleted." or the generic message, whichever the failure maps to. |
| File promise that never delivers (the source app fails) | That item fails with the generic message. |
| AI enhancements off, or no model | The pipeline is transcribe only. The placeholder title stays. |
| Transcription models not downloaded yet | The same as after a recording: the first queued transcription downloads them (existing behavior and status). |
| Deleting an imported meeting | The same as any meeting: the audio and row are removed. The session row shows "Deleted" (§5.4). |
| App relaunch | The session and the "Imported" row are gone. Imported meetings remain like any meeting. |

---

## 9. Out of scope

- Cancelling or removing import items, or clearing the session.
- Persisting the import session or the post-processing queue across launches.
- Expanding dropped folders.
- Importing via other routes: the Dock icon, "Open With", the Services menu, URL schemes, the menu-bar extra.
- Keeping, copying or linking to the original file after import.
- Trimming or editing audio before import. Picking among multiple audio tracks. Stereo-as-two-speakers handling.
- Automatic calendar association for imports.
- Queueing or otherwise special-casing manual AI actions.
- A "Show in Biscotti" path from Finder.

---

## 10. Resolved decisions

- **Meeting date fallback chain** (§6.2): embedded creation date → file modification date → import time. Confirmed.
- **Manual AI actions during a busy queue:** no special casing. Today's behavior stands.

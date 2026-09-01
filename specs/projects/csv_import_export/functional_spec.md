---
status: complete
---

# Functional Spec: CSV Import/Export

Meetings can be exported to a CSV file and imported from one. The feature exists so
users can get their data out of Biscotti, and get meeting notes *in* from other apps
(Granola, Otter, Notion exports, ad-hoc scripts). Only the meetings table is covered —
no tags, people, audio, or calendar data.

Entry points are two rows in a new **Import/Export** section in Settings.

## 1. The CSV contract

### 1.1 Columns

The canonical column set, in this exact order, is what export writes as its header row:

```
id,title,created,summary,notes,transcript
```

| Column | Meaning | Required on import |
|---|---|---|
| `id` | Stable unique identifier for the meeting | Yes |
| `title` | Meeting title | Yes |
| `created` | When the meeting happened | Yes |
| `summary` | Markdown summary | No |
| `notes` | User notes (markdown) | No |
| `transcript` | Plain-text transcript (see §4) | No |

### 1.2 Import column resolution

Import needs a header row. Header cells are matched leniently, since CSVs arrive from
other tools:

- A UTF-8 BOM at the start of the file is stripped before parsing.
- Header cells are trimmed of surrounding whitespace and matched case-insensitively.
- These aliases resolve to canonical columns:
  - `document_id` → `id`
  - `document_title` → `title`
  - `document_created` → `created`
- Any column that is neither canonical nor a known alias is ignored entirely.
- If both a canonical name and its alias are present (e.g. `id` and `document_id`),
  the canonical column wins and a warning is recorded.

A CSV whose only identity columns are `document_id`, `document_title`, and
`document_created` — with no `id`/`title`/`created` at all — must import successfully.
(Explicit test case.)

### 1.3 Dates

Export writes: `2026-01-03T14:26:42.017Z` — ISO-8601, UTC, milliseconds, `Z` suffix.

Import accepts, in this order:

1. ISO-8601 with fractional seconds and a zone: `2026-01-03T14:26:42.017Z`,
   `2026-01-03T09:26:42.017-05:00`
2. ISO-8601 without fractional seconds: `2026-01-03T14:26:42Z`, `…-05:00`
3. A bare calendar date `2026-01-03` — interpreted as local midnight
4. A bare integer — epoch time. Values below `100000000000` (1e11) are read as
   **seconds**; values at or above it are read as **milliseconds**. (1e11 seconds is
   the year 5138, so the split is unambiguous in practice.)

Anything else makes the row misformatted: the row is skipped with a warning (§3.2),
the rest of the file still imports.

### 1.4 Escaping (both directions)

RFC 4180. A field is quoted when it contains a comma, a double quote, CR, or LF.
Embedded double quotes are doubled (`""`). Quoted fields may span multiple lines —
this matters because transcripts, notes, and summaries routinely contain newlines.

- **Export** separates rows with CRLF and writes UTF-8 **without** a BOM. Newlines
  *inside* a field are preserved as-is (LF).
- **Import** accepts CRLF, LF, or CR row separators, and tolerates a trailing newline
  at end of file. The file must be valid UTF-8.

## 2. Import

### 2.1 Two-phase flow

Import is strictly **scan, then commit** — the file is read exactly once.

1. **Scan.** Read and parse the whole file into an in-memory structure: one parsed
   record per row, plus a collected summary of errors and warnings. Nothing is
   written to the database during the scan.
2. **Review.** If the scan produced any errors or warnings, show an alert (§3.3).
   Critical errors block; warnings offer Cancel (default) / Continue.
3. **Commit.** Insert the already-parsed records that the scan marked importable
   (misformatted and duplicate rows were excluded during the scan). The file is *not*
   re-read, re-parsed, or re-validated — the exact data produced by the scan is what
   lands in the database.

### 2.2 What an imported row becomes

For each row that survives the scan and is not skipped:

- **`id`** — trimmed. If it parses as a UUID, it becomes the meeting's `id` directly.
  If it does not, a fresh UUID is minted for the meeting and the raw string is stored
  in a new `externalID` field. This is how non-UUID IDs from other apps are supported
  while keeping the UUID primary key.
- **`title`** — trimmed, stored as the meeting title. `editedTitle` is set `true`
  (imported titles are authored content and must never be overwritten by calendar
  association).
- **`created`** — parsed per §1.3, stored as the meeting's `createdAt`. `startDate` and
  `endDate` stay nil, so the meeting's effective date (`startDate ?? createdAt`) is the
  imported value and it sorts correctly in the list.
- **`summary`** — stored as the meeting summary. When non-empty, `editedSummary` is set
  `true` (imported summaries are authored content).
- **`notes`** — stored as the meeting notes.
- **`transcript`** — when non-blank, parsed per §4 into a `TranscriptRecord` with
  `transcriptionMethodId` `"imported"` and made the meeting's preferred transcript.
  When blank, no transcript record is created.
- **`importBatch`** — set to this import's batch ID (§2.3) on every meeting in the run.
- No audio files, no recording duration, no calendar snapshot, no participants or tags.

Imported meetings are indexed for search exactly like recorded ones.

### 2.3 Import batch

A new nullable `importBatch` field on the meeting model, default null (all existing and
all recorded meetings have null).

Every meeting created by a single import run gets the same batch ID: epoch
**milliseconds** at the moment the commit starts. Milliseconds rather than seconds so
two imports in quick succession cannot collide; if the generated value somehow matches
an existing batch, it is incremented until unique.

The field exists to make a future "undo this import" possible. **No user-facing un-import
UI is built in this project** — the only thing that reads the field is the debug-build
affordance in §6.1.

### 2.4 Duplicate handling

A row is a duplicate, and is skipped, when:

- Its `id` is a UUID that already exists as a meeting ID in the database, **or**
- Its `id` is a non-UUID string that already exists as an `externalID` in the database,
  **or**
- An earlier row in the same file already claimed that same ID — the **first**
  occurrence wins, later ones are skipped.

Skipped rows produce a warning (§3.2), never an error. Nothing existing is ever
updated, merged, or overwritten — import only ever inserts.

### 2.5 No AI on import

Auto-enhancements (summarization, speaker-name inference) run only after a recording is
transcribed. Imported meetings never enter that path, so nothing needs to suppress them
— an imported meeting behaves like any other meeting with no audio.

## 3. Errors and warnings

### 3.1 Critical errors (block the import)

Any of these means nothing is imported:

- The file cannot be read, or is not valid UTF-8.
- The file is empty or has no header row.
- After alias resolution, any of `id`, `title`, or `created` is missing from the header.
- The CSV is structurally malformed (e.g. an unterminated quoted field).
- After the scan, **no row is importable** — every row was either misformatted or a
  duplicate. There is nothing to import, so the alert blocks rather than offering
  Continue.

Critical errors are all *file-level*: a problem with an individual row never blocks the
whole import (see misformatted rows below).

### 3.2 Warnings (import can proceed)

- **Misformatted rows:** a row with a blank `id`, a blank `title`, or a `created` value
  that is missing or unparseable per §1.3. The row is **skipped**; the rest of the file
  still imports. Reported as a count with up to 5 example row numbers, e.g.
  "3 rows are missing a required value and will be skipped."
- **No content:** a row where `summary`, `notes`, and `transcript` are all blank. The row
  still imports. Reported as a count.
- **Already in the database:** rows skipped per §2.4. Reported as
  "N meetings already exist in your database, these will be skipped."
- **Duplicate IDs within the file:** reported as a count, first-wins noted.
- **Ragged rows:** a row with a different field count than the header. Short rows are
  padded with empty values; long rows have their extra fields dropped. Reported as a
  count. (If padding leaves a required field blank, the row is a misformatted row.)
- **Ambiguous columns:** both a canonical column and its alias present (§1.2).

### 3.3 The review alert

- **Any critical errors** → blocking alert. Title names the failure; body lists each
  distinct problem with its count and up to 5 example row numbers. Single dismiss
  button. Nothing is imported.
- **Warnings only** → warning alert. Body lists each warning with its count in plain
  language, and states how many meetings will actually be imported. Buttons: **Cancel**
  (default action) and **Continue** (secondary).
- **Neither** → no alert; import proceeds immediately.

Row numbers in messages are 1-based and count the header as row 1, so they match what
the user sees in a spreadsheet.

### 3.4 The result alert

After a commit completes, an alert reports what happened, e.g.
"Imported 42 meetings." — with further lines when anything was skipped:
"3 rows were skipped because those meetings already exist." /
"2 rows were skipped because they were missing a required value."

If the commit itself fails (a database error), an alert reports the failure. A failed
commit leaves the database unchanged.

## 4. Transcript text format

One format, used for the transcript column on export, for the meeting detail **Copy**
button, and parsed on import. It is deliberately both human-readable and machine-
parseable.

### 4.1 Rendering

A speaker turn is a header line followed by the spoken text:

```
[0:23] Steve
Let's get started.

[0:31] Priya
I pushed the fix this morning.
```

- Timestamp is `M:SS`, or `H:MM:SS` from one hour up (matching the app's existing
  playback-time formatting).
- Speaker name is the assigned person's name where the speaker has been mapped,
  otherwise the diarization label (`Speaker 0`) — the same resolution the transcript
  view uses on screen.
- Consecutive segments from the same speaker (same non-nil speaker ID) collapse
  into **one** turn, their text joined by a space — segment boundaries are
  diarization artifacts, and a header per fragment would make the Copy output and
  the CSV unreadable. A turn's timestamp is its first segment's start. Segments
  without a speaker ID never collapse; blank segments are dropped.
- One blank line between turns.

This replaces the current Copy output (`Steve  0:23` on the header line). The change is
intentional: the bracketed form is unambiguous to parse.

### 4.2 Parsing

Input is free text, which may be Biscotti's own format or plain text from another app.

1. Split into lines on CRLF, LF, or CR. Trim each line. Skip blank lines.
2. A line matching `[<timestamp>] <name>` is a **header**: it sets the current speaker
   name and current timestamp for every following line, until the next header.
   Timestamps parse as `M:SS`, `MM:SS`, `H:MM:SS`, or `HH:MM:SS`.
   - If the name portion contains a colon (`[0:23] Steve: hello there`), the text before
     the first colon is the speaker name and the text after it is treated as a content
     line — several other apps emit that shape.
3. Every non-header line becomes one transcript segment carrying the current speaker and
   timestamp. **Line breaks make new segments** — no merging of consecutive lines.
4. Before any header is seen, the current speaker is `Unknown Speaker` and the current
   timestamp is `0:00`. A plain transcript with no headers at all therefore imports as a
   sequence of `Unknown Speaker` segments at `0:00` — which is all it can be.
5. Each distinct speaker name gets a sequential speaker ID (0, 1, 2 …) in order of first
   appearance, so the existing speaker-mapping UI works on imported transcripts.
6. Segment `startTime` is the current header's timestamp; `endTime` equals `startTime`
   (imported transcripts carry no durations).
7. A transcript that yields zero segments produces no transcript record.

Round-trip preserves every speaker, timestamp, and word: parsing an exported
transcript reproduces the same speakers and times and the same words in the same
order. It does not preserve segment boundaries — consecutive same-speaker
segments are one segment per turn after a round-trip, because render collapses
them (§4.1).

## 5. Export

### 5.1 Content

- **Every** meeting in the database, no filtering.
- Sorted by effective date (`startDate ?? createdAt`) **descending** — newest first.
- Header row exactly `id,title,created,summary,notes,transcript`.

Per row:

| Column | Value |
|---|---|
| `id` | The meeting's UUID. `externalID` is **never** exported — our UUID is the identity we hand out. |
| `title` | The meeting title. |
| `created` | Effective date, formatted per §1.3 (`2026-01-03T14:26:42.017Z`). |
| `summary` | Summary markdown, empty when there is none. |
| `notes` | Notes markdown, empty when there is none. |
| `transcript` | The preferred transcript rendered per §4.1 with speaker names resolved. Empty when the meeting has no transcript. |

A database with no meetings exports a header-only file.

### 5.2 Flow

Export is asynchronous and does not block the UI:

1. The user presses **Export**. The button is replaced by a spinner.
2. Generation runs off the main actor and writes the CSV to a file in the temporary
   directory, returning that path on completion.
3. On completion the spinner clears and a save dialog opens, pre-filled with the
   filename `Biscotti_export_{timestamp}.csv` where `{timestamp}` is local time as
   `yyyy-MM-dd-HHmmss` (e.g. `Biscotti_export_2026-09-01-142642.csv`).
4. Confirming moves the temporary file to the chosen location. Cancelling deletes the
   temporary file.
5. A generation or move failure surfaces as an alert; the temporary file is cleaned up.

## 6. Settings UI

A new **Import/Export** section, placed after Custom Vocabulary and before Calendars.

Two rows, each a title, a descriptive subtitle ending in a "Learn more" link, and a
trailing button:

| Title | Subtitle | Button |
|---|---|---|
| Import Meetings | Import meetings from other apps, via CSV. *Learn more.* | **Import** |
| Export Meetings | Export all meetings to CSV. *Learn more.* | **Export** |

- **Learn more** uses the app's established green (`.sage`) settings-link treatment and
  opens `https://github.com/scosman/Biscotti/blob/main/App/ImportingExporting.md`
  in the browser — the same pattern as the MCP help link.
- **Import** opens a file-selection dialog limited to `.csv`, single selection. Choosing
  a file runs the flow in §2.1.
- **Export** shows a spinner in place of the button while generating, then opens the save
  dialog (§5.2). Both buttons are disabled while an operation is in flight.

### 6.1 Debug build: Delete Imported Meetings

In debug builds only, the existing **Debug** section at the bottom of Settings gains a
**Delete Imported Meetings** button, styled like its neighbours. It deletes every meeting
whose `importBatch` is non-null — the whole imported population, not one batch — so a
developer can re-run an import repeatedly against a clean slate.

Pressing it counts the meetings and confirms:

- Title: **"Delete N meetings?"**
- Body: **"This will delete N meetings (and leave M meetings)."** — where N is the number
  of imported meetings and M the number that will remain.
- Buttons: **Cancel** (default) and **Delete** (destructive).

Confirming deletes them, along with their transcripts and search-index entries, and
refreshes the meeting list. A result alert reports "Deleted N meetings."

When there are no imported meetings, pressing the button shows "No imported meetings to
delete." instead of a confirmation.

This is a developer affordance, not a product feature: it never appears in release
builds, and it is not a substitute for the real un-import flow (§8, out of scope).

## 7. Documentation

A new `App/ImportingExporting.md`, short and user-facing, covering:

- What can be imported and exported (meetings only, and which fields)
- The exact column names, the accepted aliases, and that extra columns are ignored
- Accepted date formats
- The transcript format, with a small example, and what happens to plain-text transcripts
- Duplicate handling (existing IDs are skipped, never overwritten)
- What the warnings and errors mean
- How export names and sorts its file

## 8. Out of scope

- Un-importing / undoing a single batch as a user-facing feature (the `importBatch` field
  is stored for it; the only consumer is the debug-build bulk delete in §6.1)
- Importing or exporting tags, participants, organizers, audio, or calendar data
- Updating or merging into existing meetings (import only inserts)
- Non-comma dialects (TSV, semicolon), other encodings, XLSX
- A progress bar or cancellation for long imports/exports (spinner only)
- Import from the menu bar, a drag-and-drop target, or a URL scheme

## 9. Constraints

- The whole file is held in memory during scan and commit; memory use is proportional to
  file size. Acceptable for the expected scale (thousands of meetings, tens of MB).
- Import commits as one batch, after which the meeting list and search index refresh.
- Export generation runs off the main actor; the UI stays responsive throughout.

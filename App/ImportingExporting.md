# Importing and Exporting Meetings

Biscotti can export your meetings to a CSV file, and import meetings from one — so
you can get your data out, or bring meeting notes in from other apps (Granola,
Otter, Notion exports, or your own scripts).

Only meetings are covered: the title, date, summary, notes, and transcript. Audio
files, tags, people, and calendar data are not exported or imported.

Both features live in **Settings → Import/Export**.

## The CSV file

The first row of the file is a header. Export writes exactly these columns, in
this order:

```
id,title,created,summary,notes,transcript
```

Import is lenient about the header:

- Column names are matched ignoring case and surrounding spaces.
- These aliases from other apps' exports are understood: `document_id` → `id`,
  `document_title` → `title`, `document_created` → `created`. A file with only
  the `document_*` names imports fine.
- Any other column is ignored — extra columns from another app's export don't
  hurt.

`id` is each meeting's unique identifier. It can be a UUID, or any unique string
(another app's document ID works). Dates in the `created` column can be:

- ISO-8601 with fractional seconds: `2026-01-03T14:26:42.017Z`
- ISO-8601 without fractional seconds: `2026-01-03T14:26:42Z` (offsets like
  `-05:00` are fine in both forms)
- A bare calendar date: `2026-01-03` (read as local midnight)
- A bare integer (epoch time): below 100000000000 it is read as seconds,
  otherwise as milliseconds

Anything else makes that row invalid — it is skipped with a warning, and the
rest of the file still imports.

A file with only a header row (no data rows) is valid to import: nothing is
imported, and Biscotti reports "Imported 0 meetings."

## The transcript format

The transcript column is plain text. Biscotti's own format marks each speaker
turn with a bracketed timestamp and the speaker's name:

```
[0:23] Steve
Let's get started.

[0:31] Priya
I pushed the fix this morning.
```

On import, any line that isn't a header line becomes part of the current
speaker's turn. A plain transcript with no headers at all imports as one
"Unknown Speaker" per line at 0:00 — you can rename speakers in the meeting
afterwards. The form `[0:23] Steve: hello there` (name and text on one line, as
some other apps write it) is also understood.

## Duplicates

Import never updates or overwrites an existing meeting. A row whose `id` is
already in your library (or appears twice in the same file — the first
occurrence wins) is skipped with a warning.

## Warnings and errors

- **Warnings** (you can continue or cancel): rows that were skipped because
  they already exist, were missing a required value (`id`, `title`, or
  `created`), had the same ID as an earlier row, or had a different number of
  fields than the header; rows with no summary, notes, or transcript (these
  still import); a column appearing alongside its alias.
- **Errors** (the import is blocked): the file can't be read, isn't UTF-8 text,
  has no header row, is missing `id`, `title`, or `created` columns, isn't
  valid CSV, or contains no meetings that can be imported.

## Export

Export writes **every** meeting, newest first, to a file named
`Biscotti_export_{timestamp}.csv` (for example
`Biscotti_export_2026-09-01-142642.csv`). You pick where to save it.

The `id` column always carries Biscotti's own UUID for each meeting — an
imported meeting's original (non-UUID) identifier is never re-exported. If you
round-trip a file through another tool, use Biscotti's UUIDs as the identity.

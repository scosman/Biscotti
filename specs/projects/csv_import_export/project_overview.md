---
status: complete
---

# CSV Import/Export

I want to add a CSV import/export functionality.

Just for the meetings table.

Columns: It's important we use these exact column names.

- columns: `id,title,created,summary,notes,transcript` (used for export)
- Allow some flexibility on import without any UI (should have test case for a csv with these columns and no id/title/created)
  - `document_id` -> `id`
  - `document_title` -> `title`
  - `document_created` -> `created`

## Import

- Add "import_batch" field to meeting data model, default null. When we import a CSV we generate a batch ID (epoch-time), and set this same value on all. This lets us un-import the CSV.
- Should ignore extra columns.
- Flow/Errors/Warnings
  - Warnings and errors
    - Critical errors if CSV is missing key fields: ID, title, or created. Or if any rows are missing these (or invalid values in these).
    - Warning: if a meeting doesn't have at least one of summary/notes/transcript, it's a warning.
    - Warning: on IDs that already exist in DB, something like "N meetings already exist in your database, these will be skipped."
  - Flow
    - First scan into a data structure.
      - Scan data into data field
      - Scan also collects error/warning summary.
    - Shows an alert to user if warnings/errors are non-zero. If critical, the alert blocks. If only warnings it shows a warning with clear description of the issue(s) (default action is cancel, secondary to "Continue").
    - Import (if no errors, or they click Continue on the alert)
      - Use the in-memory data structure, import to DB. No new scan of file, use the exact data we already parsed.
- Create "App/ImportingExporting.md", a short guide for this explaining the process and fields we expect in CSV. Can link to it from the app.
- Note: some reasonable parsing flexibility — the CSVs could be coming from other apps/scripts. IDs just need to be unique, not a UUID (do we support this?).

## Export

- Exports meetings to CSV, with save-dialog to pick location.
- Has header row `id,title,created,summary,notes,transcript`
- Filename `Biscotti_export_{timestamp}.csv`
- Sorted newest first
- Async: saves to tmp returning a PATH, callback when done (UI shows spinner). The UI will offer an option on where to save it, which does the file move.
- Export transcript should use the same formatter as the "Copy" button does.

## General

- CSV will need newlines: escaping is important
- Date format: `2026-01-03T14:26:42.017Z` — whatever format this is, we should use and support.

## Settings

- New section below custom vocab
- Section title "Import/Export"
- "Learn more" links to the GitHub "App/ImportingExporting.md" on main. Usual "green text" link format we use in settings.
- 2 rows
  - "Import Meetings", "Import meetings from other apps, via CSV. Learn more.", [Import], button opens file selector dialog
  - "Export Meetings", "Export all meetings to CSV. Learn more." [Export], button shows spinner while generating file, then save dialog when ready.

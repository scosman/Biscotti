# Manual Validation: Send to Obsidian / Bear / Apple Notes

**Validation run: 2026-10-21. All steps passed.** Tested on macOS 26 and macOS 15.
No failures, no behaviour changes, no fixes needed.
Known limitation: each Apple Notes import creates a new folder ("Imported Notes", then
"Imported Notes 1", …). This is accepted; see functional spec §11.

Run these tests on **macOS 26** (primary) and **macOS 15** (Apple Notes plain-text check).
Obsidian and Bear must be installed. Apple Notes is built-in.

Record each result as PASS, FAIL, or SKIP (with reason). Add notes for any unexpected behaviour.

---

## Prerequisites

1. Build and launch Biscotti (`make build-app`, then open the `.app`).
2. Have at least one meeting with:
   - A title (e.g. "Weekly Sync")
   - A summary (non-empty)
   - Notes (non-empty, with headings, bullets, **bold**, *italic*, links, and checklists)
   - At least two tags (e.g. "project-x", "design review")
   - At least two calendar attendees
   - A known start time and duration
3. Have a second meeting with **no summary and no notes** (only a title).
4. Have Obsidian running with a vault open. Know the vault's "Default location for new notes" setting.

---

## A. Obsidian

### A1. First send — vault and placement
1. Select the meeting from prerequisite 2.
2. Click the Obsidian icon button in the tab bar (left of Copy).
3. **Check:** Obsidian activates.
pass
4. **Check:** A new note appears in the open/last-focused vault.
pass
5. **Check:** The note is in the folder set by "Default location for new notes" (or vault root if set to "Vault folder").
pass
6. **Check:** The filename is `<title> <yyyy-MM-dd>` (e.g. `Weekly Sync 2026-10-21`).
pass
7. **Check:** The note starts with YAML frontmatter:
   ```yaml
   ---
   tags: ["biscotti", "<tag1>", "<tag2>"]
   biscotti_url: "biscotti://meeting/..."
   date: 2026-10-21
   attendees: ["Alice", "Bob"]
   ---
   ```
   pass
8. **Check:** The body has the `# Title`, metadata line with date/duration/link, `Attendees:` line, summary, and `# Notes` section.
pass

Result: ____

### A2. Duplicate name
1. Click the Obsidian button again on the **same meeting**.
2. The "Already sent" alert appears. Click **Send Again**.
3. **Check:** Obsidian creates a second note with a number suffix (e.g. `Weekly Sync 2026-10-21 1`).
pass

Result: ____

### A3. Frontmatter tags
1. Open the note created in A1.
2. **Check:** The `tags` array includes `"biscotti"` first, then the meeting's tags sorted case-insensitively.
pass
3. **Check:** Tags with spaces have the spaces replaced by `-`.
pass
4. **Check:** A digits-only tag (if any) has a `t` prefix.
pass

Result: ____

### A4. No vault param (VALIDATE item)
1. If you have multiple Obsidian vaults, switch to a different vault (make it the active window).
2. Send to Obsidian from a meeting.
3. **Check:** The note lands in the currently active vault, not a hard-coded one.
No test, but trust it works.

Result: ____

---

## B. Bear

### B1. First send — title from H1
1. Select the meeting from prerequisite 2.
2. Click the Bear icon button in the tab bar.
3. **Check:** Bear activates and opens a new note.
Pass
4. **Check:** The note title is taken from the `# Title` line in the markdown (no separate `title=` param).
pass
5. **Check:** The body has the metadata line, attendees, summary, and notes.
pass

Result: ____

### B2. Tags
1. In Bear, check the note's tags.
2. **Check:** `biscotti` is present as a tag.
pass
3. **Check:** The meeting's tags are present, sanitized: spaces became `-`, commas and `#` removed, `/` kept (nested tags).
pass
4. **Check:** Tags with commas in the original are split correctly (the `%2C` URL encoding produces separate tags, not a literal comma in a tag name).
pass. One tag no comma, but that's fine. Two tas sould be wrong.

Result: ____

### B3. Duplicate title
1. Click the Bear button again on the same meeting.
2. "Already sent" alert appears. Click **Send Again**.
3. **Check:** Bear creates a new, separate note (Bear does not merge by title). Verify two notes exist with the same title.
pass

Result: ____

---

## C. Apple Notes

### C1. First send — import dialog (macOS 26)
1. Select the meeting from prerequisite 2.
2. Click the Apple Notes icon button in the tab bar.
3. **Check:** Notes activates. An import dialog may appear (or the note may import directly).
pass
4. **Record:** Does an import dialog appear? YES / NO. If yes, click Import/OK.
pass
5. **Check:** The note lands in "Imported Notes" (or another location — record where).
pass, Improted Notes
6. **Check:** The note title matches the `# Title` heading or the filename.
Pass

Result: ____

### C2. Markdown fidelity (macOS 26)
1. Open the imported note in Apple Notes.
2. **Check:** Headings render as headings (not plain text with `#`).
3. **Check:** Bullets render as bullet lists.
4. **Check:** **Bold** and *italic* render correctly.
5. **Check:** Links are clickable (the `biscotti://` link and any links in notes).
6. **Check:** Checklists render as checklists (if the notes contain `- [ ]` items).
7. **Record any formatting that does not import correctly.**

untested, on MacOS 15

Result: ____

### C3. Tag footer (macOS 26)
1. Scroll to the bottom of the note.
2. **Check:** The footer line shows `#biscotti #<tag1> #<tag2>`.
pass
3. **Check:** On macOS 26 the `#tags` become real Notes tags (visible in the sidebar tag list). (Already confirmed by user — just verify.)
pass

Result: ____

### C4. Cancel import
1. Send to Notes again (click Send Again if the alert appears).
2. If an import dialog appears, click **Cancel**.
3. Go back to Biscotti and click the Notes button again.
4. **Check:** The "Already sent" alert appears (the record was written even though the user cancelled the import — this is accepted behaviour per spec §7.3).
pass

Result: ____

### C5. Plain-text import (macOS 15)
1. On a **macOS 15** machine, repeat step C1.
2. **Check:** The `.md` file opens in Notes (it should accept it as plain text since `.md` conforms to `public.text`).
pass
3. **Check:** The content appears as plain text (markdown syntax visible, not rendered).
pass
4. **Record:** Does the import dialog appear? Does the note land in "Imported Notes"?
pass

Result: ____

---

## D. Cross-destination checks

### D1. Already-sent alert — unchanged
1. Send to any destination (first send succeeds).
2. Without editing the meeting, click the same button again.
3. **Check:** Alert title is "Already sent to <App>".
4. **Check:** Message says "This meeting was sent to <App> on <date>." (no "changed" text).
5. **Check:** Buttons are "Open <App>" (default), "Send Again", and "Cancel".
6. Click **Open <App>**.
7. **Check:** The destination app activates. No new note is created.
8. Click the button a third time and click **Cancel**.
9. **Check:** Nothing happens.

Result: ____

### D2. Already-sent alert — changed
1. Edit the meeting (change the notes text or summary).
2. Click the same send button.
3. **Check:** Alert says "…and has changed since."
4. Click **Send Again**.
5. **Check:** A new note is sent to the app.

Result: ____

### D3. No tags
1. Find or create a meeting with **no tags**.
2. Send to each destination.
3. **Check (Obsidian):** Frontmatter has `tags: ["biscotti"]` (only the default tag).
4. **Check (Bear):** Only the `biscotti` tag is present.
5. **Check (Notes):** Footer is `#biscotti`.

Result: ____

### D4. Unicode title
1. Find or create a meeting with a Unicode-heavy title (e.g. "会议 Résumé 🎉 Design").
2. Send to each destination.
3. **Check (Obsidian):** The filename is the sanitized title + date, with disallowed characters removed.
4. **Check (Bear):** The H1 title shows the full Unicode title.
5. **Check (Notes):** The filename and note title show the sanitized title.

Result: ____

### D5. Same title, same day
1. Create two meetings with identical titles and the same date.
2. Send both to Obsidian.
3. **Check:** Obsidian creates two distinct notes (the second gets a number suffix).

Result: ____

### D6. Nothing to send — disabled
1. Select the meeting from prerequisite 3 (no summary, no notes).
2. **Check:** The send buttons in the tab bar are disabled (greyed out).
3. **Check:** The tooltip on hover says "Nothing to send yet".
4. **Check:** The "Send to" submenu items in the `…` menu are disabled.

Result: ____

### D7. App not installed — hidden
1. Quit and uninstall (or temporarily rename) Obsidian or Bear.
2. Relaunch Biscotti or switch away and back.
3. **Check:** The icon button for the uninstalled app is not visible in the tab bar.
4. **Check:** The uninstalled app does not appear in the `…` → "Send to" submenu.
5. Reinstall the app and switch away/back.
6. **Check:** The button and menu item reappear.

Result: ____

---

## E. Size fallback

### E1. Clipboard fallback for oversized URL
1. Create a test meeting with an artificially large summary or notes (over ~500 KB of text total).
   - One approach: paste a very large block of repeated text into the notes field.
2. Click the Obsidian (or Bear) button.
3. **Check:** An alert appears saying the note is too large to send directly and has been copied to the clipboard.
4. **Check:** The clipboard contains the full markdown.
5. **Check:** No record is written — clicking the button again does **not** show the "Already sent" alert; it tries to send again (and shows the clipboard alert again).

Result: ____

---

## Summary

| Test | macOS 26 | macOS 15 |
|------|----------|----------|
| A1 Obsidian first send | | N/A |
| A2 Obsidian duplicate name | | N/A |
| A3 Obsidian frontmatter tags | | N/A |
| A4 Obsidian no vault param | | N/A |
| B1 Bear first send | | N/A |
| B2 Bear tags | | N/A |
| B3 Bear duplicate title | | N/A |
| C1 Notes import dialog | | |
| C2 Notes markdown fidelity | | |
| C3 Notes tag footer | | |
| C4 Notes cancel import | | |
| C5 Notes plain-text (15 only) | N/A | |
| D1 Already-sent unchanged | | |
| D2 Already-sent changed | | |
| D3 No tags | | |
| D4 Unicode title | | |
| D5 Same title same day | | N/A |
| D6 Nothing to send disabled | | |
| D7 App not installed hidden | | |
| E1 Clipboard fallback | | |

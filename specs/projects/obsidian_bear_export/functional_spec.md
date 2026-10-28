---
status: complete
---

# Functional Spec: Send meeting notes to Obsidian, Bear and Apple Notes

The source of intent is `project_overview.md` (the original spec plus the 2026-10-21 addendum).
This doc records the decisions made with the user in planning. Where it differs from the
overview, this doc wins. Deviations are listed in §12 and must be called out in the PR summary.

**Design goal: keep it simple.** The model is "send, not sync": Biscotti sends a note and
remembers *that* it sent it. It does not track the note's identity in the other app.

## 1. Codebase findings

| Topic | Finding | Consequence |
|---|---|---|
| Markdown | There is no whole-meeting exporter. The summary and the notes are each markdown already. Copy copies only the active tab. | A small pure function joins the title, a metadata line, the summary and the notes (§3). |
| Sandbox | Not sandboxed. Hardened runtime. Deployment target macOS 15. | URL schemes, `NSWorkspace` and `$TMPDIR` hand-off need no entitlements. No availability gating. |
| Persistence | SwiftData `@Model Meeting`. Arrays are stored as JSON `Data` behind a `@Transient` accessor (`TranscriptRecord.vocabularyUsed`). Additive fields with defaults need no migration. | `sentExports` uses the same pattern (§5). |
| Alerts | Only SwiftUI `.alert` is used; there is no `NSAlert`. | SwiftUI `.alert`. |
| Menus | The meeting header has an `…` overflow menu. There is no share or export menu. | Add a "Send to" submenu to `…` (§10.3). |
| Notes on macOS 15 | Notes.app (15.6) declares `public.text` as a viewable type, and `.md` conforms to it. | The `.md` hand-off is expected to work on 15, as plain text (VALIDATE). |

## 2. Behaviour summary

- One small icon button per **installed** destination sits left of the meeting detail tab bar's Copy button (Copy is at the far right), in the order Obsidian, Bear, Apple Notes.
- The same actions are in the `…` menu → **Send to ▸**.
- The content is always the whole meeting (title + metadata + summary + notes), whichever tab is shown.

Click logic, identical for all three destinations:
1. **No record → send.** Hand the note to the app (§7). If the hand-off succeeds, write or replace the record for that destination: `{destination, contentHash, sentAt}`.
2. **Record exists → alert** (§10.4): **Open <App>** (default) just makes the app active. **Send Again** sends a new note and replaces the record. **Cancel** does nothing.
3. **Nothing to send** (summary and notes both empty after trimming) → buttons and menu items are disabled.

Biscotti cannot open, update or detect the specific note in the other app. This is accepted.

## 3. Content

### 3.1 Body (all destinations)

```markdown
# Weekly Sync

2026-10-21 10:00 · 42 min · [Open in Biscotti](biscotti://meeting/<UUID>)
Attendees: Alice, Bob

<summary markdown, verbatim>

# Notes

<notes markdown, verbatim>
```

- **Title:** the current title, trimmed, with newlines collapsed to spaces. If it is empty, use `Untitled Meeting`.
- **Metadata line:** the start time in the current time zone, formatted `yyyy-MM-dd HH:mm` with the `en_US_POSIX` locale. Then the duration (`recordingDuration ?? duration`, in whole minutes: `42 min`, or `1 h 05 min`), which is omitted with its `·` when unknown or zero. Then the link from `AppLink.meeting(id:target: .tab(.summary)).url`. There is no calendar link.
- **Attendees line:** the calendar attendees' names, in calendar order, without empty names. Omit the line if there are none.
- **Summary:** verbatim, trimmed. Omit it if empty. There is no wrapper heading, because the summary has its own headings.
- **Notes:** `# Notes`, then the notes verbatim and trimmed. Omit both if the notes are empty.
- Blocks are joined with one blank line. Line endings become `\n`. The document ends with exactly one `\n`.
- The output is deterministic: no export time and no relative dates. A time-zone change alters `HH:mm` and so reads as "changed". This is accepted.

### 3.2 Per-destination additions
- **Obsidian:** prepend frontmatter. Key order is fixed. String values are double-quoted with JSON-style escaping. Omit `attendees` if empty.
  ```yaml
  ---
  tags: ["biscotti", "project-x"]
  biscotti_url: "biscotti://meeting/<UUID>"
  date: 2026-10-21
  attendees: ["Alice", "Bob"]
  ---
  ```
- **Bear:** no change to the body. Tags go in the `tags=` URL param.
- **Apple Notes:** append one footer line after a blank line: `#biscotti #project-x`. (The user confirmed that inline `#tag` text becomes real Notes tags on macOS 26. On macOS 15 it shows as plain text, which is accepted.)

## 4. Tags

`biscotti` comes first, then the meeting's tags: sanitized for the destination, with empty results dropped, sorted by lowercased value, and deduped case-insensitively. Any meeting tag equal to `biscotti` is dropped. Tags are flat.

| Destination | Sanitize |
|---|---|
| Bear | Trim. Whitespace runs become `-`. Remove `,` and `#`. Keep `/` (nested tags). |
| Obsidian | Trim. Whitespace runs become `-`. Keep only letters, digits, `_`, `-` and `/`. Trim `/` at the ends. A digits-only tag gets the prefix `t`. |
| Apple Notes | Trim. Whitespace runs become `-`. Keep only letters, digits, `_` and `-`. (The user confirmed these rules on macOS 26.) |

The Bear and Obsidian rules are VALIDATE items for the manual phase.

## 5. Data model

In `DataStore`:

```swift
public enum ExportDestination: String, Codable, Sendable, CaseIterable {
    case obsidian
    case bear
    case appleNotes = "apple-notes"
}

public struct SentExport: Codable, Sendable, Equatable {
    public var destination: ExportDestination
    public var contentHash: String   // lowercase SHA-256 hex (§6)
    public var sentAt: Date
}
```

- `Meeting` gets a JSON `Data`-backed `sentExports: [SentExport]`. The default is empty, so existing meetings read as `[]` and no migration is needed.
- There is at most one record per destination; a new send replaces it.
- Records are exposed on `MeetingDetailData`. They are deleted with the meeting. If an app is uninstalled, its records are kept.

## 6. Hash

`contentHash` is the SHA-256 (lowercase hex) of the exact text sent plus the tags:
`markdown + "\n" + tags.joined(separator: ",")`.
- The markdown is the full text: frontmatter + body for Obsidian; the body (including the tag footer) for Notes.
- At click time, the same code regenerates the hash. Equal means "not changed"; it only selects the alert message.

## 7. Transports

### 7.1 Obsidian (URL)
`obsidian://new?name=<filename>&content=<markdown>`
- There is no `vault` param, so Obsidian uses its open or last-focused vault (VALIDATE).
- `name=` (not `file=`) makes Obsidian place the note per the user's "Default location for new notes" setting.
- **Filename:** `<title> <yyyy-MM-dd>`, for example `Weekly Sync 2026-10-21`. If the name already exists, Obsidian adds a number (VALIDATE).
- Success means `NSWorkspace.open` returned true.

### 7.2 Bear (URL)
`bear://x-callback-url/create?text=<markdown>&tags=<csv>&open_note=yes`
- There are no callbacks and no `title=` param. Bear takes the title from the `# Title` line (VALIDATE).
- Success means `NSWorkspace.open` returned true.

### 7.3 Apple Notes (file hand-off)
- Write the markdown to `$TMPDIR/biscotti-export/<uuid>/<filename>.md`. The filename is the sanitized title; the folder per export prevents name collisions.
- Open the file with Notes (`com.apple.Notes`): `NSWorkspace.open([file], withApplicationAt:, configuration:)` with `activates = true`.
- Success means the completion handler reports no error. If the user cancels Notes' import dialog, the record is still written. This is accepted.
- There is no cleanup: macOS purges `$TMPDIR`, and each file is a few KB.
- No AppleScript, share sheet or clipboard is used.

### 7.4 Shared rules
- **Filename sanitization** (Obsidian and Notes): remove `* " \ / < > : | ? # ^ [ ]` and control characters, collapse whitespace, trim, strip a leading `.`, and cut to ≤ 120 characters on a character boundary. Then re-trim. If empty, use `Untitled Meeting`.
- **URL encoding** (Obsidian and Bear): percent-encode each query value with only `A–Z a–z 0–9 - . _ ~` allowed, so a space becomes `%20` and never `+`. Do not use `URLQueryItem` encoding.
- **Size fallback** (Obsidian and Bear): if the final URL string is over 512,000 UTF-8 bytes (500 × 1024), do not open it. Put the markdown on the clipboard and show: `This note is too large to send to <App> directly. It's been copied to your clipboard. Paste it into a new note in <App>.` (**OK**). No record is written.
- **Open <App>:** `NSWorkspace.openApplication(at: appURL, configuration:)` with `activates = true`.

## 8. Detection
- Obsidian: `urlForApplication(toOpen: obsidian://)`. Bear: `urlForApplication(toOpen: bear://)`. Apple Notes: `urlForApplication(withBundleIdentifier: "com.apple.Notes")`.
- A nil result means not installed: hide the button and the menu item.
- A never-launched Obsidian reads as not installed. This is accepted.
- **Coding-time decision: caching.** The coding agent measures the cost of the three lookups (a timing log in a debug build or a quick test).
  - If it is cheap (well under 1 ms in total), look them up live on each view refresh. There is no cache.
  - If it is not cheap, cache the results in memory and refresh at launch and on `NSApplication.didBecomeActiveNotification`.
  - Record the measured number and the choice in this section.
  - **Decision (Phase 2):** Measured ~0.1 ms total for all three lookups in a debug build on Apple Silicon. Live lookup on each call, no cache.

## 9. Errors
Only two alerts exist: the size fallback (§7.4) and "Already sent" (§10.4). Everything else fails quietly with a log entry: an `open` that returns false, a Notes completion error, or a temp-file write error. No record is written on failure. There is no double-click guard; a fast double click can send two notes, and this is accepted.

## 10. UI

### 10.1 Buttons
- They sit in the meeting detail tab bar, left of Copy (Copy is at the far right), with the same control size and style (`.borderless`, `.controlSize(.small)`, `.inkSecondary`). The icons have no labels.
- **Icons:** user-supplied outline SVGs in `DesignSystem/Resources/Icons/` (`obsidian-outline.svg`, `bear-outline-plain.svg`, `apple-notes-outline.svg`). They are rendered as template images at ~17 pt (20% larger than Copy's symbol, ~14 pt). The Copy button keeps its default size.
- There is no state dot.

### 10.2 Tooltip = accessibility label
| State | Text |
|---|---|
| Normal (with or without a record) | `Send to Obsidian` / `Send to Bear` / `Send to Apple Notes` |
| Nothing to send | `Nothing to send yet` |

The tooltip does not show the record state; the alert does that.

### 10.3 Menu
The `…` overflow menu in the meeting header gets a **Send to ▸** submenu with the installed apps (Obsidian, Bear, Apple Notes). It uses the same action as the buttons and is disabled when there is nothing to send.

### 10.4 "Already sent" alert
- Title: `Already sent to <App>`
- Message (not changed): `This meeting was sent to <App> on <date>.`
- Message (changed): `This meeting was sent to <App> on <date> and has changed since.`
- `<date>` is `sentAt` in the abbreviated date style (for example `Oct 21, 2026`).
- Buttons: **Open <App>** (default), **Send Again**, **Cancel** (cancel role).
- `<App>` is `Obsidian`, `Bear` or `Apple Notes`.
- The alert is shown by the meeting detail view, because it only appears in response to a click.

## 11. Manual validation (its own phase, on real machines including macOS 26 and macOS 15)
1. Obsidian: `new` with no vault uses the open vault, `name=` follows the default-location setting, a duplicate name gets a number, and the frontmatter tags and `attendees` work.
2. Bear: the title comes from the H1 with no duplicate title, the `tags=` sanitization works, and `%2C` separators are split.
3. Apple Notes: the hand-off triggers import; check whether the import dialog shows each time and what cancel does; the note lands in "Imported Notes"; check the fidelity of headings, bullets, bold/italic, links and checklists on macOS 26; plain-text import works on macOS 15; the title comes from the H1 or the filename (they match). (The footer `#tags` were already confirmed by the user.)
4. All: first send; repeat click unchanged → Open, Send Again and Cancel; repeat after an edit → "changed" text; the Notes import is cancelled → the record still exists → the alert shows on the next click; a meeting with no tags; a unicode-heavy title; two meetings with the same title on the same day; nothing to send → disabled; an app not installed → hidden.
5. Over 500 KB → clipboard fallback (use a padded test meeting).

**Validation run (2026-10-21): all steps passed.** No failures, no behaviour changes, no fixes needed. See `manual_validation.md` for the full script and per-step results.

**Known limitation (accepted):** Notes puts each import into a new folder: the first send lands in "Imported Notes", the next in "Imported Notes 1", and so on. Notes chooses the folder; the file hand-off cannot change it. Only a different transport (AppleScript, or the Notes share sheet) can target the default folder, and §13 excludes those. We keep the import transport and accept the extra folders.

## 12. Deviations from the overview (call out in the PR)
- **D1 "Send, not sync"** (approved): no x-callbacks, locators, open-existing or update-in-place for Bear and Obsidian. All three use the Notes-style record + alert. "Open <App>" only makes the app active.
- **D2 Record shape:** `SentExport {destination, contentHash, sentAt}`. `ExportRecord` with `id`, `locator`, `auxPath` and `updatedAt` is dropped. The `file` future case and the `obsidian-url` raw value are dropped (now `obsidian`).
- **D3 Obsidian location:** `name=` + the user's default-location setting, not `file=Biscotti/…`. The filename is `<title> <date>`.
- **D4 Content:** a new small exporter: summary + notes, no transcript. `# Notes` heading.
- **D5 Labels:** "Send to <App>" (always) in place of "Copy to / Open in / Exported to". There is one shared alert text for all apps, with a date.
- **D6 Alerts:** SwiftUI `.alert`, not `NSAlert`.
- **D7 Icons:** user-supplied outline SVGs for all three, not app icons from `NSWorkspace`.
- **D8 No temp cleanup** for Notes files (macOS purges `$TMPDIR`).
- **D9 No double-click guard.**
- **D10 Menu:** "Send to ▸" submenu in the `…` menu (there is no share or export menu).

## 13. Out of scope
Transcript export, settings, vault or folder choice, opening the exact note, update in place, detection of deleted notes, AppleScript, iOS, and a plugin system.

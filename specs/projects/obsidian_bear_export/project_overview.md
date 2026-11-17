---
status: complete
---

# Spec: Export meeting notes to Obsidian, Bear and Apple Notes

## Read first (for the coding agent)
Biscotti is a macOS meeting recorder that already saves meeting notes as markdown. This
spec adds one-click export of those notes to Obsidian and Bear.

Technical details about third-party URL schemes come from their public docs as of
Oct 2026, plus some unverified assumptions. Anything marked **VALIDATE** must be tested
against the real apps before you rely on it. If docs or real behaviour contradict this
spec, follow reality, update the spec, and call out the change in your PR summary.
Raise anything under **Open Questions** with me before building that part, unless it has
a stated default, in which case build the default and flag it.

References:
- Obsidian URI: https://help.obsidian.md/uri
- Bear x-callback-url: https://bear.app/faq/x-callback-url-scheme-documentation/

## Summary
Add two built-in export destinations, **Obsidian** and **Bear**, as small icon buttons
next to the existing Copy button. Clicking one sends the meeting note's markdown (from our
existing markdown exporter) to that app via its URL scheme, with the content in the URL.
Each meeting note keeps a list of where it was exported. Clicking again opens the existing
note instead of creating a duplicate, or asks what to do if the content has changed since
that export.

## Fixed decisions
1. Both destinations are built in. There is no plugin system.
2. Both use URL schemes only. Do not write into Obsidian vaults or read or write Bear's database.
3. Content goes in the URL (`content=` for Obsidian, `text=` for Bear), not via clipboard.
4. Size fallback: if a built export URL exceeds **500 KB** (500 × 1024 bytes of the final
   percent-encoded URL string, UTF-8), do not open it. Instead:
   - put the markdown on `NSPasteboard.general`,
   - show an alert: "This note is too large to send to <App> directly. It's been copied
     to your clipboard. Paste it into a new note in <App>."
5. Detection is URL-scheme based. Show a destination's button only if its app is installed.
6. Tags: always `biscotti`, plus every tag the meeting has in Biscotti.
7. Meeting notes carry an `exports` list (data model below). Its records drive open-versus-export behaviour.
8. UX: small icon buttons placed beside the existing Copy button, always visible when the
   app is installed. There is no setting to show or hide them, and they must not be visually heavy.

## Data model
Add an `exports` list to the meeting note model. Adapt names and persistence to whatever
Biscotti already uses (SwiftData, Core Data, JSON, etc.), and include a migration that
defaults existing meetings to an empty list.

~~~swift
enum ExportDestination: String, Codable {
    case bear            // locator = Bear note unique identifier
    case obsidianURL = "obsidian-url"  // locator = obsidian://open?... URI from x-success
    case file            // FUTURE, not built now. locator = absolute file path
}

struct ExportRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var destination: ExportDestination
    var locator: String          // see enum comments
    var auxPath: String?         // obsidian: file:// URL from x-success (desktop only), informational
    var contentHash: String      // SHA-256 hex of the canonical export payload (see Hashing)
    var exportedAt: Date
    var updatedAt: Date?         // set when "Export Again" updates in place
}

// On the meeting note:
var exports: [ExportRecord]
~~~

Rules:
- Keep at most one record per destination per meeting note. The newest record wins and replaces the old one.
- `file` exists in the enum for future use only. Build no UI or behaviour for it.

## Hashing
- Hash the **canonical export payload**, meaning exactly what we'd send minus URL encoding:
  title + markdown body + sorted, normalized tag list (+ Obsidian target path).
  Use SHA-256 and store it as lowercase hex.
- The payload must be **deterministic**. Nothing time-varying may appear in the exported
  markdown, such as an "exported at" timestamp, a relative time like "2 hours ago", or
  random IDs, or every click will read as "changed". Audit the existing markdown exporter
  for this. The meeting's own start time is fine because it's fixed.
- Normalize line endings to `\n` before hashing.

## Click behaviour (state machine)
Compute the current payload and hash at click time, then look up the destination's record.

1. **No record → Create.**
   - Build the create URL (per-destination sections below).
   - If it is over 500 KB, use the clipboard fallback and stop. Record nothing (see Open Questions).
   - Otherwise open it with `x-success` and `x-error` callbacks.
   - On success, insert a record with the locator from the callback and the hash.
2. **Record exists, hash matches → Open** the existing note (per-destination).
3. **Record exists, hash differs → Alert.**
   - Title: "Already exported to <App>"
   - Message: "This meeting note has changed since it was exported."
   - Buttons: **Open** (default), **Export Again**, **Cancel**.
   - **Export Again** = update the existing note in place by default (see Open Questions).
     On success, update the record's `contentHash` and `updatedAt`.
4. **Open fails because the note no longer exists:**
   - Remove the record.
   - Show an alert: "Couldn't find this note in <App>. It may have been deleted. Export again?" with **Export** and **Cancel**.

- While a request is pending for a meeting and destination, disable that button to prevent
  double clicks.
- If no callback arrives within ~60 s, drop the pending request and log it. The next click
  may then create a duplicate. This is acceptable.

## Callbacks (x-success / x-error)
- Register a URL scheme for Biscotti in Info.plist (`CFBundleURLTypes`). If Biscotti already
  has one, reuse it.
- Handle incoming URLs via `application(_:open:)` or SwiftUI `onOpenURL`.
- Callback URLs:
  - `biscotti://x-callback/export/success?req=<uuid>`
  - `biscotti://x-callback/export/error?req=<uuid>`
- Keep an in-memory table of pending requests:
  `req → (meetingID, destination, action: create|open|update, contentHash, startedAt)`.
- Ignore any callback with an unknown or expired `req`. Treat incoming callback params as
  untrusted input.
- **VALIDATE:** both apps append their result params to an `x-success` URL that already
  contains a query string, per the x-callback-url convention. If either doesn't, encode
  `req` in the path instead (`.../success/<uuid>`).

## URL encoding (both apps)
- Percent-encode every query value yourself with a strict allowed set: unreserved
  characters only (`A–Z a–z 0–9 - . _ ~`). Encode spaces as `%20`, never `+`.
- Don't rely on `URLQueryItem` defaults. They leave `+`, `/`, `?` and others unencoded, and
  Obsidian's docs explicitly require `/` to be encoded as `%2F`.
- Open URLs with `NSWorkspace.shared.open(_:)`, not by shelling out to `open`.
- Apply the 500 KB check to the final URL string. Long transcripts are the most likely way
  to hit it.

## Detection
- `NSWorkspace.shared.urlForApplication(toOpen: URL(string: "obsidian://")!)`, and the
  same for `bear://`. A nil result means not installed, so hide that button.
- Cache the result in memory. Refresh at launch and on `NSApplication.didBecomeActiveNotification`.
  Don't persist the cache.
- Known quirk: Obsidian registers its scheme only after first launch, so a never-opened
  install reads as not installed. This is acceptable.
- If an app is uninstalled, hide its button but keep existing export records.

## Bear
Documented actions used: `/create`, `/open-note`, `/add-text`.

**Create**
~~~
bear://x-callback-url/create
  ?text=<markdown, first line "# <meeting title>">
  &tags=biscotti,<tag1>,<tag2>
  &open_note=yes
  &x-success=<encoded success URL>
  &x-error=<encoded error URL>
~~~
- Put the title as an H1 on the first line of `text` and don't pass `title=`. That way
  create and update use the identical payload.
  **VALIDATE:** Bear derives the note title from the H1 and doesn't duplicate it.
- `x-success` returns `identifier` and `title`. Store `identifier` as the locator.
- Bear rejects empty notes, so guard against an empty body before calling.

**Open**
~~~
bear://x-callback-url/open-note?id=<locator>&exclude_trashed=yes
  &x-success=...&x-error=...
~~~
- `x-error` means not found, so follow state-machine step 4.
- **VALIDATE:** whether archived notes open (they should) and what happens with locked or encrypted notes.

**Update (Export Again)**
~~~
bear://x-callback-url/add-text?id=<locator>&mode=replace_all&text=<markdown>
  &tags=biscotti,...&open_note=yes&x-success=...&x-error=...
~~~
- **VALIDATE:** `replace_all` combined with `tags` produces the correct final tag set with
  no duplicate tag lines. If not, append tags inline as hashtags in the text instead.

**Tags**
- Bear tags are inline hashtags. **VALIDATE** how tags containing spaces or special
  characters behave via the `tags=` param.
- Sanitization rule: trim, collapse whitespace, and replace spaces with `-`, unless
  validation shows Bear handles spaces correctly.
- Dedupe case-insensitively.

## Obsidian
Documented actions used: `new`, `open` (via the `url` returned from x-success).

**Create**
~~~
obsidian://new
  ?file=<vault-relative path, e.g. Biscotti%2F2026-10-21%20Weekly%20Sync>
  &content=<markdown with YAML frontmatter>
  &x-success=<encoded success URL>
~~~
- Omit `vault`, so Obsidian uses its current or last-focused vault.
  **VALIDATE** this behaviour for `new`; the docs state it only for some actions.
- `x-success` returns `name`, `url` (an `obsidian://open` URI) and, on desktop, `file`
  (a `file://` URL).
  - Store `url` as the locator; it encodes the vault and path.
  - Store `file` in `auxPath`.
- **VALIDATE:** what `new` does if the file already exists and no flags are passed. I
  expect it to create a numbered duplicate. The state machine avoids that case anyway.
- **VALIDATE:** whether `new` auto-creates missing intermediate folders.
- Obsidian docs don't document `x-error` for `new`. Pass it anyway, but don't depend on it.

**Frontmatter**
~~~yaml
---
tags: [biscotti, tag1, tag2]
biscotti_id: <meeting UUID>
date: 2026-10-21
# plus meeting metadata the markdown exporter already produces
# (e.g. start time, duration, attendees, calendar event); keep it deterministic
---
~~~
- Obsidian tag rules: no spaces, and allowed characters are letters, digits, `_`, `-`, `/`.
  A tag must not be purely numeric. Sanitize accordingly (spaces become `-`; strip other
  disallowed characters; prefix purely numeric tags, e.g. `t2026`). **VALIDATE** these rules.

**Filename**
- `YYYY-MM-DD <meeting title>`, stripped of characters Obsidian disallows: `* " \ / < > : | ? # ^ [ ]`.
- Trim the name to ~120 characters.
- Two meetings with the same title on the same day would collide on filename. Default:
  append the start time (`YYYY-MM-DD HHmm <title>`) when a collision with another
  Biscotti meeting is possible, or always. See Open Questions.

**Open**
- Open the stored `url` locator with NSWorkspace.
- No `x-error` is documented, so we can't reliably detect a missing note.
- **VALIDATE** what Obsidian does when that file was deleted or renamed (error notice?
  creates an empty note?) and report back. If it creates an empty note, flag it; we may
  need another approach.

**Update (Export Again)**
~~~
obsidian://new?path=<absolute path from auxPath>&overwrite&content=<markdown>&x-success=...
~~~
- The `path` param overrides `vault` and `file`.
- If `auxPath` is missing, fall back to the `file` param parsed from the locator URL.
- **VALIDATE:** `overwrite` replaces the file in place and doesn't duplicate it.

## UX
- **Placement:** a small icon button per installed destination, immediately to the right of
  the existing Copy button, with the same size, hit target and visual weight. No labels.
- **Icon:** the real app icon from `NSWorkspace.shared.icon(forFile: appURL.path)`, rendered
  at the Copy button's icon size. If that looks too loud next to an SF Symbol, use a
  desaturated or template treatment and flag it with screenshots.
- **Tooltip and accessibility label:**
  - No record: "Copy to Obsidian" / "Copy to Bear"
  - Record exists and matches: "Open in Obsidian" / "Open in Bear"
  - Record exists but stale: "Open in Bear (changed since export)"
- **State hint:** optional tiny dot or badge for "exported" and "stale" states, only if it
  stays subtle. Show both options in the PR (see Open Questions).
- **Keyboard:** add menu items under the meeting's existing share/export menu, if one
  exists, with the same actions. Don't add global shortcuts.
- **Errors:** use NSAlert only for the size fallback, stale content, and missing note. Fail
  everything else quietly and log it.

## Testing
Unit tests:
- percent-encoding (spaces, `/`, `+`, `&`, `#`, emoji, CJK, newlines)
- 500 KB threshold boundary (just under, exactly at, just over)
- payload canonicalization and hash determinism (same meeting produces the same hash across runs)
- tag sanitization for both apps
- filename sanitization and same-title, same-day collisions
- callback parsing, including unknown or expired `req` and malicious params
- state-machine decisions for all four branches

Manual test matrix, run against real Bear and Obsidian:
- create, then open, then edit in Biscotti, then the stale alert → Open, and → Export Again
- deleted in target app, then click
- Bear note trashed vs archived
- Obsidian with 2+ vaults
- Obsidian note renamed or moved
- Obsidian never launched (button hidden)
- long meeting with full transcript over 500 KB (clipboard fallback)
- meeting with no tags
- meeting with unicode-heavy title
- two meetings with the same title on the same day

## Open Questions
1. **Export Again semantics.** Default: update the existing note in place (Bear
   `replace_all`, Obsidian `overwrite`). This discards edits the user made in Bear or
   Obsidian. The alternative is to create a new note and repoint the record. Confirm.
2. **Obsidian destination.** Default: no `vault` param (current vault), folder `Biscotti/`,
   filename `YYYY-MM-DD <meeting title>`. Is a vault or folder setting needed in v1?
   Default: no setting.
3. **Filename collisions.** Default: always include start time (`YYYY-MM-DD HHmm <title>`)
   to avoid same-day, same-title collisions. Confirm, or prefer date-only with a suffix on collision.
4. **What content is exported.** Does the exported markdown include the full transcript or
   only summary and notes? Default: whatever the existing markdown exporter produces today.
5. **Clipboard fallback and records.** Default: don't record an export, since we get no ID
   or path. Confirm.
6. **Missing note in Obsidian.** We may not be able to detect it (see Open → VALIDATE).
   Report findings before choosing an approach.
7. **Stale indicator visuals.** Show the dot/badge vs tooltip-only options in the PR with screenshots.
8. **Sandbox and existing URL scheme.** Is Biscotti sandboxed, and does it already register
   a URL scheme? Check the project and report; this doesn't block the URL-only approach.
9. **Tag namespacing.** Default: flat (`biscotti`, `tag1`, `tag2`). The alternative is
   nested (`biscotti/tag1`). Confirm.
10. **Hash scope.** Default: include the title, body, tags and Obsidian path. Changing any
    of these marks the meeting stale. Confirm.

---

# Addendum (2026-10-21): change requests

## No state dot
Do not build the "state dot" / badge state hint (Open Question 7). Tooltip only.

## Add Apple Notes as a third export destination

### Context
We already have an export feature for meeting notes with Obsidian and Bear destinations,
built from the existing spec in this repo. Read that spec and the current implementation
first. This task adds **Apple Notes** as a third destination. It uses a different transport
(temp file handed to Notes) and has weaker capabilities: no note ID and no way to open a
specific note. Update the spec document as part of this work.

Some details below are unverified. Items marked **VALIDATE** must be tested on real
machines (macOS 26+ and at least one older supported version). If reality differs from
this prompt, follow reality and call it out in your PR summary. Ask me before deviating
from the decisions below.

### Decisions
1. **Transport: temp file + open with Notes.**
   - Render the meeting's markdown (existing exporter), write it to a `.md` file in a temp
     location, and open it with Notes. Notes imports the file and copies the content into
     its own store, so the file is only a carrier.
   - Do **not** use AppleScript/Apple Events, the share sheet, or the clipboard.

     ~~~swift
     let notes = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes")
     let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
     NSWorkspace.shared.open([mdURL], withApplicationAt: notes!, configuration: cfg) { app, error in … }
     ~~~
2. **Availability: all supported macOS versions.**
   - Show the button whenever Notes resolves by bundle ID. Use the same `.md` handoff
     everywhere.
   - On macOS 26+ Notes converts the markdown to rich text. On older versions it imports
     the file as plain text with the markdown syntax visible. That's acceptable; don't add
     an alternate path or a warning.
3. **Generalize the destination abstraction.** Don't special-case Notes inside the Bear
   and Obsidian code paths. Introduce or extend a per-destination capability model,
   roughly:
   - `transport`: `.urlScheme` | `.fileHandoff`
   - `supportsLocator` (returns an ID or path we can reopen)
   - `supportsOpenExisting`
   - `supportsUpdateInPlace`
   - `maxURLBytes`: only relevant for `.urlScheme`; the 500 KB clipboard fallback does not
     apply to Notes

   Bear and Obsidian behaviour must not change. Refactor with tests proving that.
4. **Data model.**
   - Add destination `apple-notes` to the existing enum.
   - Its records have a `nil` locator (make `locator` optional if it isn't already, with a
     migration if needed) and store `contentHash` and `exportedAt` as usual.
   - Write the record when the file is successfully handed to Notes (the completion
     handler reports no error). We cannot detect whether the user then cancelled Notes'
     import confirmation. Accept that and don't try to work around it.
5. **Repeat-click behaviour for Notes** (replaces the open/stale logic for this destination):
   - No record: export.
   - Record exists: always show an alert, because we can't open the specific note.
     - Title: "Already exported to Apple Notes"
     - Message, if the hash matches: "This meeting note was already exported to Notes."
     - Message, if the hash differs: "This meeting note was already exported to Notes and
       has changed since."
     - Buttons:
       - **Open Notes** (default): just activates the Notes app.
       - **Export Again**: creates a new note, since there's no in-place update, and
         replaces the record.
       - **Cancel**.
6. **UX.**
   - Same small icon-button treatment as Bear and Obsidian, next to Copy, using the Notes
     app icon from NSWorkspace.
   - Tooltips: "Copy to Apple Notes" when there's no record, "Exported to Apple Notes"
     when one exists.

### Implementation details
- **Temp file:**
  - Write to a unique subfolder per export (e.g. `tmp/biscotti-export/<uuid>/`) so the
    filename can be the meeting title without collisions.
  - Sanitize the filename (`/ : \ * ? " < > |`, trim to ~120 characters).
  - Delete old export folders lazily, either those older than ~10 minutes on the next
    export or at app launch. Never delete synchronously after `open`, because Notes reads
    the file asynchronously.
- **Content adjustments for Notes:**
  - Strip YAML frontmatter, since Notes would show it as plain text.
  - Ensure the meeting title is the first-line H1.
  - **VALIDATE** whether Notes titles the note from the H1 or the filename; make them match either way.
- **Tags:** our rule is `biscotti` plus the meeting's tags.
  - **VALIDATE** whether inline `#tag` text in imported markdown becomes real Notes tags
    (macOS 26+).
  - If it does and looks clean (e.g. one footer line of tags), include it.
  - If not, omit tags for Notes and tell me.
- **Hash:** reuse the existing canonical-payload hash, computed on the Notes-adjusted payload.

### VALIDATE and report (with screenshots where useful)
1. Opening a `.md` file via `NSWorkspace.open(_:withApplicationAt:)` triggers import, the
   same as File › Import. Check this from a **sandboxed** build if we're sandboxed; Notes
   must be able to read the file from our container's temp directory.
2. Whether the "Import to Notes?" confirmation appears every time, and what happens if
   the user cancels it.
3. Where the note lands ("Imported Notes" folder for iCloud accounts, per Apple's docs).
4. Fidelity on real meeting notes (macOS 26+): headings, bullets, bold and italic, links,
   plus anything our exporter emits that may be unsupported, such as tables, checklists
   or action items, code blocks, and long transcripts.
   - If an element renders badly, propose a Notes-specific pre-transform (e.g. tables to
     lists) rather than changing the shared exporter.
5. Behaviour on macOS 26 and 27 (rich text) vs macOS 15 (plain text): confirm the import
   succeeds on all of them.

### Also check
- Our deployment target: make sure the feature works on every macOS version we support,
  with no availability gating for Notes.
- Any shared menu (share/export) gets an "Export to Apple Notes" item with the same logic.
- Accessibility labels for the new button and alert.

### Tests
- Unit tests:
  - capability model, ensuring Bear and Obsidian paths are unchanged
  - Notes state machine (no record; record with matching hash; record with changed hash)
  - temp-file naming and sanitization
  - frontmatter stripping
  - temp cleanup selection
- Manual tests:
  - first export
  - repeat click with unchanged content, then each of Open Notes, Export Again and Cancel
  - repeat click after editing the meeting
  - cancel the Notes import dialog, confirm a record was still written, and confirm the
    next click shows the alert
  - macOS < 26: export works and imports as plain text

### Icon
Apple Notes outline icon (user-supplied): `apple-notes-outline.svg`.

### Deliverables
- The implementation, the updated spec document (with a new Apple Notes section and the
  generalized destination model), tests, and a PR summary listing every VALIDATE finding
  and any deviations.

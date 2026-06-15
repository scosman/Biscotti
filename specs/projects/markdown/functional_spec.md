---
status: complete
---

# Functional Spec: Markdown

## Summary

Introduce a reusable, Biscotti-styled **live markdown editor** control, backed by
[swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine), and use it for the
**meeting notes** section. The editor renders markdown inline as the user types (bold, italic,
headings, lists, etc.) while keeping the raw markdown markers **visible but dimmed**. Notes continue
to persist as the same plain-text (`Meeting.notes: String`) markdown source — no data migration.

The control is built as a thin wrapper so the rest of the app consumes a Biscotti-flavored editor
(our fonts, colors, spacing, feature set, defaults) rather than the raw third-party view, making
markdown a first-class building block we can reuse on other surfaces later.

## In Scope

1. **Adopt the dependency**: add the `MarkdownEngine` SwiftPM product (the **core, zero-external-dependency** product). The `MarkdownEngineCodeBlocks` (syntax highlighting) and `MarkdownEngineLatex` products are **not** adopted.
2. **A Biscotti wrapper control** — a SwiftUI view that wraps `NativeTextViewWrapper` and applies our theme, font, marker style, feature set, and sensible defaults. Lives in a new module (see architecture).
3. **A theme/config factory** that maps Biscotti's F Sage design tokens onto the engine's `MarkdownEditorConfiguration` / `MarkdownEditorTheme`.
4. **Integrate into meeting notes**: replace the plain `TextEditor` in `MeetingDetailView`'s notes section with the wrapper, preserving the existing debounced autosave + flush-on-disappear.

## Out of Scope (this project)

- Syntax-highlighted code blocks (no `MarkdownEngineCodeBlocks` / HighlighterSwift dependency). Fenced/inline code still renders monospaced; it just isn't colorized.
- LaTeX math (no `MarkdownEngineLatex` / SwiftMath dependency).
- Wiki-links (`[[Name]]`) and embedded images (`![[Name]]`): no resolver/provider services are supplied, so these are not first-class features here. (The syntax may appear inert/plain; we don't build a note-linking or image-embed system.)
- Image paste (no `onPasteImage` handler — paste falls through to plain text).
- Applying the editor to other surfaces (transcript, summaries, settings). The wrapper is *designed* to be reusable, but the only consumer in this project is meeting notes.
- Any change to how notes are stored, searched, or synced. Notes remain a plain markdown `String`, indexed by the existing search.
- A markdown manual-test tab in `ManualTestApp` (out of scope; visual checks are done ad hoc — see Testing).

## The Wrapper Control

### Purpose & shape

A SwiftUI view (working name `MarkdownEditor`) exposing a small, Biscotti-shaped API. At minimum it
takes a two-way `text` binding (the markdown source string). It internally constructs the Biscotti
configuration and renders the engine's `NativeTextViewWrapper`. Callers don't see the engine's
configuration object or its many optional callbacks.

Expected surface (final names decided in architecture):

- `text: Binding<String>` — the markdown source (required).
- `documentId: String` — stable per-document identity so undo history / per-document editor state stay scoped to one document. For notes this is the meeting's id. (Maps to the engine's `documentId`.)
- `placeholder: String` — ghost text shown while empty (e.g. "Add notes…"). The wrapper converts it to a styled `NSAttributedString`.
- `isEditable: Bool` — default `true`. A `false` value yields a live-rendered, read-only view (enables future read-only reuse; not used by notes).

The wrapper does **not** expose the engine's wiki-link / code-block / caret callbacks; they are unused.

### Marker rendering (the headline behavior)

**Always-visible, dimmed markers.** Markdown markers (`*`, `**`, `~~`, `#`, list bullets, `>` etc.)
remain on screen at all times, drawn in a **lighter/dimmer color than body text**, while the spans
they delimit render styled (italic, bold, strikethrough, heading size, …).

Mechanism (validated against the engine source):
- The engine keeps markers in the text storage and, when the caret is *outside* a token, shrinks them to `MarkerStyle.hiddenMarkerFontSize` (default `0.1` ≈ invisible). Setting `hiddenMarkerFontSize` to the **body font size** keeps markers at full, readable size at all times (no shrink/grow as the caret moves).
- Markers are colored via the theme: most inline markers use `MarkdownEditorTheme.mutedText`; heading markers use `headingMarker`. We map both onto a **dimmed ink** from the F Sage palette so markers read as clearly secondary to body text.
- Net effect matches the chosen design: `*italic*` shows a dimmed `*…*` with the inner word italicized; `## Agenda` shows a dimmed `##` with the heading enlarged.

Exact dimming level (e.g. `inkSecondary` vs `inkTertiary`) and whether markers are body-size or slightly smaller is a **visual-tuning** decision finalized during implementation against a real render (see Testing). The functional contract is: *markers always visible, clearly dimmer than body text, spans fully styled.*

### Supported markdown features

**Always on (core engine):** bold, italic, strikethrough, headings (H1–H6), ordered/unordered lists
(with auto-continue, auto-indent via Tab, marker conversion), blockquotes, inline code, fenced code
(monospaced, not colorized), links, horizontal rules.

**Enabled:**
- **Task checkboxes** — `- [ ]` / `- [x]`, clickable to toggle. Good for meeting action items.
- **GFM tables** — pipe tables.

**Not enabled:** syntax-highlighted code blocks, LaTeX, wiki-links, image embeds (see Out of Scope).

### Inherited editing behaviors

From the engine, kept at sensible defaults:
- **Undo/redo**, scoped per `documentId`.
- **Spell check / grammar / autocorrect** — on by default (notes are prose). We do **not** persist the user's per-editor spell toggles in this project (the `onSpellCheckingPolicyChanged` hook is unused); toggles reset to defaults when the editor is recreated. (Acceptable; persisting is a future nicety.)
- **In-document find**, list helpers, auto-close of bracket pairs `() [] {}`.
- **Paste** falls through to the system's plain-text paste (no image-embed interception).

### Styling (F Sage)

The editor uses Biscotti's design tokens, not stock system colors:

| Engine knob | Biscotti mapping (intent) |
|---|---|
| `theme.bodyText` (body + caret) | `ink` |
| `theme.mutedText` (inline markers, de-emphasis) | dimmed ink (`inkSecondary`/`inkTertiary` — tuned) |
| `theme.headingMarker` (`#` glyphs) | dimmed ink |
| `theme.link` | `sage` |
| `theme.findMatchHighlight` / `findCurrentMatchHighlight` | F Sage accent wash / a brand highlight |
| `theme.strikethroughColor` | `ink` |
| base font (`fontName` / `fontSize`) | app body font + notes body size |
| `headings.fontMultipliers` | engine defaults (tunable) so H1–H3 read as clear hierarchy |
| `markers.hiddenMarkerFontSize` | = body size (always-visible markers) |
| editor background | clear (sits on the meeting-detail `paper` background) |

The control should look like it belongs in the app: warm ivory background showing through, ink body
text, sage links, dimmed-ink markers. Precise values come from `DesignSystem` at implementation time.

## Notes Integration

- **Location**: the `notesSection` of `MeetingDetailView` (currently `MeetingDetailView.swift:281–297`). Replace the inline `TextEditor` with the wrapper. Keep the "Notes" section header.
- **Binding & autosave**: the wrapper binds to the same `viewModel.notes` via `updateNotes(_:)`; the existing 1-second debounced autosave and `flushNotes()` on `onDisappear` are preserved unchanged.
- **Document identity**: pass the meeting id as `documentId` so undo and editor state are per-meeting. (The detail view is already keyed by meeting id, so switching meetings recreates the editor.)
- **Placeholder**: "Add notes…" (styled, dimmed).
- **Layout — bounded inline box**: the editor is given a **min/max height** and scrolls internally when notes exceed it; it sits inside the existing page `ScrollView` like the current `TextEditor`. The engine's own vertical scroller (autohide) handles overflow. Concrete dimensions and overscroll tuning are set in UI design / implementation. (Auto-grow-to-content and a dedicated notes pane were considered and deferred — see UI design.)

## Edge Cases

- **Empty notes**: placeholder shown; first keystroke hides it. Saved value is `""` (unchanged from today).
- **Existing plain-text notes**: render as a normal paragraph (plain text is valid markdown). No migration, no surprise reformatting of already-saved notes.
- **Very long notes**: the bounded editor scrolls internally; autosave still debounced. (Nested scrolling inside the page scroll is accepted and bounded.)
- **Switching meetings mid-edit**: `onDisappear` flushes notes before the editor is torn down; the new meeting gets a fresh editor (new `documentId`, fresh undo).
- **Pasting rich text** (e.g. from a webpage): inserted as plain text (the markdown source), consistent with a markdown editor.
- **Markdown that uses unsupported syntax** (e.g. `[[wiki]]`, `$math$`): rendered inertly as plain/near-plain text, never crashes; round-trips losslessly because it's stored verbatim as the source string.
- **Read-only state**: not used by notes, but `isEditable: false` must produce a caret-less, non-editable live render (keeps the control honest for future reuse).

## Constraints

- **Platform**: macOS 15+ (engine requires 14+; fine). Apple silicon only.
- **Swift 6 strict concurrency**: the project builds under Swift 6 strict concurrency (Xcode 26.3 in CI). The engine is `Sendable`-annotated; compiling it cleanly in our toolchain is the **primary first-phase risk** and is de-risked first (see implementation plan).
- **Dependency footprint**: only `MarkdownEngine` (zero transitive external deps). No HighlighterSwift, no SwiftMath.
- **Versioning**: the engine is **pre-1.0** (~0.7.x). Pin an exact version (`.exact` or a tight range); revisit on upgrade since the public API may shift between minor versions.
- **License**: Apache-2.0 (compatible). Record it where third-party licenses are tracked.
- **AppKit bridge**: the engine is an `NSViewRepresentable` over an `NSScrollView`/`NSTextView` (TextKit 2). It is macOS-native — no iOS concerns.

## Testing

- **Unit-testable**: the theme/config factory — assert it maps F Sage tokens to the expected `MarkdownEditorConfiguration`/`MarkdownEditorTheme` values (body color = ink, marker font size = body size, features enabled, etc.) and that any pure helpers (e.g. placeholder `NSAttributedString` construction) behave. These run under `swift test`.
- **Build/compile gate**: the new module compiles under our Swift 6 toolchain (the main automated signal that the dependency integrates).
- **Visual / interaction verification is manual** (a live AppKit editor's rendering can't be meaningfully unit-tested): confirm on a real run that markers are dimmed-but-visible, spans style correctly, checkboxes toggle, tables render, autosave persists, and the bounded box scrolls. Done via the app (and SwiftUI previews); not added to the `ManualTestApp` gate in this project.

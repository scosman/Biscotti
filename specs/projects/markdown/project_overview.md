---
status: complete
---

# Markdown

Adopt **markdown as a first-class citizen** in the Biscotti app.

## Goals

- **Adopt the [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) project.** It's a native macOS markdown editor (AppKit/TextKit 2, bridged to SwiftUI) that lets you type and see markdown rendered live as you type.
  - **Explore its config options during speccing.** Style: **use ours** (F Sage design tokens — fonts, colors, spacing).
  - When we have the choice, **render the exact text AND the style.** Example: `*italic*` should preferably still render the markdown `*` characters (lighter than the core text — dimmed, not hidden), while rendering the span itself as italic.
- **Use it for the "notes" section of meetings.** The meeting notes field is currently a plain `TextEditor` storing a plain `String`; this project upgrades it to a live markdown editor.
- **Make a wrapper control if appropriate** — our style, our config choices, our defaults — so the rest of the app consumes a Biscotti-flavored markdown editor rather than the raw third-party view.

## Context (from initial research)

- The library is a *live editor*, not a preview-only renderer: markdown syntax styles inline as you type (bold, italic, strikethrough, headings, lists, blockquotes, GFM tables, inline/fenced code, links, task checkboxes, horizontal rules), with optional wiki-links, embedded images, syntax-highlighted code blocks, and LaTeX.
- It's split into three SwiftPM products: `MarkdownEngine` (core, **zero external dependencies**), `MarkdownEngineCodeBlocks` (adds syntax highlighting), and `MarkdownEngineLatex` (adds LaTeX). We can adopt only what we need.
- Theming/config is first-class: `MarkdownEditorConfiguration` + `MarkdownEditorTheme` expose colors, fonts/sizing, marker visibility, lists, headings, links, spacing, scroll behavior, reading width, spell-checking, etc.
- Marker visibility is controlled by `MarkerStyle.hiddenMarkerFontSize` (default `0.1` = effectively hidden until the caret enters the token). Raising it keeps markers visible; markers are colored via the theme's `mutedText`, which makes our "dimmed but visible" preference achievable by config.
- macOS 14+ (we target 15+), Swift 5.9+, Apache-2.0 license, currently pre-1.0 (~0.7.x — pin a version).
- The notes field already exists end-to-end: `Meeting.notes: String` (SwiftData), debounced autosave in `MeetingDetailViewModel`, surfaced as a plain `TextEditor` in `MeetingDetailView`. Storing raw markdown in that same `String` needs no schema change.

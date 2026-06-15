---
status: complete
---

# Implementation Plan: Markdown

## Phases

- [x] **Phase 1 — Foundation: dependency + `MarkdownEditorUI` module.**
  Add the pinned `swift-markdown-engine` (core `MarkdownEngine` product) dependency; create the `MarkdownEditorUI` target/product/test-target; add the `NSColor` palette mirrors to `DesignSystem`; implement the `MarkdownEditor` wrapper view + the `MarkdownEditorConfiguration.biscotti(…)` factory (F Sage theme, always-visible dimmed markers, prose-friendly defaults); add a SwiftUI preview and `MarkdownEditorUITests` for the factory mapping. **De-risks the #1 risk (Swift 6 strict-concurrency compile) before any integration.** Gate: `build` + `lint` + `test` green.

- [ ] **Phase 2 — Integrate into meeting notes.**
  Add `MarkdownEditorUI` to `MeetingDetailUI`'s dependencies; replace the notes `TextEditor` with `MarkdownEditor` (bounded inline box, `documentId` = meeting id, "Add notes…" placeholder, subtle container affordance); preserve the existing debounced autosave + flush-on-disappear. Tune visuals (marker dimming, sizes, box height, overscroll) against previews/a real run. Record the Apache-2.0 attribution. Gate: `build` + `lint` + `test` green; app builds (`build-app`, non-gating); behavior verified on a run.

(Two phases keeps each CR a coherent sitting: a self-contained, testable control first; a focused integration second.)

---
status: complete
---

# Architecture: Markdown

## Overview

One new, dependency-light UI module wraps the third-party engine behind a Biscotti-shaped control;
`MeetingDetailUI` consumes it for the notes section. A small, single-sourced color/config mapping
ties the engine to F Sage tokens. No data-model, persistence, or view-model changes beyond pointing
the notes binding at the new control.

```
MeetingDetailUI ──► MarkdownEditorUI ──► MarkdownEngine (3rd-party, core product)
       │                   │
       └──► DataStore      └──► DesignSystem (tokens, incl. new NSColor mirrors)
```

## New module: `MarkdownEditorUI`

A new SwiftPM target + product in `Packages/BiscottiKit`.

- **Name**: `MarkdownEditorUI`. (The overview floated "MarkdownUI"; we avoid that exact name because the popular `swift-markdown-ui` package's product is literally `MarkdownUI` — a future-reader footgun even though we don't depend on it. Trivial to rename if you prefer `MarkdownUI`.)
- **Dependencies**: `DesignSystem` + `.product(name: "MarkdownEngine", package: "swift-markdown-engine")`. Nothing else — keeps the third-party dependency out of `DesignSystem` (which stays zero-dep) and out of every other module.
- **Consumers (this project)**: `MeetingDetailUI` only. Designed to be reusable by any future surface that wants a Biscotti markdown editor/render.
- **Test target**: `MarkdownEditorUITests`.

`Package.swift` changes:
- Add to `dependencies`: `.package(url: "https://github.com/nodes-app/swift-markdown-engine", exact: "<pinned 0.x.y>")`. Pin **exact** (pre-1.0; API may shift between minors). Confirm the latest stable tag at implementation time.
- Add `.library(name: "MarkdownEditorUI", targets: ["MarkdownEditorUI"])` to `products`.
- Add the `MarkdownEditorUI` target (deps: `DesignSystem`, `MarkdownEngine`) and `MarkdownEditorUITests` test target, both with the standard `warningsAsErrors` setting.
- Add `"MarkdownEditorUI"` to `MeetingDetailUI`'s dependency list (target + its test target as needed).

## Public API (the wrapper)

A thin SwiftUI view plus a pure configuration factory. Callers never see the engine's config object or
its many optional callbacks.

```swift
public struct MarkdownEditor: View {
    public init(
        text: Binding<String>,        // markdown source (the stored string)
        documentId: String,           // stable per-document id → scopes undo/editor state
        placeholder: String = "",     // ghost text while empty
        isEditable: Bool = true       // false → live-rendered, caret-less read-only
    )
}
```

Internally it renders `NativeTextViewWrapper(text:configuration:fontName:fontSize:documentId:placeholder:isEditable:)`
with:
- `configuration` = the Biscotti config (below).
- `fontName` / `fontSize` = the app body font + notes size (a constant in this module; `NSFont(name:)` falls back to `systemFont` if the name doesn't resolve — derive from `NSFont.systemFont(ofSize:).fontName` to be safe).
- `placeholder` converted from `String` → styled `NSAttributedString` (dimmed ink, base font).
- Unused engine bindings/callbacks left at their defaults (no wiki-link/code-block/caret wiring).

### Configuration factory

A pure, `Sendable`, **unit-testable** function builds the engine configuration from F Sage tokens —
the single place engine knobs are set:

```swift
public extension MarkdownEditorConfiguration {
    static func biscotti() -> MarkdownEditorConfiguration
}
```

Mapping (engine knob → Biscotti intent):

| Engine field | Value |
|---|---|
| `theme.bodyText` | `NSColor` ink (also the caret) |
| `theme.mutedText` | `NSColor` inkSecondary — **inline markers** + de-emphasis |
| `theme.headingMarker` | `NSColor` inkSecondary — `#` glyphs |
| `theme.disabledText` | `NSColor` inkTertiary |
| `theme.link` | `NSColor` sage |
| `theme.findMatchHighlight` | `NSColor` from `accentWashStrong` |
| `theme.findCurrentMatchHighlight` | stronger sage |
| `theme.strikethroughColor` | `NSColor` inkSecondary |
| `markers.hiddenMarkerFontSize` | engine default (0.1pt) — hide-on-blur; always-visible was attempted but the engine's `shrinkInactiveMarkers` applies a negative kern that collapses layout advance, causing text overlap at full font size |
| `overscroll` | reduced for a bounded box (e.g. `percent: 0`, small `maxPoints`/`minPoints`) |
| `scrollers` | `.default` (vertical, autohide) |
| `lists.helpersEnabled` | `true` (auto-continue/indent) |
| `lists.autoClosePairsEnabled` | `false` (prose-friendly) |
| `headings.fontMultipliers` | engine defaults (`[2.0, 1.5, 1.17, …]`) |
| `textInsets` | small inner padding (~8pt) |
| `readingWidth` | `nil` (fill the box) |
| `spellChecking` | `.default` (on) |
| `services` | `.default` (no-op: no wiki-link resolver, image provider, syntax highlighter, or LaTeX renderer) |

Notes on feature gating:
- **Task checkboxes and GFM tables need no flag** — they're inherent to the core engine; we simply keep them and style them.
- **Code-block syntax highlighting and LaTeX are excluded by not linking** the `MarkdownEngineCodeBlocks` / `MarkdownEngineLatex` products and by leaving their services no-op.
- **Wiki-links / image embeds are excluded** by leaving `services` at `.default` (no resolver/provider).

## DesignSystem change: NSColor mirrors

The engine theme requires `NSColor`; the F Sage palette is SwiftUI `Color`. To keep the palette
**single-sourced** and avoid per-call `NSColor(Color:)` conversions (which can land in unexpected
color spaces), add an `NSColor` mirror of the palette to `DesignSystem` (`Color+Theme.swift` or a
sibling), built from the same RGB/alpha literals — e.g. `NSColor.ink`, `.inkSecondary`, `.sage`,
`.accentWashStrong`, etc. This is a small, additive change; `DesignSystem` is already macOS-only and
imports SwiftUI/AppKit. `MarkdownEditorUI` consumes these mirrors.

(Acceptable fallback if we choose not to touch DesignSystem: convert locally via `NSColor(Color.x)`
inside `MarkdownEditorUI`. Preference is the single-sourced mirror.)

## `MeetingDetailUI` integration

Replace the `notesSection`'s `TextEditor` (`MeetingDetailView.swift:281–297`) with:

```swift
MarkdownEditor(
    text: Binding(get: { viewModel.notes }, set: { viewModel.updateNotes($0) }),
    documentId: viewModel.meetingID.uuidString,   // per-meeting undo/state
    placeholder: "Add notes…"
)
.frame(minHeight: 120, maxHeight: 340)            // bounded box (tuned)
.overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardStroke)) // subtle affordance
```

- **No view-model change**: `notes`, `updateNotes(_:)` (1s debounce), and `flushNotes()` on `onDisappear` are untouched. The control is a drop-in for the binding.
- `viewModel.meetingID` already exists (the view model is constructed with a meeting id) and supplies `documentId`.

## Concurrency & build

- `MarkdownEditor` is a SwiftUI `View` (main-actor). `NativeTextViewWrapper` is an `NSViewRepresentable` (main-actor). The config factory is pure and returns the engine's `Sendable` `MarkdownEditorConfiguration`. No new concurrency surface.
- **Primary risk**: the engine compiling cleanly under our **Swift 6 strict-concurrency + warnings-as-errors** package settings (`swift-tools-version 6.1`, `swiftLanguageModes: [.v6]`, Xcode 26.3 in CI). The engine is `Sendable`-annotated, but third-party code can still trip our strict bar. **De-risked in Phase 1** by adding the dependency and getting a trivial instance to build before any integration work. If the engine itself emits warnings under `-warnings-as-errors`, that's a dependency-build concern (dependencies aren't held to our flags — only first-party targets are), so the risk is concentrated in *our* wrapper code, not theirs.

## Testing

- **`MarkdownEditorUITests`** (runs under `swift test`):
  - `MarkdownEditorConfiguration.biscotti()` maps tokens correctly: `bodyText == NSColor.ink`, `mutedText == NSColor.inkSecondary`, `link == NSColor.sage`, `markers.hiddenMarkerFontSize == engine default (0.1pt)`, `lists.autoClosePairsEnabled == false`, `services` are the no-op defaults, etc.
  - Any pure helper (placeholder `NSAttributedString` construction) behaves.
- **`DesignSystemTests`**: optionally assert the new `NSColor` mirrors equal the `Color` palette values.
- **Build gate**: `MarkdownEditorUI` + `MeetingDetailUI` compile under the Swift 6 toolchain (the main signal the dependency integrates) via `mcp__hooks-mcp__build` / CI `make ci`.
- **Visual/interaction**: manual (a live AppKit editor can't be meaningfully unit-tested) — verified via SwiftUI previews in `MarkdownEditorUI` and a real app run. Not added to the `ManualTestApp` gate.

## Files touched (anticipated)

- `Packages/BiscottiKit/Package.swift` — dependency + product + targets.
- `Packages/BiscottiKit/Sources/MarkdownEditorUI/MarkdownEditor.swift` — the wrapper view (new).
- `Packages/BiscottiKit/Sources/MarkdownEditorUI/MarkdownEditorConfiguration+Biscotti.swift` — config factory + font constant (new).
- `Packages/BiscottiKit/Sources/DesignSystem/Color+Theme.swift` (or sibling) — NSColor mirrors.
- `Packages/BiscottiKit/Sources/MeetingDetailUI/MeetingDetailView.swift` — swap notes editor.
- `Packages/BiscottiKit/Tests/MarkdownEditorUITests/…` — config-factory tests (new).
- License/attribution tracking for Apache-2.0 (wherever third-party licenses are recorded).

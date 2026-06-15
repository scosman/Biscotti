---
status: complete
---

# Phase 1: Foundation -- dependency + `MarkdownEditorUI` module

> **Post-hoc note (Phase 2):** The `baseFontSize` parameter and
> `hiddenMarkerFontSize = baseFontSize` ("always-visible markers") described
> below were reverted in Phase 2. The engine's `shrinkInactiveMarkers`
> applies a negative kern that collapses layout advance, causing text overlap
> at full font size. The factory is now `biscotti()` (no parameter) and
> markers use the engine default hide-on-blur behavior.

## Overview

Add the pinned `swift-markdown-engine` dependency, create the `MarkdownEditorUI` module with its test target, add `NSColor` palette mirrors to `DesignSystem`, implement the `MarkdownEditor` wrapper view and the `MarkdownEditorConfiguration.biscotti(...)` factory, and write tests for the config factory. This phase de-risks the primary concern (Swift 6 strict-concurrency compile with a third-party dependency) before any integration work.

## Steps

1. **Add `swift-markdown-engine` dependency to `Package.swift`**
   - `.package(url: "https://github.com/nodes-app/swift-markdown-engine", exact: "0.7.0")` in the top-level `dependencies` array.
   - Add `.library(name: "MarkdownEditorUI", targets: ["MarkdownEditorUI"])` to `products`.
   - Add the `MarkdownEditorUI` target with dependencies: `["DesignSystem", .product(name: "MarkdownEngine", package: "swift-markdown-engine")]` and `warningsAsErrors`.
   - Add `MarkdownEditorUITests` test target depending on `"MarkdownEditorUI"` with `warningsAsErrors`.

2. **Add `NSColor` mirrors to `DesignSystem/Color+Theme.swift`**
   - Add a `public extension NSColor` block with static properties mirroring the SwiftUI palette: `ink`, `inkSecondary`, `inkTertiary`, `sage`, `accentWashStrong`, `cardStroke`. Built from the same RGB/alpha literals as the `Color` versions.

3. **Create `MarkdownEditorConfiguration+Biscotti.swift`**
   - `public extension MarkdownEditorConfiguration { static func biscotti(baseFontSize: CGFloat) -> MarkdownEditorConfiguration }`.
   - Maps F Sage tokens: `theme.bodyText = .ink`, `theme.mutedText = .inkSecondary`, `theme.headingMarker = .inkSecondary`, `theme.disabledText = .inkTertiary`, `theme.link = .sage`, `theme.findMatchHighlight = .accentWashStrong`, `theme.findCurrentMatchHighlight` = stronger sage, `theme.strikethroughColor = .inkSecondary`.
   - `markers.hiddenMarkerFontSize = baseFontSize` (always-visible markers).
   - `lists.helpersEnabled = true`, `lists.autoClosePairsEnabled = false` (prose-friendly).
   - `overscroll` reduced for bounded box (`percent: 0`, small `maxPoints`/`minPoints`).
   - `scrollers = .default` (vertical, autohide).
   - `textInsets = TextInsets(horizontal: 8, vertical: 8)`.
   - `readingWidth = nil`.
   - `spellChecking = .default` (on).
   - `services = .default` (no-op: no wiki-link, image, syntax, latex).

4. **Create `MarkdownEditor.swift` wrapper view**
   ```swift
   public struct MarkdownEditor: View {
       public init(
           text: Binding<String>,
           documentId: String,
           placeholder: String = "",
           isEditable: Bool = true
       )
   }
   ```
   - Internally renders `NativeTextViewWrapper` with the biscotti configuration.
   - Converts `placeholder` String to a styled `NSAttributedString` (dimmed ink, system body font).
   - Uses `NSFont.systemFont(ofSize:).fontName` for safe font name resolution.

5. **Add a SwiftUI `#Preview`** in `MarkdownEditor.swift` for visual verification.

6. **Write `MarkdownEditorUITests`**
   - Test the `biscotti(baseFontSize:)` factory: verify body text color, muted text color, heading marker color, link color, marker font size, list helper/autoclose settings, overscroll, text insets, services are default.
   - Test the placeholder `NSAttributedString` helper: correct string content, font, color.

## Tests

- `testBiscottiConfigurationThemeColors` -- bodyText == NSColor.ink, mutedText == NSColor.inkSecondary, headingMarker == NSColor.inkSecondary, link == NSColor.sage, disabledText == NSColor.inkTertiary.
- `testBiscottiConfigurationMarkers` -- hiddenMarkerFontSize == baseFontSize (always-visible).
- `testBiscottiConfigurationListOptions` -- helpersEnabled == true, autoClosePairsEnabled == false.
- `testBiscottiConfigurationOverscroll` -- percent == 0, small maxPoints/minPoints.
- `testBiscottiConfigurationTextInsets` -- horizontal == 8, vertical == 8.
- `testBiscottiConfigurationDefaults` -- readingWidth == nil, services == .default, spellChecking == .default.
- `testPlaceholderAttributedString` -- correct text, font, color attributes.

---
status: draft
---

# Phase 1: Adaptive Palette Foundation + Guarantee Tests

## Overview

Convert the static color palette into appearance-adaptive tokens so the app
renders correctly in both light and dark mode, using a single
`dynamicNSColor(light:dark:)` helper. Light-mode output is byte-identical to the
current code. Add new semantic tokens needed for Phase 2 repoints. No call-site
changes in this phase -- after it lands, every redefined token already renders its
dark value when the system appearance is dark.

## Steps

1. **Create `DesignSystem/DynamicColor.swift`** -- internal helper with two
   functions: `dynamicNSColor(light:dark:) -> NSColor` and
   `dynamicColor(light:dark:) -> Color`. The only appearance switch in the
   codebase.

2. **Rewrite `DesignSystem/Color+Theme.swift`** -- convert every token from a
   static literal to a `dynamicColor(light:dark:)` call:
   - Surfaces & ink: `paper`, `wall`, `sidebarTint`, `ink`, `inkSecondary`,
     `inkTertiary`, `hairline`, `neutralChip`, `cardStroke`.
   - Sage family: `sage`, `accentWashSoft`, `accentWashStrong`, `softSageFill`,
     `findHighlightFocused`.
   - Alert red: `signalRed`, `recordingOutline`. Keep derived tokens
     (`recordingTintSoft/Strong`, `recordingOutlineStrong`, `recordingHoverFill`)
     as `base.opacity(x)` where spec allows, else promote.
   - Amber: `warningOchre`, `warningChipText` (gets its own dark value).
   - New tokens: `accentFill`, `read`, `elevatedFill`, `accentTrack`,
     `signalRedText`, `cardShadow`, `controlShadow`, `cardFill`.
   - Unify `Color`/`NSColor` into single-source: `NSColor` tokens via
     `dynamicNSColor`, `Color` tokens as `Color(nsColor:)`.
   - Preserve `ShapeStyle` sugar, extend for new tokens.
   - Update doc comments on `signalRed`/`warningOchre` to note the dark text
     variants and adaptive behavior.

3. **Update `DesignSystem/Tokens.swift`**:
   - `cardFill = Color.white` -> `cardFill = Color.cardFill` (adaptive).
   - `warningChipText` stays as `Color.warningChipText` (now has own dark value).
   - Add aliases: `elevatedFill`, `accentFill`, `read`, `accentTrack`,
     `signalRedText`, `cardShadow`, `controlShadow`.
   - Avatar palette, typography, spacing, radii: untouched.

4. **Add `Tests/DesignSystemTests/DynamicColorTests.swift`**:
   - Test 1 (light byte-identical): resolve every token at `.aqua` and assert
     components match the legacy literal values within 1/512 tolerance.
   - Test 2 (dark matches design): resolve every token at `.darkAqua` and assert
     components match the functional-spec hex values.
   - Test 3 (no view conditionals): grep `Packages/BiscottiKit/Sources/` for
     `colorScheme` references and assert zero hits outside `DynamicColor.swift`.

5. **Green `hooks-mcp` checks**: `lint`, `format`, `test`, `build`.

## Tests

- `testLightValuesMatchLegacyLiterals` -- every token's `.aqua` resolution ==
  legacy sRGB literal (the byte-identical-light guard).
- `testDarkValuesMatchDesignSpec` -- every token's `.darkAqua` resolution ==
  design hex from functional spec section 3.
- `testNoColorSchemeConditionalsInViewCode` -- grep-based assertion that no view
  file uses `@Environment(\.colorScheme)` or `colorScheme ==`.

---
status: complete
---

# Phase 3: Home + App Shell (Primary Surfaces)

## Overview

Re-skin the two highest-visual-surface views: `HomeView` and `AppShellView`.
HomeView gets the serif greeting, mono numbers/kickers, sage links/countdowns,
and a footer brand mark with the sage `lock.shield.fill` icon. AppShellView gets
a new sidebar brand lockup, idle Record button in sage (active stays red), sage
selection highlight + glyphs, mono kicker, and the window-wall/sidebar-tint seam
(with flat warm-grey fallback). These are the two additive design elements
approved in the functional spec plus the mechanical token/family swaps on the
primary surfaces.

## Steps

### HomeView.swift

1. **Greeting block** -- `.foregroundStyle(.primary)` -> `.foregroundStyle(.ink)`;
   date text `.foregroundStyle(.secondary)` -> `.foregroundStyle(.inkSecondary)`.

2. **Stat chips row** -- calendar tint `.accentColor` -> `.sage`; "Next" dot tint
   `Tokens.liveGreen` -> `.sage` (already aliased, but make call site explicit).

3. **Hero row countdown/time** -- `Tokens.metaTextMedium` ->
   `Font.monoMetaMedium` on countdown, `Color.accentColor` -> `.sage`;
   `formattedTime` font `Tokens.metaText` -> `Font.monoMeta`, color `.secondary`
   -> `.inkSecondary`. Participants text `.secondary` -> `.inkSecondary`. Notes
   text `.secondary` -> `.inkSecondary`.

4. **Hero actions** -- "View in calendar" link `.secondary` -> `.sage` (it's a
   navigable link, not descriptive text).

5. **Ordinary upcoming row** -- countdown `Color.accentColor` -> `.sage`, font ->
   `Font.monoMetaMedium`; time font -> `Font.monoMeta`, color `.secondary` ->
   `.inkSecondary`. Chevron `.tertiary` -> `.inkTertiary`.

6. **Past meetings section** -- "See all" link `Color.accentColor` -> `.sage`.
   Past row second-line font -> `Font.monoMeta`, color `.secondary` ->
   `.inkSecondary`. Chevron `.tertiary` -> `.inkTertiary`.

7. **Group labels (kickers)** -- replace `HomeSharedViews.groupLabel` body with
   `.kicker()` modifier + `.foregroundStyle(.inkSecondary)`, remove manual
   font/tracking/textCase/padding.

8. **Footer** -- add sage `lock.shield.fill` icon above the "Biscotti" wordmark;
   `.foregroundStyle(.primary)` -> `.foregroundStyle(.ink)` on wordmark;
   `.foregroundStyle(.tertiary)` -> `.foregroundStyle(.inkTertiary)` on tagline.

9. **Empty-state cards** -- connect-calendar and no-upcoming cards: `.secondary`
   -> `.inkSecondary`. No-recordings card: `.secondary` -> `.inkSecondary`.

### AppShellView.swift

10. **Sidebar brand lockup** -- add a non-interactive brand lockup above the
    home row: `lock.shield.fill` icon (sage, ~16pt) + "Biscotti" wordmark
    (SF Pro semibold ~15pt, `.ink`), with consistent sidebar padding.

11. **Idle Record button** -- change `Tokens.recordingRed` on the idle icon to
    `.sage`; the `.bordered` button is tinted sage. Active recording stays red
    with `Tokens.recordingRed`.

12. **Active recording counter** -- `.monospacedDigit()` -> `Font.monoMeta`
    (mono font, tabular figures inherent).

13. **Sidebar nav rows (home, pastMeetings, settings)** -- selected icon
    `Color.accentColor` -> `.sage`; unselected stays `Tokens.secondaryText`.
    Selection background `Color.accentColor.opacity(0.15)` ->
    `Tokens.accentWashStrong`.

14. **Upcoming sidebar section** -- kicker `Tokens.sectionHeaderFont` +
    `Tokens.secondaryText` -> `.kicker()` + `.foregroundStyle(.inkSecondary)`.
    Event selection background `Color.accentColor.opacity(0.15)` ->
    `Tokens.accentWashStrong`.

15. **Search field** -- magnifying glass `.secondary` -> `.inkSecondary`;
    clear button `.secondary` -> `.inkSecondary`; background `.quinary` ->
    `Color.neutralChip`.

16. **ContentUnavailableView** -- "No Meeting Selected" gets `serifHeadline`
    via the label closure.

17. **Window wall** -- apply flat warm-grey `#E4E1D8` background as the
    fallback wall behind the sidebar (no radial gradient, no AppKit surgery).
    The sidebar gets a translucent ivory tint overlay. Home and detail panes
    already paint their own `paper` background.

## Tests

- No new test files. Changes are purely visual (color/font/token swaps and two
  additive label elements). Font registration tests from Phase 1 verify font
  availability. Build + lint + existing tests passing confirm no regressions.
- `mcp__hooks-mcp__build_app` confirms the app target compiles with all changes.
- Visual verification: previews for HomeView and AppShellView are reviewed for
  correct rendering in the F Sage identity.

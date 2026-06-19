---
status: complete
---

# Phase 2: DesignSystem Components Re-tokenized

## Overview

Re-skin every shared DesignSystem component to use the F Sage tokens established
in Phase 1. This is the highest-leverage phase: these components are consumed
across every screen, so re-tokenizing them once propagates the warm-ivory /
sage / mono identity everywhere they appear. The changes are purely visual
(color/font swaps); no layout, structure, or behavior changes.

## Steps

1. **Avatar.swift** -- "+N" badge: font -> `monoBadge`, text color ->
   `inkSecondary`; badge fill -> warm (`Color.inkSecondary.opacity(0.28)`).
   `RecordingAvatar` grey fill -> warm neutral (`Color.ink.opacity(0.22)`).
   Inset hairline rings and white stacked rings stay unchanged.

2. **StatChip.swift** -- value text -> `monoStat` + `inkSecondary` (already
   done in Tokens; just replace `.secondary` with `.inkSecondary`). Preview
   tints -> `.sage` instead of `.accentColor`/`.secondary`.

3. **UpcomingEventRow.swift** -- `timeLabel` font -> `monoMeta` (drop
   `.monospacedDigit()`); color -> `inkSecondary`. Badge fill ->
   `Color.neutralChip` (warm, replaces `Color.secondary.opacity(0.12)`);
   badge text -> `inkSecondary`.

4. **MeetingPlatformChip.swift** -- chip background fill ->
   `Color.neutralChip` (replaces `Color.black.opacity(0.06)`); label text
   color -> `inkSecondary` (replaces `.secondary`). Video icon tint already
   uses `Tokens.liveGreen` which is now sage.

5. **HomeCardModifier.swift** -- already uses warm tokens from Phase 1 (stroke
   = `Tokens.cardStroke`, hairline = `Tokens.hairline`). No changes needed.

6. **JoinRecordButtonStyle.swift** -- fill `Color.accentColor` -> `.sage`.

7. **TranscriptSegmentRow.swift** -- speaker chip background already uses
   `Tokens.speakerChipBackground` (= `accentWashSoft`). Text color already
   uses semantic tokens. No changes needed.

8. **StatusRow.swift** -- success checkmark `.green` -> `.sage`; secondary
   text already uses `Tokens.secondaryText`. No changes needed for text.

9. **Banner.swift** -- text color: add explicit `.foregroundStyle(.inkSecondary)`
   to message text. Warning/error icons keep amber/red (status semantics).
   Background fill -> warm (`Color.neutralChip` or keep current). No changes
   to structure.

10. **AudioTransport.swift** -- elapsed/total time font: `.caption` +
    `.monospacedDigit()` -> `Font.monoCaption` (drop `.monospacedDigit()`).
    Time text color already uses `Tokens.secondaryText`. Disabled-state
    `.tertiary` -> `.inkTertiary`.

11. **CalendarContextBlock.swift** -- background fill
    `Color.secondary.opacity(0.06)` -> `Color.neutralChip`. Text colors
    already use `Tokens.secondaryText`. No other changes needed.

12. **RecordButton.swift** -- idle dot fill: `Tokens.recordingRed` -> `.sage`
    (idle = sage per the affordance rule). Disabled stays gray.

13. **VersionPicker.swift** -- unchanged (system Menu, SF Pro stays).

14. **Update previews** -- ensure each component's `#Preview` uses warm
    backgrounds (`.background(Tokens.contentBackground)`) and sage tints
    so they read correctly in the new identity.

## Tests

- No new test files. The changes are purely visual token swaps on existing
  components. Font registration tests (Phase 1) already verify font
  availability. Build + lint + existing tests passing confirm no regressions.
- Visual verification: each component's `#Preview` is reviewed for correct
  rendering in the F Sage identity.

---
status: complete
---

# Phase 4: Remaining screens (final mechanical sweep)

## Overview

Migrate all remaining screens to the F Sage design language: MeetingListView,
MeetingDetailView/EventPreviewView, RecordingView, Onboarding, SettingsView.
Then do a final acceptance grep for stray system colors/fonts across all UI
modules.

## Steps

1. **MeetingListView** -- token/family swaps:
   - `meetingRow`: title `.font(.body)` stays (SF Pro), secondary text already
     uses `Tokens.metadataFont`/`Tokens.secondaryText` -- OK.
   - `searchRow`: date text `.font(Tokens.metadataFont)` -> `.font(.monoMeta)`,
     secondary text already warm.
   - `ContentUnavailableView("No Recordings")` -- use the label closure to
     apply `serifHeadline` to the title.

2. **MeetingDetailView** -- token/family swaps + deferred migration:
   - Header date/duration `.font(Tokens.metadataFont)` -> `.font(.monoMeta)`.
   - `notesSection`: "Notes" header -> `.kicker()` modifier.
   - `reTranscribePrompt` background: `Color.accentColor.opacity(0.08)` ->
     `Color.accentWashSoft` (the deferred migration).
   - `EventPickerSheet` time text -> `.font(.monoMeta)`.

3. **EventPreviewView** -- token/family swaps:
   - Date range `.font(Tokens.metadataFont)` -> `.font(.monoMeta)`.
   - Section headers `.font(Tokens.sectionHeaderFont)` -> `.kicker()`.
   - Platform badge fill `Color.secondary.opacity(0.12)` -> `Color.neutralChip`.

4. **RecordingView** -- counter to mono:
   - `elapsedTime`: replace `Tokens.elapsedTimeFont` + `.monospacedDigit()` with
     just `Tokens.elapsedTimeFont` (already monoElapsed). Remove `.monospacedDigit()`.
   - Everything else unchanged (reds resolve to signalRed via Tokens.recordingRed).

5. **OnboardingView + OnboardingStepViews** -- serif headline, success -> sage:
   - `wizardPage` title `.font(.title2).fontWeight(.semibold)` ->
     `.font(.serifHeadline)` (remove fontWeight).
   - `launchAtLoginStep` and `doneStep` titles likewise.
   - Success checkmarks `.foregroundStyle(.green)` -> `.foregroundStyle(.sage)`.
   - Step indicator dots: `Color.primary` -> `Color.ink`,
     `Color.secondary.opacity(0.3)` -> `Color.inkTertiary`.
   - "Open System Settings" link `.foregroundStyle(.blue)` ->
     `.foregroundStyle(.sage)`.

6. **SettingsView** -- warm neutrals:
   - Permission row success `.green` -> `.sage`.
   - No other changes needed (SF Pro stays; calendar dots keep hex; form
     structure unchanged).

7. **BiscottiApp.swift** -- warm error view neutrals:
   - `errorView`: `.foregroundStyle(.secondary)` -> `.foregroundStyle(.inkSecondary)`.

8. **Final stray-color grep** -- scan `App/Sources` + `Packages/*/Sources`
   view code for stray `systemBlue`, raw `Color.accentColor` (outside
   AccentColor asset), cool `.secondary`/`.tertiary` foreground,
   `Color.black/.white` opacities used as neutrals, raw `Font.system(...)`
   that should use the ramp.

## Tests

- No new tests (visual-only changes; existing font registration test + CI
  cover compilation). `build-app` verifies all screens compile.

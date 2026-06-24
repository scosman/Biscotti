---
status: draft
---

# Phase 2: Split Repoints, Hardcoded Sites, Verification

## Overview

Repoint the ~16 call sites identified in functional-spec section 4 to use the new
semantic tokens added in Phase 1. Confirm the hardcoded "stays" sites (section 5)
are untouched. Run all automated checks (lint, format, test, build-app).

The live dark-mode smoke pass (architecture section 5) is a human-on-hardware step
flagged for manual execution.

## Steps

1. **`JoinRecordButtonStyle.swift:19`** -- `.fill(Color.sage)` -> `.fill(Color.accentFill)`
2. **`OnboardingPrimaryButtonStyle.swift:18`** -- `.fill(Color.sage)` -> `.fill(Color.accentFill)`
3. **`AppShellView.swift:99`** -- `ToolbarRecordButtonStyle(fill: .sage)` -> `fill: .accentFill`
4. **`GrantedTag.swift:18`** -- `Circle().fill(Color.sage)` -> `.fill(Color.accentFill)`
5. **`LightAlertButtonStyle.swift:20`** -- `Tokens.cardFill` -> `Color.elevatedFill`
6. **`LightAlertButtonStyle.swift:28`** -- `.black.opacity(0.06)` -> `Color.controlShadow`
7. **`EditableMeetingTitle.swift:117`** -- `Color.white` -> `Color.elevatedFill`
8. **`TranscriptListView.swift:196`** -- `.foregroundStyle(.inkSecondary)` -> `.foregroundStyle(.read)`
9. **`RecordingView.swift:217`** -- `.foregroundStyle(Color.signalRed)` (RECORDING label) -> `.foregroundStyle(Color.signalRedText)`
10. **`AutoStopCountdownCard.swift:46`** -- `.foregroundStyle(Color.signalRed)` (seconds text) -> `.foregroundStyle(Color.signalRedText)`
11. **`EventPickerSheet.swift:125`** -- `.foregroundStyle(.signalRed)` -> `.foregroundStyle(.signalRedText)`
12. **`ManageModelsSheet.swift:281`** -- `.foregroundStyle(.signalRed)` -> `.foregroundStyle(.signalRedText)`
13. **`ModelDownloadCard.swift:208`** -- `.foregroundStyle(.signalRed)` -> `.foregroundStyle(.signalRedText)`
14. **`ProgressHeader.swift:36`** -- `.fill(Color.sage)` -> `.fill(Color.accentTrack)`
15. **`ModelDownloadCard.swift:152`** -- `.fill(Color.sage)` (indeterminate bar) -> `.fill(Color.accentTrack)`
16. **`ModelDownloadCard.swift:266`** -- `.fill(Color.sage)` (determinate bar) -> `.fill(Color.accentTrack)`
17. **`HomeCardModifier.swift:14`** -- `.black.opacity(0.05)` -> `Color.cardShadow`

18. **Verify "stays" sites** are untouched: white labels, white sheen gradients,
    avatar whites, `.ultraThinMaterial`, `Color(hex:)`, native controls,
    `AlertsHelpSheet.swift` `.tint(.sage)`, `RecordButton.swift` sage dot,
    `AudioTransport.swift` `.tint(.sage)`, `Banner.swift` signalRed icon.

19. **Green automated checks** via hooks-mcp: format, lint, test, build-app.

## Tests

- Existing Phase 1 tests (light byte-identical, dark matches design, no colorScheme
  conditionals) continue to pass -- they validate the tokens, and these repoints
  only change which token a call site references (same light value).
- No new tests needed: the repoints swap one equal-in-light token for another;
  the token values are already fully tested. The `noColorSchemeInViews` test
  confirms we did not introduce any appearance conditionals.

---
status: draft
---

# Phase 4: Import screen, sidebar row and File menu

## Overview

Builds the user-facing Import screen, the sidebar "Imported" row, the File menu command, and supporting design-system additions. The drop overlay and window drop target are deferred to Phase 5. This phase makes the import flow visible and usable through the file menu entry point.

## Steps

1. **DesignSystem: new tokens and `BezelButtonStyle`.**
   - Add `Color.dropVeil` / `Tokens.dropVeil` and `Color.controlStroke` / `Tokens.controlStroke` to `Color+Theme.swift` and `Tokens.swift`.
   - Add `BezelButtonStyle` to a new `BezelButtonStyle.swift` in DesignSystem: elevated fill, 0.5pt controlStroke border, controlShadow, pressed overlay, disabled opacity.

2. **Formatting: `TimeFormatting.dateAndTime(_:)`.**
   - Add `dateAndTime(_:)` to `TimeFormatting.swift`: `"Oct 30, 2026 \u{00B7} 2:14 PM"` format using `shortDate` and a new short-time formatter.

3. **Package.swift: add `ImportUI` target and test target.**
   - New library target `ImportUI` depending on `AppCore`, `AudioImport`, `DataStore`, `DesignSystem`, `Formatting`.
   - New test target `ImportUITests` depending on `ImportUI`, `AppCore`, `AudioImport`, `BiscottiTestSupport`, `DataStore`, `Formatting`, plus transitive test deps.
   - Add `ImportUI` as a dependency of `AppShellUI`.

4. **ImportUI module: `DropOverlayState`.**
   - `Sources/ImportUI/DropOverlayState.swift`: the enum with `classify`, `acceptsDrop`, copy properties (title, subtitle, showsFormatLine, skipNotice, isNeutral).

5. **ImportUI module: `ImportViewModel` and `ImportRowModel`.**
   - `Sources/ImportUI/ImportViewModel.swift`: `@MainActor @Observable` class mapping `core.audioImport.items` to `[ImportRowModel]`, computing `header`, with `goToMeeting` and `showInFinder` actions.

6. **ImportUI module: `ImportView` and `ImportRowView`.**
   - `Sources/ImportUI/ImportView.swift`: ScrollView layout per ui_design section 3 -- centered column, header, card with lazy rows.
   - `Sources/ImportUI/ImportRowView.swift`: individual row per ui_design section 3.3.

7. **AppShellUI: wire ImportUI.**
   - Add `ImportUI` import.
   - `AppShellViewModel`: add `importViewModel`, `dropTarget`, `hasImportSession`, `isImportConverting`, `showImport()`, `importFiles(_:)`, import-panel passthroughs.
   - `AppShellView`: wire `DetailContentView` for `.importing`, add `importedRow` in the sidebar footer, add `.fileImporter` and `onChange` for import panel request.

8. **App: File > Import Audio File... command.**
   - `BiscottiApp.swift`: `CommandGroup(replacing: .importExport)` with the menu item, `keyboardShortcut("i", modifiers: [.command, .shift])`, disabled during onboarding.

## Tests

- `DropOverlayStateTests`: classify truth table, acceptsDrop, all copy properties, singular/plural variants.
- `ImportViewModelTests`: row mapping for each status, deleted meeting, date text, goToMeeting routing, showInFinder with existing/missing file, header passthrough.
- `TimeFormattingTests`: dateAndTime produces expected format.
- `AppShellViewModelTests`: hasImportSession/isImportConverting, importedRow visibility, importPanelRequested passthrough.

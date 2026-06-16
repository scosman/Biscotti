---
status: complete
---

# Phase 1: DesignSystem Foundations + Shared Title

## Overview

Add the new color tokens required by the recording redesign, create the reusable
`LightAlertButtonStyle`, and extract the inline editable-title control from
`MeetingDetailView` into a shared `EditableMeetingTitle` component in
`DesignSystem`. Refactor `MeetingDetailView` to use the shared control --
behavior-preserving. This phase is the foundation for Phases 3-5.

## Steps

1. **Add new color tokens to `Color+Theme.swift`:**
   - `recordingTintSoft` = `signalRed` @ 0.08
   - `recordingTintStrong` = `signalRed` @ 0.12
   - `recordingOutline` = `signalRed` @ 0.32
   - `recordingOutlineStrong` = `signalRed` @ 0.20
   - `recordingHoverFill` = `signalRed` @ 0.05
   - `warningChipFill` = `warningOchre` @ 0.16
   - `warningChipText` = `warningOchre` (alias, for semantic clarity)
   - `softSageFill` = `sage` @ 0.12

2. **Add token aliases to `Tokens.swift`:**
   Add corresponding `Tokens.*` static properties for the new colors, following
   the existing pattern.

3. **Create `LightAlertButtonStyle` in `DesignSystem/LightAlertButtonStyle.swift`:**
   ```swift
   public struct LightAlertButtonStyle: ButtonStyle {
       // White cardFill, recordingOutline 0.5pt border, whisper shadow,
       // signalRed content, recordingHoverFill on hover.
   }
   ```
   Shared by Stop & Save and the recording-state header button.

4. **Create `EditableMeetingTitle` in `DesignSystem/EditableMeetingTitle.swift`:**
   Extract the inline title control from `MeetingDetailView.header` -- the
   ZStack of TextField + truncating Text, the focus box, the selectAll on tap,
   and the click-away NSEvent local monitor -- into a reusable View.
   ```swift
   public struct EditableMeetingTitle: View {
       @Binding var text: String
       var placeholder: String
       var font: Font
       var tracking: CGFloat = -0.27
       var onCommit: () async -> Void
   }
   ```

5. **Refactor `MeetingDetailView` to use `EditableMeetingTitle`:**
   Replace the inlined title control + private monitor helpers with:
   ```swift
   EditableMeetingTitle(
       text: $viewModel.editableTitle,
       placeholder: "Untitled meeting",
       font: .biscottiSerif(27),
       onCommit: { await viewModel.saveTitle() }
   )
   ```
   Remove `@FocusState private var titleFieldFocused`, `titleFrame`,
   `clickAwayMonitor`, `installClickAwayMonitor()`, `removeClickAwayMonitor()`
   from MeetingDetailView. The `.onChange(of: titleFieldFocused)` and
   `.onDisappear` cleanup for the monitor also move into the shared control.

## Tests

- No new unit tests for this phase (the components are SwiftUI/AppKit views
  verified via the existing meeting-detail manual flow). The key verification
  is that existing tests stay green and the meeting-detail title behavior is
  identical after extraction.
- Existing `MeetingDetailUITests` and `RecordingUITests` must pass unchanged.

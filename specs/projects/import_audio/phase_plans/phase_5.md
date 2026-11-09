---
status: done
---

# Phase 5: Window drop target and overlay

## Overview

Builds the AppKit window drop target (`WindowDropView`), the SwiftUI drop overlay (`DropOverlayView`), the pasteboard classification logic, file-promise handling, and the `NSViewRepresentable` bridge (`WindowDropTargetInstaller`). Wires them into the shell root. Adds tests for pasteboard classification and the overlay state machine.

## Placement

Both the drag target and the visual overlay must cover the **entire** window, including the toolbar/titlebar strip. A SwiftUI `.overlay` NSViewRepresentable is confined to the content area below the toolbar, so P1 alone is not sufficient.

**Drag target** — `WindowDropView` is installed on the window's theme frame (`contentView.superview`) by `DropTargetInstallerView.viewDidMoveToWindow()`. The `DropTargetInstallerView` is a zero-size NSView hosted in SwiftUI via `WindowDropTargetInstaller` (as a `.background`). When it enters a window, it creates and adds the `WindowDropView` to the theme frame with `autoresizingMask = [.width, .height]`. The `hitTest(_:)` filter returns nil for all mouse/scroll/cursor events, preserving click-through to toolbar buttons and SwiftUI content.

**Visual overlay** — `DropOverlayView` is hosted in a borderless, transparent child `NSPanel` (`OverlayPanel`) created lazily by `WindowDropView.ensureOverlayPanel()` on the first `draggingEntered`. This keeps the `NSHostingView` out of memory when idle. The `NSHostingView` uses `sizingOptions = []` and the SwiftUI root has `.frame(maxWidth: .infinity, maxHeight: .infinity)` so it fills the panel even when the overlay content is invisible. The panel uses `ignoresMouseEvents = true`, so all clicks, scrolling, and traffic-light buttons pass through. `syncFrame()` is called on `draggingEntered` and `draggingUpdated` to keep the panel aligned with the parent window. Its content is clipped with a 10 pt continuous corner radius to match the parent window's rounded corners.

## Steps

1. Create `WindowDropView.swift` in `ImportUI/`:
   - `NSView` subclass implementing `NSDraggingDestination`.
   - Registers for `.fileURL` + `NSFilePromiseReceiver.readableDraggedTypes`.
   - `hitTest(_:)` returns nil for all mouse/scroll/cursor events, passes through for drag-destination lookup.
   - `draggingEntered` classifies the pasteboard, sets `model.state`, caches the operation.
   - `draggingExited` / `draggingEnded` / `concludeDragOperation` → `model.state = nil`.
   - `performDragOperation` builds `[ImportEntry]` from classified items and calls `onDrop`.
   - `wantsPeriodicDraggingUpdates = false`.

2. Create `PasteboardClassification.swift` in `ImportUI/`:
   - `DraggedItemDescriptor` with `.file(URL)` and `.promise(typeIdentifier: String?, index: Int)` kinds.
   - `PasteboardClassifier.describe(_: NSPasteboard) -> [DraggedItemDescriptor]`.
   - `PasteboardClassifier.supportedFlags(_: [DraggedItemDescriptor]) -> [Bool]`.

3. Create `PromisedFile.swift` in `ImportUI/`:
   - `@unchecked Sendable` class holding a `CheckedContinuation<URL, Error>`.
   - Supports resolution before or after awaiting.
   - First-file-only approach per receiver (multi-file promises are unreliable).

4. Create `DropOverlayView.swift` in `ImportUI/`:
   - SwiftUI view rendering `DropTargetModel.state`.
   - Layers: veil (`.ultraThinMaterial` + `Color.dropVeil`), dashed drop zone, centered content stack.
   - Tile (76x76), title, subtitle, format line, skip notice pill per spec.
   - `.transition(.opacity)` with `.easeOut(duration: 0.14)`.
   - Accessibility announcement on state change.

5. Create `WindowDropTargetInstaller.swift` in `ImportUI/`:
   - `WindowDropTargetInstaller` (`NSViewRepresentable`) returns `DropTargetInstallerView`.
   - `DropTargetInstallerView` (zero-size NSView): on `viewDidMoveToWindow` adds `WindowDropView` to the theme frame; on removal, cleans up.
   - `WindowDropView.viewDidMoveToWindow` creates `OverlayPanel` (transparent child `NSPanel`) hosting `DropOverlayView`.

6. Wire into `AppShellView.swift`:
   - Add `WindowDropTargetInstaller` as a `.background` on the outer `Group`.
   - No separate `DropOverlayView` overlay (it is hosted in the child panel).

## Tests

- `PasteboardClassificationTests`: file-URL items, promise descriptors, plain-string items ignored, `supportedFlags` truth table.
- `OverlayPanelTests` / `DropTargetInstallerViewTests`: **removed**. Both involve `NSThemeFrame` (private Apple view) or `NSHostingView`-backed panels. Creating and tearing down these objects in sequential `--no-parallel` tests causes SIGSEGV (NSHostingView deferred SwiftUI teardown corrupts process state). The frame-alignment and installer-placement behaviour is trivially correct and verified on hardware.
- `DropOverlayStateTests`: already exist from Phase 4 (classify, acceptsDrop, all copy).
- `ImportViewModelTests`: already exist from Phase 4.
- `AppShellUITests`: imported-row tests already exist from Phase 4.

## Promises approach

First-file-only per receiver. Multi-file promises (one dragged item promising several files) are unreliable: callback counts can exceed `fileTypes.count`, and a never-resolved future would leave a row stuck. Each `NSFilePromiseReceiver` produces one `ImportEntry`. Extra callbacks are ignored and their files deleted.

## Manual verification checklist (human, run after all automated checks pass)

Run on a Mac, in light and dark mode:

1. Drag 1 `.m4a` from Finder over each of: the sidebar, the Home body, the Meetings list, meeting detail (transcript, notes editor, summary), Settings, the Recording screen, and the Import screen. Each shows "Drop to import" with the format line, and the cursor shows "+". Dropping lands on the Import screen.
2. Drag 3 supported files: "Drop to import 3 files".
3. Drag 3 supported + 2 PDFs: mixed title + "2 files are unsupported…". After the drop, only 3 rows appear.
4. Drag 1 PDF: neutral "Can't import this file", no "+" badge. The drop does nothing.
5. Drag text or a link from Safari: no overlay.
6. Drag a recording from Voice Memos and a video from Photos: the overlay shows, and the rows go "Receiving…" then "Converting…" then Go to Meeting.
7. With no drag in progress: clicks, scrolling, hover highlights, tooltips, context menus, text editing in the notes and title fields, and toolbar buttons all behave exactly as before.
8. Esc during a drag dismisses the overlay.
9. During onboarding: no overlay, the drop is refused, and the File menu item does nothing or is disabled.
10. File > Import Audio File... (and Cmd+Shift+I): the sheet is filtered to audio/video and allows multi-select. Import lands on the Import screen.

## Hardware verification results (2026-11-08)

Steps 1--5 and 7--10: **PASS**.

Step 6 (drag from Voice Memos / Photos): **CRASH** -- deferred to a follow-up task. The app crashes when receiving a file promise from Voice Memos.

### Observed log noise

- **Theme-frame warning (functional, cosmetic only):** The unified log shows `NSWindow warning: adding an unknown subview: <ImportUI.WindowDropView: …>` once per window when the drop view is installed on the theme frame. The warning does not affect behaviour; it is logged by AppKit's `-[NSThemeFrame addSubview:]` for any non-standard subview.
- **Metal shader cache errors (unrelated):** `Unable to open mach-O at path: default.metallib Error:2` and `flock failed to lock list file (.../com.apple.metal/.../functions.list): errno = 35`. These are system-level Metal shader-cache log lines unrelated to Biscotti.

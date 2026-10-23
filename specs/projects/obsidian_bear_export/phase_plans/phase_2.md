---
status: draft
---

# Phase 2: Sending + UI

## Overview

Build the effects layer (`SendEnvironment`, `AppCore+SendTo`), the icon loading (`ExportIcons`), the send-to buttons in the meeting detail tab bar, the overflow menu submenu, the alerts, and the VM/AppCore/DesignSystem tests. This wires the Phase 1 pure logic into real AppKit/SwiftUI interactions.

## Steps

1. **`DesignSystem/ExportIcons.swift`** -- new file. `ExportIcons` enum with `Kind` (obsidian, bear, appleNotes) and `image(_:) -> NSImage`. Loads SVGs from `Bundle.module` Resources/Icons as template images, cached in a static dictionary.

2. **`AppCore/SendEnvironment.swift`** -- new file. `SendEnvironment` struct with closures for `appURLForScheme`, `appURLForBundleID`, `openURL`, `openFile`, `openApp`, `writePasteboard`, `tempRoot`, `now`, `timeZone`. Plus `static let live` wiring to real NSWorkspace/FileManager/NSPasteboard.

3. **`AppCore/AppCore+SendTo.swift`** -- new file. Extension on AppCore with `SendOutcome` enum, `installedSendDestinations()`, `send(_:to:)` async, and `openDestinationApp(_:)`. Uses the `SendEnvironment` stored on AppCore. Detection is live (no cache), since NSWorkspace lookups are sub-millisecond.

4. **`AppCore/AppCore.swift`** -- add `sendEnvironment: SendEnvironment` parameter to init (default `.live`), stored as `let sendEnvironment`.

5. **`MeetingDetailUI/MeetingDetailViewModel.swift`** -- add send-to state: `sentExports: [SentExport]`, `sendDestinations: [ExportDestination]`, `sendAlert: SendAlert?`, computed `sendSource: ExportSource?` and `canSend: Bool`. Add methods `sendTapped(_:)`, `sendAgain(_:)`, `openApp(_:)`, `performSend(_:)`. Wire into `refreshData()` and `load()`.

6. **`MeetingDetailUI/SendToButton.swift`** -- new file. Small SwiftUI button rendering an ExportIcons image as template at 14pt, with `.borderless` / `.controlSize(.small)` / `.foregroundStyle(.inkSecondary)`, tooltip and accessibility label per spec.

7. **`MeetingDetailUI/MeetingDetailView.swift`** -- add SendToButton instances after the Copy button in tabBar, add "Send to" submenu in overflowMenu, add `.alert` binding for `sendAlert`.

## Tests

**`DesignSystemTests/ExportIconTests.swift`:**
- All three icons load successfully
- Images are non-empty (size > 0)
- Images have `isTemplate = true`

**`AppCoreTests/SendToTests.swift`** (fake `SendEnvironment`):
- URL send (Obsidian) records the export with the correct hash
- `openURL` returns false -> `.failed`, no record written
- Oversize payload -> pasteboard written, `.copiedToClipboard`, no record, no URL opened
- Notes file hand-off -> temp file exists with correct contents, `openFile` called with Notes app URL, record written
- `openFile` throws -> `.failed`, no record
- Not installed -> `.failed`
- `installedSendDestinations` returns correct order and filters out unavailable apps

**`MeetingDetailUITests/SendToTests.swift`:**
- `sendSource` includes unsaved edits (title, summary, notes, tags)
- `alreadySent` alert with `changed` after a notes edit
- `tooLarge` alert after oversize send
- `canSend` false when summary and notes are both empty
- `sendDestinations` updates from AppCore

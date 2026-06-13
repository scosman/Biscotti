---
status: complete
---

# Phase 6: Top app bar & record relocation

## Overview

Move the Record button from the sidebar to the top app bar (toolbar), narrow the search field to ~60% width and change its placeholder to "Search", and verify no app name leaks into the top bar. The result is exactly one record button (toolbar, trailing side next to search), a narrower search field, and no app name visible in the bar.

## Steps

1. **Verify app name removal (already done).** Phase 3 added `WindowTitleHider` to hide `NSWindow.titleVisibility`. No SwiftUI `navigationTitle("Biscotti")` is set in `AppShellView`. Confirm no app name renders in the toolbar / sidebar header. No code change expected.

2. **Add a Record toolbar button (trailing, next to search).** In `AppShellView`, add a `ToolbarItem(placement: .primaryAction)` containing a record button that calls `viewModel.startRecording()`, disabled when `viewModel.recordButtonDisabled`. Use SF Symbol `"record.circle"` with a `.help("Record")` accessibility label.

3. **Narrow the search field and change placeholder.** Change the `.searchable` prompt from `"Search meetings\u{2026}"` to `"Search"`. Add a `.frame(maxWidth: 180)` (approximately 60% of the current ~300pt default) on a wrapping approach if possible, or use a `ToolbarItem` with `.searchable` placement constraints. Since `.searchable` doesn't directly support width, the most reliable macOS approach is keeping `.searchable` but changing the prompt. Width tuning may need the `NSToolbar` introspection; we'll use `.searchable`'s natural sizing and accept that exact 60% requires on-device tuning.

4. **Remove the Record button from the sidebar.** Remove the `recordSection` view and its usage from the `sidebar` `VStack` in `AppShellView`. Remove the `RecordButton` import usage from the sidebar (it remains in `DesignSystem` for use in `EventPreviewView`).

5. **Add a test** that the toolbar record action routes through the same `startRecording` path on `AppShellViewModel`. The existing `recordButtonDisabledWhenRecording` test validates this, but add a test confirming `startRecording()` from the view model routes to `.recording` (already exists: `routeRecordingAfterStart`). No new test needed for the view-model layer since the passthrough is already tested.

## Tests

- Existing `routeRecordingAfterStart` already tests that `viewModel.startRecording()` routes to `.recording` -- this is the same action the toolbar button will call. No new test required since we're reusing the exact same view-model method, not adding a new one.
- Existing `recordButtonDisabledWhenRecording` confirms the disabled state. The toolbar button reads the same `recordButtonDisabled` property.
- Visual/layout (search width, toolbar placement, app-name absence) verified on device.

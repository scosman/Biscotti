---
status: complete
---

# Phase 3: "Notifications Stay Visible" row

## Overview

Adds the self-hiding "Notifications Stay Visible" settings row that guides users to switch Biscotti's macOS notification style to Alerts. This requires: a new `NotificationAlertStyle` enum and `alertStyle()` provider method in the Notifications module, a `currentAlertStyle()` mapper on `NotificationService`, a `notificationsUseBannerStyle()` helper on `AppCore`, and the conditional row + explanatory help sheet in `SettingsUI` (with `showStayVisibleRow`, `refreshAlertStyle()`, `openNotificationSettings()`, and a `didBecomeActive` re-check).

## Steps

### Notifications module

1. **New file `Notifications/NotificationAlertStyle.swift`** -- Public Sendable enum with cases `.none`, `.banner`, `.alert`.

2. **`NotificationCenterProviding.swift`** -- Add `func alertStyle() async -> UNAlertStyle` to the protocol.

3. **`LiveNotificationCenter.swift`** -- Implement `alertStyle()`: return `await UNUserNotificationCenter.current().notificationSettings().alertStyle`.

4. **`NotificationService.swift`** -- Add `public func currentAlertStyle() async -> NotificationAlertStyle` that maps the provider's `UNAlertStyle` to the app's enum (`.none` -> `.none`, `.banner` -> `.banner`, `.alert` -> `.alert`, `@unknown default` -> `.banner`).

### FakeNotificationCenter (test support)

5. **`FakeNotificationCenter.swift`** (in NotificationsTests) -- Add `var scriptedAlertStyle: UNAlertStyle = .banner` to Backing and implement `alertStyle()`.

6. **`CoreFixture.swift`** (in BiscottiTestSupport) -- Add `var scriptedAlertStyle: UNAlertStyle = .banner` to `FakeTestNotificationCenter.Backing` and implement `alertStyle()`.

### AppCore

7. **`AppCore.swift`** -- Add `public func notificationsUseBannerStyle() async -> Bool` returning `await notifications.currentAlertStyle() == .banner`.

### SettingsUI

8. **`SettingsViewModel.swift`** -- Add `public private(set) var showStayVisibleRow = false`. In `load()`, set `showStayVisibleRow = await core.notificationsUseBannerStyle()`. Add `public func refreshAlertStyle() async` and `public func openNotificationSettings()`.

9. **`SettingsView.swift`** -- Add Row 4 (conditional on `viewModel.showStayVisibleRow`) inside `notificationsSection`: HStack with title/subtitle VStack + "Enable" button. Add `@State private var showAlertsHelp = false` and `.sheet(isPresented:)` presenting `AlertsHelpSheet`. Add `.onReceive(NSApplication.didBecomeActiveNotification)` to call `refreshAlertStyle()`.

10. **`AlertsHelpSheet` view** (new private view in a sibling file or same file) -- Modal sheet with title "Keep Notifications On Screen", explanatory text, 3 numbered steps, Cancel + Open Settings buttons.

## Tests

### Notifications
- `currentAlertStyle()` maps each `UNAlertStyle` value (`.none`, `.banner`, `.alert`) to the correct `NotificationAlertStyle` case. Uses the existing FakeNotificationCenter with a scriptable `alertStyle`.

### SettingsUI
- `SettingsViewModel.showStayVisibleRow` is `true` when alert style is `.banner`, `false` when `.alert` or `.none`.
- `refreshAlertStyle()` updates `showStayVisibleRow` to reflect a changed scripted style.

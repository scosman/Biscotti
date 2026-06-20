---
status: complete
---

# Architecture: Onboarding Redesign

A contained, view-layer refresh of `Packages/BiscottiKit/Sources/OnboardingUI`,
plus one small reusable extraction into `DesignSystem`. No new modules, no data
model, no dependency changes, no changes to `AppCore`/`Permissions`/`Calendar`/
`TranscriptionService` APIs. The only logic change is reshaping the
`OnboardingViewModel` **step machine** so a single consolidated permissions
screen drives four independent permission rows — every underlying behavior is
preserved.

Single architecture doc; **no component designs** (the work is small and lives
in one module). Visual detail is in `ui_design.md`; behavior contract in
`functional_spec.md`.

---

## 1 · Affected code

| File | Change |
|---|---|
| `OnboardingUI/OnboardingViewModel.swift` | Reshape `Step` enum (5 cases); split `requestPermission()` into four per-permission methods; update `advance`/`skip`/`footerButton`/`progressIndex`/`totalSteps`/`syncLivePermissionState`; remove `.launchAtLogin` + `setLaunchAtLogin`. |
| `OnboardingUI/OnboardingView.swift` | Rebuild as the new scaffold: `ProgressHeader`, centered content switching on 5 steps, `BrandFooter`. |
| `OnboardingUI/OnboardingStepViews.swift` | Replace per-step views with the new screens (Welcome, Grant access + `PermissionRow` card, Choose calendars, Download, Done). |
| `OnboardingUI/` (new files) | `OnboardingScaffold`, `ProgressHeader`, `PermissionRow` + card, `OnboardingPrimaryButtonStyle`, Granted tag. |
| `DesignSystem/` (new) | `BrandFooter` (promoted from Home's private `HomeFooter`). |
| `HomeUI/HomeView.swift` | Replace private `HomeFooter` with `DesignSystem.BrandFooter` (keep Home's `.padding(.top, 30)` at the call site). |
| `Tests/OnboardingUITests/*` | Migrate per §6. |

`AppShellView` (presentation gate on `route == .onboarding`), `AppCore`
(`completeOnboarding`, `showOnboardingReplay`), and the `BiscottiApp`
window/scene are **unchanged**.

---

## 2 · `OnboardingViewModel` — the step-machine refactor

### 2.1 Step enum (screens, not permissions)

```swift
public enum Step: Int, CaseIterable, Sendable {
    case welcome = 0
    case permissions          // consolidated: mic + system audio + calendar + notifications
    case calendarSelection    // conditional: only when calendar granted
    case modelDownload
    case done
}
```

- `totalSteps` → `Step.allCases.count` (5).
- `progressIndex` → `currentStep.rawValue` (0…4). Fill = `(rawValue + 1) / 5`
  → 20/40/60/80/100%. `calendarSelection` owns position 2 (60%); when it is
  skipped the bar moves `.permissions` (40%) → `.modelDownload` (80%) — the
  "jump past" from functional_spec §2. No custom mapping table is needed
  anymore (rawValue *is* the position).

### 2.2 Per-permission request methods (replaces `requestPermission()`)

The four rows are on screen simultaneously, so requests can no longer be keyed
to `currentStep`. Split the existing `switch currentStep` body verbatim into
four independent methods, each called by its row's Grant control:

```swift
public func requestMicrophone() async      // body of old case .microphone
public func requestSystemAudio() async     // body of old case .systemAudio (probe + states)
public func requestCalendar() async        // body of old case .calendar (+ noteCalendar)
public func requestNotifications() async   // body of old case .notifications
```

Each preserves its exact logic and result mapping (mic → `.authorized/.denied`;
system audio → `isValidatingSystemAudio` + `SystemAudioPermissionState`;
calendar → `.authorized/.denied/.notDetermined` + `core.permissions.noteCalendar`;
notifications → granted bool). `requestPermission()` is removed.

### 2.3 Navigation: `advance()` and `skip()`

With consolidation, the forward transition depends only on `currentStep` and
permission **state**, not on whether the user pressed Continue vs Skip. Both
delegate to one private `proceed()`:

```swift
private func proceed() async {
    switch currentStep {
    case .welcome:
        currentStep = .permissions
    case .permissions:
        if calendarResult == .authorized {
            let infos = await core.calendar.calendars()
            calendarGroups = Self.groupCalendars(infos)
            currentStep = .calendarSelection
        } else {
            checkDiskSpace()
            currentStep = .modelDownload
        }
    case .calendarSelection:
        checkDiskSpace()
        currentStep = .modelDownload
    case .modelDownload:
        currentStep = .done
    case .done:
        await completeOnboarding()
    }
    syncLivePermissionState()
}

public func advance() async { await withAnimationProceed() }
public func skip()    async { await withAnimationProceed() }
```

(`advance`/`skip` stay as the public API the views call — Continue calls
`advance`, Skip calls `skip` — but they now do the same state-based thing.)

**Behavior preserved:** Choose-calendars appears **iff calendar is granted**
— exactly as today (where granted → Continue → branch; ungranted → Skip →
no selection). The disk-space check still runs immediately before
`.modelDownload` is shown (moved from the old notifications→download edge to
both edges that now enter download).

### 2.4 Footer button

```swift
public enum FooterButton: Equatable, Sendable { case continueButton, skip }  // .custom removed

public var allPermissionsGranted: Bool {
    microphoneGranted && systemAudioGranted && calendarGranted && notificationsGranted
}

public func footerButton(for step: Step) -> FooterButton {
    switch step {
    case .welcome, .calendarSelection, .done: .continueButton
    case .permissions: allPermissionsGranted ? .continueButton : .skip
    case .modelDownload: downloadComplete ? .continueButton : .skip
    }
}
```

The Grant-access footer shows **Skip** until all four granted, then
**Continue** (functional_spec §3) — aggregating the old per-step gating.
`isCurrentStepComplete` is unchanged (`footerButton(for: currentStep) ==
.continueButton`).

### 2.5 Live-state sync

`syncLivePermissionState()` for `.permissions` syncs **all four** rows (not one),
so already-granted permissions show the Granted tag on entry:

```swift
case .permissions:
    microphoneResult = core.permissions.microphone
    systemAudioResult = core.permissions.systemAudio
    calendarResult = mapped(core.calendar.auth)
    notificationsGranted = core.permissions.notifications == .authorized
default: break
```

### 2.6 Removed

- `Step.launchAtLogin`, all its handling, and `setLaunchAtLogin(_:)`.
- `FooterButton.custom`.
- `import ServiceManagement` (now unused in the VM — verify and drop).
- Launch-at-login is unaffected app-wide: still defaults ON via
  `BiscottiApp.registerLaunchAtLogin()` and is toggled in `SettingsUI` (both
  untouched).

`resetForReplay()` resets the same fields it does today (none were
launch-at-login state); it remains the replay entry point.

---

## 3 · View layer

`OnboardingView` becomes the scaffold host, switching content on the 5 steps.
All visual specifics (tokens, sizes, the `PermissionRow` states, motion) are in
`ui_design.md`; the architecture-level points:

- **`OnboardingScaffold`** wraps every screen: `ProgressHeader` (top) ·
  centered content (maxWidth 520) · `BrandFooter` (bottom). Background
  `Color.paper`.
- **Grant access** renders one `.homeCard()` with four `PermissionRow`s
  (`InsetDivider` between). Each row owns its trailing state view and calls the
  matching `viewModel.requestX()`; the system-audio row keeps the
  `.fixPermissionsAlert` modifier and binds `showFixPermissionsAlert`.
- **Step transition animation** stays in the VM (`withAnimation(.easeInOut)`
  around step changes), honoring `accessibilityReduceMotion` at the view level.
- New `OnboardingPrimaryButtonStyle`; Grant pills reuse `JoinRecordButtonStyle`;
  `Banner` and `FixPermissionsAlert` reused.

### 3.1 `BrandFooter` extraction

Move Home's private `HomeFooter` body into `public struct BrandFooter: View` in
`DesignSystem`, **without** the `.padding(.top, 30)`. `HomeView` uses
`BrandFooter().padding(.top, 30)` (Home unchanged); the onboarding scaffold uses
`BrandFooter()` positioned by its bottom `Spacer`. Pure refactor — identical
pixels on Home.

---

## 4 · Behavior-preservation contract

Unchanged and must remain so (the refresh is view + step-machine-shape only):

- Every permission request path, result mapping, denial guidance, and the
  system-audio probe/`requestedNotVerified`/Retry/Fix-permissions flow.
- Calendar selection: grouping, default-all (`nil`), toggle persistence via
  `core.store.updateSettings`, and **revert-on-failure**.
- Model download: disk-space gate, `Download Now`, progress/status stream,
  failure message + retry, completion; skip does **not** cancel the in-flight
  task.
- `completeOnboarding()` (persist flag, route → Home, start deferred services)
  and the replay path.

---

## 5 · Error handling

No change. Errors surface exactly as today: denial guidance for denied
mic/calendar; `Banner`/caption for download failure; `FixPermissionsAlert` for
unverified system audio; silent best-effort for settings persistence (calendar
toggles revert on failure). No new error surfaces are introduced.

---

## 6 · Testing strategy

Swift Testing, `@testable import OnboardingUI`, existing fakes
(`makeCoreFixture`, `FakeNotificationAuthorizer`, fake event store). Behavior
coverage must not regress; only step-structure assertions change.

**Rewrite (step-structure / API surface):**
- `OnboardingFooterButtonTests` — re-expressed against the new steps:
  - welcome/done/calendarSelection → Continue (keep).
  - **New** `.permissions` gating: Skip until all four granted; granting a
    subset keeps Skip; all four granted → Continue. Drive via the new
    `requestMicrophone/SystemAudio/Calendar/Notifications`.
  - `.modelDownload` Skip→Continue (keep; shorter walk).
  - **Delete** the `launchAtLogin == .custom` test.
- `OnboardingViewModelTests`:
  - "advances through all steps…", "progress index maps…", "total steps is 8"
    → rewrite for the 5-step sequence / `rawValue` progress / "total steps is 5".
  - calendar-selection-shown/-skipped, skip-without-request, download
    skippable/status, disk-check, calendar grouping, all-enabled-when-nil,
    completeOnboarding, resetForReplay → keep assertions; update the step walk
    and (for disk-check) the entry edge.
- `OnboardingGrantedAndLoginTests`:
  - granted-state-derived, already-granted-on-entry → keep; reframe to the
    `.permissions` screen syncing all four; update call surface.
  - **Delete** the three launch-at-login tests (the capability is covered by
    existing `SettingsUI` tests, untouched).

**Keep (behavior; update only the call surface):**
- `OnboardingSystemAudioTests` (probe toggles `isValidating`, approved/
  requestedNotVerified results, non-blocking skip/advance, fix-permissions
  alert toggle, no-probe-on-entry, reset) → call `requestSystemAudio()` and
  drive the consolidated screen instead of walking to a `.systemAudio` step.
- `OnboardingNotificationTests` (authorizer wiring, granted/denied, missing
  authorizer) → call `requestNotifications()`.

**New tests:**
- `allPermissionsGranted` aggregation (false until all four; true when all).
- Progress: `.calendarSelection` is position 2 (60%) and the bar jumps
  40%→80% when calendar is not granted.
- `advance()` and `skip()` from `.permissions` both branch to
  `.calendarSelection` iff calendar granted.

Gate: `make ci` (lint + test + build) green. Per the repo's manual-test
staleness rule, this project touches neither `Packages/Transcription` nor
`Packages/AudioCapture`, so `manual_test_results.json` is **not** affected.

---

## 7 · Risks & mitigations

- **Test churn (largest risk).** ~970 lines, tightly coupled to the old step
  machine. Mitigation: the §6 plan classifies every test up front;
  behavior assertions are copied, only walks/API change.
- **`requestPermission()` callers.** Verified only called within `OnboardingUI`
  (the VM + `OnboardingStepViews` + tests), all of which are being rewritten;
  `SettingsUI.requestPermission(for:)` is an unrelated method on a different VM.
  Safe to remove.
- **Disk-check timing.** Must run on *both* edges into `.modelDownload`
  (permissions-no-calendar and calendarSelection), else the warning is missed
  on one path. Covered by an updated disk-check test on each path.
- **System-audio row complexity.** Its multi-state trailing view is the most
  intricate row; build it from the existing `systemAudioStep` logic to avoid
  drift, and keep the `.fixPermissionsAlert` attached at the screen level.
- **Reduced-motion.** Verify the row Grant→Granted spring and step cross-fade
  both degrade to instant under `accessibilityReduceMotion`.

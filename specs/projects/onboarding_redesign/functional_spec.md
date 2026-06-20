---
status: complete
---

# Functional Spec: Onboarding Redesign

## 0 · Nature of this project

This is a **visual refresh** of the existing first-run onboarding flow
(`Packages/BiscottiKit/Sources/OnboardingUI`). Every permission request,
error/denial path, validation/retry flow, conditional step, persistence
side-effect, and skip affordance that exists today is preserved exactly, with
**two sanctioned structural changes**:

1. **Screen consolidation** — the four separate permission screens become one
   "Grant access" screen with one row per permission.
2. **Launch-at-Login screen removed** — simply dropped from onboarding. The
   toggle already exists in Settings and is untouched; nothing is relocated or
   added (see §6).

Visual realization (layout, tokens, components, motion) is specified separately
in `ui_design.md`.

The authoritative description of current behavior is the existing code:
`OnboardingViewModel`, `OnboardingView`, `OnboardingStepViews`,
`AppShellView` (presentation), `AppCore.completeOnboarding()`. This spec
re-states that behavior as the contract the refresh must not break.

---

## 1 · Screen sequence

The wizard is a single linear path. Screens, in order:

| # | Screen | Internal step(s) | Conditional? | Progress kicker |
|---|---|---|---|---|
| 1 | Welcome | `.welcome` | always | `WELCOME` |
| 2 | Grant access (consolidated) | `.microphone`, `.systemAudio`, `.calendar`, `.notifications` | always | `PERMISSIONS` |
| 3 | Choose calendars | `.calendarSelection` | **only if calendar granted** | `CALENDARS` |
| 4 | Download Local AI Models | `.modelDownload` | always | `AI MODELS` |
| 5 | You're all set | `.done` | always (terminal) | `FINISH` |

**Navigation:**
- Welcome → Continue → Grant access.
- Grant access → Continue/Skip → **if calendar granted** → Choose calendars;
  **else** → Download Models. (Same conditional that exists today between
  `.calendar` and `.calendarSelection`.)
- Choose calendars → Continue → Download Models.
- Download Models → Continue (or Skip) → You're all set.
- You're all set → Get Started → onboarding completes.

There is **no Back navigation** (matches today — the flow has always been
forward-only). No new branching is introduced.

### 1.1 · Deliberate deviations

The brief merges microphone + system audio into a single "Microphone & System
Audio" row and drops the Choose-calendars and Launch-at-Login screens. Our
deviations:

- **Microphone and System Audio are two separate rows.** They are distinct OS
  permissions with distinct prompts, and system-audio carries a unique
  validation/retry/Fix-permissions flow (see §3.2) that cannot be represented
  by a single Grant/Granted toggle. So the Grant access card has **four rows**.
- **Choose calendars remains as its own screen** (restyled), not dropped — it
  is a real behavior and only appears when calendar access is granted.
- **Launch at Login is removed from onboarding** (per product decision) and is
  governed by its default + the existing Settings toggle (see §6).

The flow is therefore **five screens max** (four when calendar access is not
granted).

---

## 2 · Progress affordance

The current step **dots** are replaced by a single thin **sage progress bar**
with a **monospace kicker** beneath it (per the brief's intent, realized with
project tokens — JetBrains Mono, sage). This is purely visual.

- The bar has **five fixed positions**, one per screen, regardless of which are
  shown: Welcome (20%), Grant access (40%), Choose calendars (60%), Download
  Models (80%), You're all set (100%). Fill = `(position + 1) / 5`.
- Each screen maps to its fixed position; the fill never moves backward.
- When calendar access is **not** granted, the Choose-calendars screen is
  skipped and the bar **jumps past** its position (Grant access 40% →
  Download Models 80%). Showing extra forward progress is preferred over a
  bar that appears stalled.
- Kicker text per screen is the right-hand column of the §1 table.
- Exact bar metrics, fill math, and kicker typography are in `ui_design.md`.

---

## 3 · Grant access screen (consolidated permissions)

One screen, one card, four rows. Each row independently triggers its own native
OS permission prompt and reflects that permission's live state.

**Footer button:** the screen footer shows **Skip** until **all four**
permissions are granted, then toggles to **Continue** — aggregating today's
per-step gating (each permission step showed Skip until granted, then Continue)
to the consolidated screen. "All granted" means `microphoneGranted &&
systemAudioGranted && calendarGranted && notificationsGranted`. Both Skip and
Continue advance the flow (to Choose calendars if calendar is granted, else
Download Models); the label is the of-record cue that some permissions are
still ungranted. Skipping a permission = not pressing its row's Grant.

Each row renders, by state:
- **Ungranted / not-yet-requested:** an actionable **Grant** control that fires
  the native prompt.
- **Granted:** a non-interactive granted indicator (checkmark + "GRANTED").
- **Denied / problem states:** the recovery affordances described below.

When a row's permission is **already granted** at screen entry (e.g. replaying
onboarding, or granted previously outside the wizard), it shows the granted
state immediately. This preserves `syncLivePermissionState()` behavior, which
must run for the consolidated screen so all four rows reflect live OS state on
entry, not just the one being interacted with.

### 3.1 · Microphone row

- Grant → `core.permissions.requestMicrophone()`. Result maps to
  `.authorized` / `.denied`.
- `.authorized` → granted indicator.
- `.denied` → **denial guidance**: warning icon + "Denied?" + an **Open System
  Settings** action (`openSettings(for: .microphone)`), exactly as today.

### 3.2 · System Audio row

Preserves the full `SystemAudioPermissionState` machine and the tone-probe
validation:

- Grant ("Request Access") → `core.requestSystemAudioPermission()`. While the
  tone-probe runs, show a **Validating…** indicator (`isValidatingSystemAudio`).
- Result states:
  - `.notRequested` → the Grant/Request Access control.
  - `.requestedNotVerified` → a "Not approved" indicator plus **Retry**
    (re-runs the request) and **Fix permissions** (opens the
    `FixPermissionsAlert` with the existing title/body; its "Open Settings"
    calls `openSystemAudioSettings()`).
  - `.approved` → granted indicator.

The `FixPermissionsAlert` and its copy
(`SystemAudioPermissionState.fixPermissionsAlertTitle` / `…Body`) are reused
unchanged.

### 3.3 · Calendar row

- Grant → `core.calendar.requestAccess()`, mapped to
  `.authorized` / `.denied` / `.notDetermined`, and mirrored into
  `core.permissions.noteCalendar(...)` (keeps the Settings pane consistent —
  preserve this side-effect).
- `.authorized` → granted indicator. (Granting calendar is what makes the
  Choose-calendars screen appear after Continue — see §1.)
- `.denied` → denial guidance with **Open System Settings**
  (`openSettings(for: .calendar)`), as today.

### 3.4 · Notifications row

- Grant → `core.permissions.requestNotifications()` → granted bool.
- Granted → granted indicator. (No denial-guidance link today for
  notifications; preserve that — granted shows a check, ungranted shows the
  Grant control.)

---

## 4 · Choose calendars screen (`.calendarSelection`)

Unchanged behavior, restyled.

- Reached only when calendar access was granted; on entry the calendar list is
  loaded (`core.calendar.calendars()`) and grouped by source
  (`groupCalendars`).
- Per-calendar toggles. Default is **all enabled** (`enabledCalendarIDs == nil`
  means "all"); toggling persists `enabledCalendarIDs` via
  `core.store.updateSettings`. When all are enabled the stored value collapses
  back to `nil`. **On persistence failure, the selection reverts** (current
  behavior — preserve).
- Footer: **Continue** (always enabled).

---

## 5 · Download Local AI Models screen (`.modelDownload`)

Unchanged behavior, restyled to the new identity (the brief's sage progress bar
for the download state; project components otherwise).

- **Disk-space check** runs when entering this screen (today: on advancing out
  of notifications; now: on advancing into model download, from either Grant
  access or Choose calendars). Required ≈ `requiredDiskSpaceMB` (2000 MB).
- **Insufficient disk:** show the warning **Banner** ("Not enough disk
  space…"). The Download control is **not** offered in this state; the user can
  only Skip (preserve current behavior).
- **Idle (sufficient disk):** a **Download Now** primary control →
  `startDownload()`.
- **Downloading:** progress indicator + status caption driven by
  `downloadStatus` (the live message stream from
  `ensureModelsReady`). Footer remains **Skip**.
- **Failure:** `downloadStatus` shows "Download failed. You can retry or skip."
  The Download control is available again to retry; Skip remains. (Preserve —
  no new auto-retry.)
- **Complete:** `downloadComplete == true` → "Models ready" granted indicator;
  footer becomes **Continue**.
- **Skip semantics:** the footer shows **Skip** until `downloadComplete`, then
  **Continue** — identical to today. Skipping mid-download does **not** cancel
  the in-flight task (current behavior; we do not add cancellation).

---

## 6 · Launch at Login (removed from onboarding)

The Launch-at-Login **screen is removed** from onboarding. Nothing is relocated
— the capability already lives in Settings and stays exactly as-is:

- Launch-at-login defaults **ON** — `BiscottiApp.registerLaunchAtLogin()`
  registers `SMAppService.mainApp` at first launch (unchanged).
- Users can toggle it any time in **Settings** (`SettingsView` launch-at-login
  toggle → `SettingsViewModel.setLaunchAtLogin`, with `SMAppService.mainApp`
  status as the source of truth). This already exists and is untouched.

Implementation: remove the `.launchAtLogin` step from the onboarding flow. The
now-unused `OnboardingViewModel.setLaunchAtLogin` and its `.launchAtLogin`
handling should be removed (the Settings path is the single owner). No
`SMAppService` behavior changes — onboarding simply no longer prompts for it.

---

## 7 · Welcome and Done screens

- **Welcome (`.welcome`):** serif title + lead copy + a single **Continue**
  primary button → Grant access. No actions/side-effects.
- **You're all set (`.done`):** serif title + lead copy + **Get Started** →
  `completeOnboarding()`, which persists `onboardingComplete = true`, transitions
  the route to Home, and starts the background services that were deferred during
  onboarding (preserve — this is `AppCore.completeOnboarding()`, untouched).

---

## 8 · Presentation & window model

- Onboarding remains a **full-window takeover** inside the existing single
  resizable main `Window(id: "main")` — gated on `core.route == .onboarding`
  via `AppShellView`. No new window scene; no change to the
  single-Window menu-bar architecture or the route-swap on completion.
- The window keeps its current resizability (min 640×400, default ≈1000×640).
  The roomy/centered look from the brief is achieved with **content max-width
  caps and centering**, not by fixing the window size.
- The window already hides its title bar (`WindowTitleHider`) and the traffic
  lights float; the onboarding layout must clear the floating lights (top
  padding), as today.

---

## 9 · Replay onboarding

The Settings debug "Replay Onboarding" path is preserved: toggling the route
back to `.onboarding` calls `resetForReplay()` (via `AppShellView`'s
`onChange(showOnboarding)` when the VM has advanced past welcome), resetting all
per-step state to the Welcome screen. The refresh must keep `resetForReplay()`
resetting the same fields it does today.

---

## 10 · Copy

Copy is part of the visual refresh and may be updated for tone, provided it
stays accurate. Proposed (adjustable in review):

- **Welcome** — title "Welcome to Biscotti"; lead "Private, on-device meeting
  transcripts. Nothing you say ever leaves your Mac."
- **Grant access** — title "Grant access"; lead "A few quick permissions —
  every one is used locally, nothing is sent anywhere."
- **Rows** (name / why):
  - Microphone — "Microphone" / "Record your voice locally to transcribe your
    meetings."
  - System Audio — "System Audio" / "Capture the other side of your call."
  - Calendar — "Calendar" / "Join meetings and connect event data"
  - Notifications — "Notifications" / "Alerts when meetings are starting"
- **Choose calendars** — title "Choose calendars"; lead "Select which calendars
  to monitor for meetings."
- **Download models** — title "Download Local AI Models"; lead "A one-time
  download (~1.5 GB). Everything runs entirely on your Mac — no cloud, ever."
- **You're all set** — title "You're all set"; lead "Start recording your first
  meeting whenever you like."

Footer brand lockup (passive, every screen): shield mark + "Biscotti" +
tagline "Total recall, total privacy." (matches the app's existing brand
lockup; see `ui_design.md`).

---

## 11 · Out of scope

- Any change to permission semantics, request order of side-effects, error
  handling, validation, persistence, or the conditional/terminal logic.
- A separate/fixed onboarding window scene (rejected; see §8).
- Back navigation, a progress "X of N" fraction, or step-skipping shortcuts.
- Dark mode (the app is light-only today).
- New permissions or new steps. Removing the **Choose calendars** step (it
  stays). The only step removed is **Launch at Login** (§6).
- Any change to the Settings launch-at-login toggle or `SMAppService`
  registration behavior/defaults.
- Download cancellation, auto-retry, or any change to model-download mechanics.
- Custom vocabulary work (blocked upstream; untouched).
- Changes to `AppCore`, `Permissions`, `Calendar`, or `TranscriptionService`
  APIs. The refresh lives in `OnboardingUI` (+ shared `DesignSystem`
  components if new reusable pieces are extracted).

---

## 12 · Acceptance

- `OnboardingUITests` are updated where they assert the **old screen structure**
  (separate per-permission steps, the `.launchAtLogin` step) or the old
  skip/continue gating, and otherwise preserved. Behavior assertions
  (permission results, the new aggregated skip→continue gating on Grant access,
  calendar-selection persistence + revert, download states/failure, completion)
  must hold. Tests covering the removed `.launchAtLogin` onboarding step are
  deleted; the Settings launch-at-login tests are untouched.
- The flow is reachable and completable on real hardware identically to today,
  with the new visuals.
- No regressions in `make ci` (lint + test + build).

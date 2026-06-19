---
status: complete
---

# UI Design: Notification UI

All new UI lives in the in-window **Settings** screen (`SettingsView`), plus one explanatory dialog. No new windows, no navigation changes. Everything reuses existing `SettingsView` idioms: grouped `Form` sections, the `VStack { control; Text(subtitle) }` row pattern (see "Exit app on window close"), default `Toggle`/`Picker`, and the design-system warning tokens.

## Section placement

A new **"Notifications"** `Section`, inserted between **General** and **Permissions**:

```
General
Notifications        ← new
Permissions
Calendars
```

Rationale: these are behavioral preferences (siblings of General), and grouping all notification controls together keeps them discoverable. The "Notifications" permission row stays in Permissions as today.

## "Notifications" section layout

```
┌─ Notifications ─────────────────────────────────────────────┐
│ Monitor for Meetings                              [ ●  ]     │
│ Detect when an app starts using your microphone and offer    │
│ to record. Nothing is recorded or processed unless you       │
│ start recording.                                             │
│                                                              │
│ Calendar Event Notifications        [ All Meetings    ▾ ]    │
│ Show a notification to record and join when a calendar       │
│ event starts.                                                │
│                                                              │
│ Stop Recording Automatically                      [ ●  ]     │
│ Stop recording when we detect your meeting has ended.        │
│                                                              │
│ Notifications Stay Visible                       [ Enable ]  │  ← only when alertStyle == .banner
│ Make notifications stay open until clicked or dismissed.     │
└──────────────────────────────────────────────────────────────┘
```

### Row 1 — Monitor for Meetings
`VStack(alignment:.leading)` containing a `Toggle("Monitor for Meetings", isOn:)` and a subtitle `Text` (`Tokens.metadataFont` / `Tokens.secondaryText`). Mirrors the "Exit app on window close" row.

### Row 2 — Calendar Event Notifications (`Picker`)
`VStack(alignment:.leading)`:
- `Picker("Calendar Event Notifications", selection:)` with three tagged options, display text: **"All Meetings"**, **"Meetings with Video Conferencing"**, **"Never"**.
- Subtitle `Text` below.
- **No-calendar-permission state** (`calendarState != .authorized`):
  - Picker is `.disabled(true)` and displays **"Never"** (display binding pins to `.never`; the stored value is untouched and restored when access returns).
  - A **warning badge** renders on its own line between the picker and the subtitle:

    ```
    Calendar Event Notifications              [ Never ▾ ]  (dimmed)
    ⚠ Requires Calendar Access
    Show a notification to record and join when a calendar event starts.
    ```
  - Badge = small capsule, `exclamationmark.triangle.fill` + "Requires Calendar Access", using `Tokens.warningChipFill` background + `Tokens.warningChipText` foreground (warning-ochre). Reuse/adapt the existing `StatChip`-style capsule; architecture decides reuse vs. a small inline helper.

### Row 3 — Stop Recording Automatically
Same shape as Row 1: `Toggle` + subtitle.

### Row 4 — Notifications Stay Visible (conditional helper)
Only rendered when `viewModel.alertStyle == .banner` (hidden for `.alert` and `.none`). Layout like a settings row with a trailing action button:
- Leading `VStack`: title **"Notifications Stay Visible"** + subtitle **"Make notifications stay open until clicked or dismissed."**
- Trailing: `Button("Enable")`, `.buttonStyle(.bordered)`, `.controlSize(.small)` (matches the permission action buttons).
- Tapping **Enable** presents the explanatory dialog (below). It does **not** itself change any setting — macOS doesn't allow that.

## Explanatory dialog ("Enable" → how-to)

A modal **sheet** (preferred over `.alert` so the numbered steps read cleanly), presented over Settings:

```
┌──────────────────────────────────────────────┐
│  Keep Notifications On Screen                  │
│                                                │
│  macOS decides how long notifications stay     │
│  on screen. To keep Biscotti's notifications   │
│  visible until you dismiss them, set their     │
│  style to “Alerts”.                            │
│                                                │
│   1.  Open System Settings → Notifications     │
│   2.  Select Biscotti                          │
│   3.  Set the alert style to “Alerts”          │
│                                                │
│            [ Cancel ]   [ Open Settings ]      │
└──────────────────────────────────────────────┘
```

- **Open Settings** → deep-links to the macOS Notifications settings pane (best-effort; macOS may not pre-select Biscotti, hence the explicit step 2). Then dismisses the sheet.
- **Cancel** → dismisses.
- Styling follows the design system (ivory background, system fonts, `.sage` for the primary button to match existing accents).
- On return to the app, `alertStyle` is re-read; if now `.alert`, Row 4 disappears.

## Interaction / state notes

- All three controls write through the `SettingsViewModel` (new properties + setters) following the existing `Binding` wrapper pattern; changes apply live.
- The picker's disabled/badge state and Row 4's visibility derive from observable state already (or newly) exposed on the view model: `calendarState` (exists) and `alertStyle` (new).
- No empty/loading states beyond what `SettingsView.task { load() }` already provides.

## Out of scope (UI)

- Notification banners themselves are rendered by macOS; we only control content/buttons/`interruptionLevel` (covered in the functional spec, not a UI surface here).
- No changes to onboarding, menu bar, or the record screen.

---
status: complete
---

# Implementation Plan: Notification UI

Three phases, each a coherent, independently reviewable unit. Details live in `functional_spec.md`, `ui_design.md`, and `architecture.md` (referenced by section).

## Phases

- [x] **Phase 1 — Settings: persistence, wiring, UI, and gating.**
  The three settings end-to-end, including the behavior they gate.
  - `DataStore`: new `CalendarNotificationMode` enum; `AppSettings` + `AppSettingsData` + read/write mapping (arch §1).
  - `AppCore`: 3 `Notification.Name`s, cached settings + loader, live observers (arch §3.1–3.3); the three gates — monitor guard in `handleDetectionStarted`, auto-stop guard in `handleAllMicUsersStopped`, `eventsToNotify(_:mode:)` + calendar-timer gating/re-check (arch §3.5–3.7).
  - `SettingsUI`: `SettingsViewModel` props/setters/`load`; `SettingsView` "Notifications" section — two toggles + the calendar-mode `Picker` with the disabled/"Requires Calendar Access" badge (arch §4.1–4.2, ui_design §Rows 1–3).
  - Tests: `DataStore` round-trip + enum; `eventsToNotify`; detection-notification + auto-stop gating; live-toggle wiring; ViewModel setters/load (arch §7).

- [x] **Phase 2 — Notification presentation & copy.**
  The meeting-detected and calendar-event notifications themselves.
  - `Notifications`: meeting-detected copy → "Meeting detected" / "App: {name}"; `.timeSensitive` on both kinds; "Record & Join"/"Record" action rework (`ActionID`, categories, `NotificationAction` drop `.join`, `ResponseMapper`); `cancelAdHocDetected()` + presented-ID tracking (arch §2.2–2.5).
  - `AppCore`: call `cancelAdHocDetected()` at the top of `startRecording`; drop the `.join` consumer case (arch §3.8–3.9).
  - App target: `AppDelegate` URL-open / window-foreground rewrite (arch §5).
  - Tests: `ResponseMapper`; `NotificationService` (copy, interruption level, categories, `cancelAdHocDetected`) (arch §7).

- [ ] **Phase 3 — "Notifications Stay Visible" row.**
  The self-hiding Alerts-style nudge.
  - `Notifications`: `NotificationAlertStyle`; provider `alertStyle()`; `NotificationService.currentAlertStyle()` (arch §2.1).
  - `AppCore`: `notificationsUseBannerStyle()` (arch §3.2).
  - `SettingsUI`: `showStayVisibleRow` + `refreshAlertStyle()` + `openNotificationSettings()`; the conditional row, the help sheet, and the `didBecomeActive` re-check (arch §4.1–4.3, ui_design §Row 4 + dialog).
  - Tests: `currentAlertStyle()` mapping; ViewModel `showStayVisibleRow` per scripted style (arch §7).

## Notes

- No `Packages/AudioCapture` or `Packages/Transcription` changes — the `manual-tests-check` gate stays untouched.
- Notification *presentation* (dwell, prominence, deep link, the row self-hiding) needs a manual hardware smoke test before sign-off (arch §7).
- Time-sensitive **entitlement** is deferred to Project 9; `.timeSensitive` degrades harmlessly until then.

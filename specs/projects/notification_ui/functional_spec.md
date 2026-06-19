---
status: complete
---

# Functional Spec: Notification UI

## Scope

Two coupled changes to Biscotti's notification experience:

1. **Notification settings** — three new user-facing controls on the Settings page (two toggles + one dropdown), each wired to live app behavior.
2. **Notification presentation & copy** — fix dwell/persistence, simplify copy, and correct the click/button behavior for the two foreground-flow notifications: the **calendar-event** notification and the **meeting-detected** notification.

The auto-stop **countdown** notification and the notification-permission request flow are unchanged except where noted.

---

## Part A — Notification Settings

Two of the three settings live in a new **"Notifications"** section on the Settings page; "Stop Recording Automatically" lives in the General section (see `ui_design.md`). Each persists to the existing SwiftData `AppSettings` store and takes effect **live** (no app restart), following the established pattern: ViewModel setter writes the store and posts a `Notification.Name` that `AppCore` observes to start/stop the relevant service.

### A1. Monitor for Meetings

- **Control:** Toggle. **Default: on.**
- **Title:** "Monitor for Meetings"
- **Subtitle:** "Detect when an app starts using your microphone and offer to record. Nothing is recorded or processed unless you start recording."
- **Behavior when ON:** When an app starts using audio I/O (a meeting), Biscotti posts a **meeting-detected** notification offering to record.
- **Behavior when OFF:** No meeting-detected notifications are posted (and no "detected-pending" state transition). The lightweight audio-activity monitor itself **keeps running** — it only observes *which apps have audio input/output active* (boolean flags from Core Audio process listeners), never any audio content, so there's no privacy reason to stop it and dependent features (e.g. auto-stop) keep working. "Off" simply silences the detection prompts.
- **Interaction with auto-stop (A3):** Fully independent. The monitor always runs, so A3 works regardless of A1. A1 gates only the detection *notification*; A3 gates only the auto-stop.
- **Permission dependency:** None. No badge.

### A2. Calendar Event Notifications

- **Control:** **Dropdown / Picker** (3 options). **Default: "All Meetings."**
  - **All Meetings** — notify before any *meeting-like* calendar event starts. "Meeting-like" = not all-day, not a birthday, and (has a detected video-call link **OR** has 2+ attendees).
  - **Meetings with Video Conferencing** — notify only for events where a video-call/conference link was detected.
  - **Never** — never post calendar-event notifications.
- **Title:** "Calendar Event Notifications"
- **Subtitle:** "Show a notification to record and join when a calendar event starts."
- **Disabled / no-permission state:** When calendar access is **not** authorized, the dropdown is **disabled**, **renders as "Never,"** and shows a yellow **"[Requires Calendar Access]"** badge (warning-ochre chip, reusing the design-system warning tokens). The stored value is preserved and restored once access is granted; while unauthorized the effective behavior is "Never" regardless of stored value.
- **Permission dependency:** Calendar (EventKit) authorization, read from the existing observable permission state.

### A3. Stop Recording Automatically

- **Control:** Toggle. **Default: on.**
- **Title:** "Stop Recording Automatically"
- **Subtitle:** "Stop recording when we detect your meeting has ended."
- **Behavior when ON:** Current behavior — when all non-Biscotti microphone users stop during an active recording, begin the auto-stop countdown (with its "Keep Recording" notification) and stop if not cancelled.
- **Behavior when OFF:** Never auto-stop; never post the countdown notification. Recording stops only on explicit user action.

---

## Part B — Notification Presentation & Copy

### B0. Persistence (applies to B1 and B2)

**Constraint (validated against macOS docs):** there is **no public API** to set a notification's on-screen dwell time or force "stay until dismissed." On-screen persistence is governed by the user's per-app **Alerts vs. Banners** style in System Settings → Notifications (Banners auto-dismiss after ~5s; Alerts persist until dismissed). `interruptionLevel` controls prominence/Focus-breakthrough, **not** dwell. Notifications *with action buttons* render in the more persistent alert presentation. The "hide after exactly 1 minute" goal is not achievable; the accepted fallback is "stay until dismissed," which requires Alerts style.

**Approach (chosen):**
1. Set `interruptionLevel = .timeSensitive` on the calendar-event and meeting-detected notifications (more prominent; breaks through Focus when permitted). The `com.apple.developer.usernotifications.time-sensitive` **entitlement is deferred to the signing project (Project 9)**; until it's added, `.timeSensitive` degrades harmlessly to `.active`.
2. Keep/relabel **action buttons** on both notifications (alert-style presentation).
3. Add a **self-hiding Settings row** guiding the user to set Biscotti's notification style to **"Alerts"** (for true stay-until-dismissed). See **B3**.

Both notifications already remain in **Notification Center** until dismissed — that part is unchanged.

### B1. Calendar-event notification

Two variants, selected by whether a video-call link was detected on the event:

**Variant 1 — event has a video-call link:**
- **Title:** event title (unchanged).
- **Subtitle/body:** unchanged from today (no new copy requested).
- **Single action button:** **"Record & Join."** (Label says "Join"; behavior = start recording **and** open the call link.)
- **Default action (tap the notification body):** same as the button — start recording **and** open the call link.
- **Foreground behavior:** opening the link brings the meeting app/browser to the front. Biscotti's own main window is **not** forced to the foreground (recording runs in the menu-bar background). Differs from today, which foregrounded Biscotti. *(Confirmed.)*
- Replaces today's two-button design ("Open & Record" + "Join"); the single "Record & Join" covers both. There is **no** separate "Join-only" button — intentionally removed. A user who wants to join *without* recording can use macOS Calendar's own event notification. *(Confirmed.)*

**Variant 2 — event has no video-call link** (only reachable when the dropdown is "All Meetings"):
- **Title:** event title.
- **Single action button:** **"Record"** (record only — there is no link to open).
- **Default action:** start recording. Background record; Biscotti window not forced foreground.

### B2. Meeting-detected notification

- **Title:** "Meeting detected" (was "Meeting detected in {App}").
- **Subtitle:** "App: {AppName}" — e.g. "App: Safari" (uses the notification `subtitle` field; body cleared).
- **Action button:** "Record" (unchanged) — records the detected app's meeting.
- **Suppression — must not appear during an active recording:**
  1. Keep the existing guard that suppresses *posting* when a recording is in progress.
  2. **Additionally**, when any recording **starts**, remove any already-delivered/pending meeting-detected notification(s) so a banner that arrived microseconds before "Record" doesn't linger on screen during recording.
  3. **Investigate root cause** of the reported "appeared while already recording" case and fix it (likely a race between detection-event delivery and recording start, or a stale already-delivered notification — points 1–2 should cover both, but confirm).
  - The existing calendar-notification suppression window (don't post meeting-detected shortly after a calendar notification) is retained.
- **Persistence:** per B0.

### B3. "Notifications Stay Visible" row (the Alerts-style guidance)

A **self-hiding row** in the Settings → Notifications section that guides the user to switch Biscotti's macOS notification style to **Alerts** (the only way to get stay-until-dismissed). No onboarding step, no popup, no just-in-time nag.

- **Row title:** "Notifications Stay Visible"
- **Subtitle:** "Make notifications stay open until clicked or dismissed."
- **Button:** "Enable."
- **Button action:** opens an **explanatory dialog** (sheet/alert) — macOS controls notification dwell, so we can't flip it for the user; the dialog explains how and offers a button to **open System Settings → Notifications** (deep-link; best-effort target of Biscotti, with a one-line "find Biscotti, choose Alerts" instruction since macOS may not pre-select the app). The dialog does not itself change any setting.
- **Visibility rule (self-hiding):** read the current `UNNotificationSettings.alertStyle`.
  - `.banner` → **show** the row (notifications are on but transient — this is who we're helping).
  - `.alert` → **hide** entirely (goal already met).
  - `.none` → **hide** (notifications are off; the existing Notifications permission row handles that case).
  - Re-evaluate when the app/Settings becomes active again, so the row disappears right after the user switches to Alerts.

---

## Part C — Behavior Wiring (what each setting gates)

| Setting | Gates |
|---|---|
| **Monitor for Meetings** (A1) | Whether **meeting-detected notifications** are presented (and the detected-pending transition happens). The audio-activity monitor always runs regardless. |
| **Calendar Event Notifications** (A2) | Whether calendar-start notifications are scheduled/posted, and for which events: *All Meetings* → all meeting-like events; *Meetings with Video Conferencing* → link-only; *Never* → none. |
| **Stop Recording Automatically** (A3) | Whether the auto-stop countdown + stop fires when a meeting's mic activity ends during a recording. |

**No monitor lifecycle management.** The audio-activity monitor runs continuously (as today) — it reads only per-process audio I/O flags, not audio content, so there is no privacy reason to stop it. A1 and A3 are pure presentation/behavior gates, checked when their respective detection events fire; toggling them takes effect live with no starting/stopping of the monitor.

---

## Edge Cases

- **Calendar permission revoked while dropdown is "All Meetings"/"Video":** dropdown becomes disabled, renders "Never," shows the badge; no calendar notifications fire (calendar fetch already requires auth). Stored mode is preserved and restored on re-grant.
- **Calendar permission granted while app running:** dropdown re-enables and restores the stored mode; badge disappears. (Relies on the existing observable permission refresh.)
- **Notification permission not granted:** no notifications post (existing behavior); the Alerts-style nudge (B0.3) is only meaningful once notifications are authorized.
- **Monitor off + recording started manually + auto-stop on:** auto-stop still works — the monitor always runs; A1 only suppressed the detection *notification*, not the monitor.
- **Meeting detected for the same app that's already being recorded:** suppressed (covered by B2 suppression).
- **Event with a link but the link fails to open:** recording still starts; link-open failure is logged, not surfaced as an error (best-effort, matches current `NSWorkspace.open` behavior).
- **Dropdown = "Never" but Monitor on:** ad-hoc meeting-detected notifications still fire; only calendar notifications are suppressed. (The two are independent surfaces.)

---

## Out of Scope

- The auto-stop **countdown** notification's copy/behavior (only gated on/off by A3).
- The notification-permission **request** flow and its UI.
- Adding the time-sensitive **entitlement** (deferred to the signing project, Project 9).
- Any change to *which* audio is captured, recording quality, or the detector's debounce tuning.
- Localization of the new copy.

---

## Open Items for Review

_All major behavior decisions resolved. Remaining details (exact section ordering, dialog copy, badge styling) are handled in the UI-design step._

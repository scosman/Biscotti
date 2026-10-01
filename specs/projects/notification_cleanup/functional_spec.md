---
status: complete
---

# Functional Spec: Notification Cleanup

## Problem

Biscotti posts two kinds of "offer to record" notifications at `.timeSensitive` priority:

- **Calendar notification** ("Record & Join" / "Record"), posted at the event start time.
- **"Meeting detected" notification**, posted when an app has held the microphone for 3 seconds.

Today, Biscotti removes "Meeting detected" notifications only when a recording starts. It never removes calendar notifications. Both kinds stay in Notification Center (and, with the "Alerts" style, on screen) long after they stop being useful.

## Goal

Remove each notification (from the screen **and** from Notification Center) when it no longer applies. The priority level does not change; removal is the fix.

"Remove" in this spec means: remove the delivered notification and any pending request with the same identifier. Removing a notification that the user has already dismissed is a silent no-op.

## Behaviors

### C1 — Calendar notification expires 5 minutes after the meeting starts

- When Biscotti posts a calendar notification for an event, it removes that notification at `event.start + 5 minutes`.
- The removal time is fixed when the notification is posted. It does not use the event end time, also for meetings shorter than 5 minutes.
- Calendar changes after the post have no effect on the removal: if the event is deleted, moved, or its notification setting changes, the notification is still removed at the original `start + 5 minutes`. A calendar refresh must not cancel or change a scheduled removal.

### C2 — A recording start removes calendar notifications

- When a recording starts, from any path (calendar notification action, "Meeting detected" action, menu bar, home, event preview, hotkey, etc.), Biscotti removes all of its calendar notifications at once, as it already does for "Meeting detected" notifications.
- After this removal, a scheduled C1 removal for the same notification is a no-op.

### D1 — "Meeting detected" notification is removed when the call ends

- When the meeting detector reports that a detected app stopped using the microphone (the existing per-app "stopped" signal: mic released for 8 seconds), Biscotti removes that app's "Meeting detected" notification.
- This applies in all run states, not only while the detection is pending.
- No added grace period. If an app releases the mic when the user mutes, the notification can go away during the muted period. This is acceptable.
- The existing behavior stays: a recording start removes all "Meeting detected" notifications.

### L1 — Cleanup at app launch

Delivered notifications stay in Notification Center after Biscotti quits or crashes. At launch, Biscotti examines its delivered notifications:

- **"Meeting detected" notifications:** remove all. Detection state starts fresh at launch, so none of them can still be tracked.
- **Calendar notifications:**
  - If the meeting started more than 5 minutes ago, remove the notification at once.
  - If the meeting started less than 5 minutes ago, schedule the removal at `start + 5 minutes` (as C1).
- Other notification kinds (for example, the auto-stop countdown) are not changed by the launch cleanup.

### L2 — Sleep and wake

Removal times are wall-clock times. If the Mac is asleep at a removal time, the removal occurs immediately after wake.

## Edge Cases

| Case | Behavior |
|---|---|
| User dismisses or clicks the notification before the removal time | The later removal is a silent no-op. |
| Calendar notification is not posted (suppressed because a recording runs, or mode is "Never") | No removal is scheduled. |
| The Mac sleeps through `start + 5 minutes`, so the calendar timer fires at wake | Do not post the calendar notification (it would already be expired). |
| Two calendar events start at the same time | Each notification has its own removal at its own `start + 5 minutes`. |
| Two apps detected (two "Meeting detected" notifications) | Each app's notification is removed when that app's "stopped" signal arrives. |
| Notification authorization is denied | Removal still runs (cleanup is always valid), as `cancelCountdown` does today. |
| Recording start fails after the notifications are removed | The notifications stay removed. |

## Out of Scope

- Changing notification priority (`.timeSensitive`) or presentation.
- The auto-stop countdown notification (already removed when the countdown is cancelled or the recording stops).
- Removing notifications when settings change (for example, "Monitor for Meetings" turned off, or the calendar mode set to "Never"). Existing notifications expire through C1 / D1 / L1.
- Any new user setting. The 5-minute window is a constant in code.
- UI changes. This project has no user-facing UI apart from notifications that go away.

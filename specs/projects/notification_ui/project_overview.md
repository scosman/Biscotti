---
status: complete
---

# Notification UI

A project to update Biscotti's in-app notifications — both the notifications themselves (presentation + copy + behavior) and the notification-related settings.

## Notification Settings

Add these three settings to the Settings page, and wire them up:

- **"Monitor for Meetings"** — "Detect when an app starts using your microphone and offer to record. Nothing is recorded or processed unless you start recording." A toggle. Default **on**. When off, don't monitor audio for sending [notifications].
- **"Calendar Event Notifications"** — "Show a \"Record & Join\" notification when a calendar event with a video call link is about to start." Toggle, default **on**. Disabled and renders as off if no calendar permissions, and add a yellow "[Requires Calendar Access]" badge when disabled because no calendar permissions.
- **"Stop Recording Automatically"** — "Stop recording when we detect your meeting has ended." Toggle, default **on**.

## Notification presentation and copy

- **Notification for calendar event**
  - Only appeared for a second; should stay visible 1 min ideally then hide (but still be in the list). If we can't "hide after 1 min," prefer stay open until dismissed (check macOS notification docs/options).
  - Clicking the notification started recording, but didn't open the link. The default action should be **"Record & Open"**.
  - Ideally there would be a button on it that says **"Record & Open"**.
- **"Meeting detected" notification**
  - Text: simplify the notification to **"Meeting detected"**, and subtitle to **"App: Safari"**. It was too wordy today.
  - Shown when already recording — should have been filtered, and not appear if recording is in progress.
  - Only appeared for a second; should stay visible 1 min+ (same as above).

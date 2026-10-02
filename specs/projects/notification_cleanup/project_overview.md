---
status: complete
---

# Notification Cleanup

Biscotti needs to close notifications when they no longer apply.

- **Meeting/time based ones** (calendar event notifications): remove them 5 minutes after the meeting starts.
- **"Meeting detected" based ones**: remove them when the call ends.

Today we show notifications with high priority, and never remove them.

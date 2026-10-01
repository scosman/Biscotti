---
status: complete
---

# Implementation Plan: Notification Cleanup

## Phases

- [x] Phase 1: All of `architecture.md` — `Notifications` module (event start in `userInfo`, `deliveredNotifications()` seam + `DeliveredNotification`, new `cancel…`/query methods on `NotificationService`, fakes model delivery) and `AppCore` wiring (C1 expiry timers + late-post skip, C2 on recording start, D1 on detection stopped, L1 launch cleanup), with the tests in architecture §4.

---
status: complete
---

# Phase 6: Background coordination + menu bar (completes Project 6)

## Overview

This phase wires the detection, notification, and calendar modules into AppCore's background coordination layer, adds the MenuBarUI module, and updates the app target for background operation. The result: the app runs headlessly in the menu bar, detects meetings, fires notifications with actionable buttons, schedules calendar-start timers, applies auto-stop countdowns for detection-driven recordings, and enforces one-recording-at-a-time with de-dup. All coordination logic is unit-testable via an `AppScheduler` clock seam and fake services.

## Steps

### 1. AppScheduler clock seam (`AppCore/AppScheduler.swift`)
- Define `AppScheduler` protocol with `sleep(for:)` and `now()`.
- Implement `LiveAppScheduler` using `ContinuousClock`.
- Both types are `public` (init param on AppCore).

### 2. RunState enum (`AppCore/RunState.swift`)
- `public enum RunState: Sendable, Equatable { case idle, recording(UUID), detectedPending }`.

### 3. Extend AppCore with background coordination
- Add `MeetingDetector`, `NotificationService` as dependencies.
- Add `RunState`, `AppScheduler`, detection/notification consumer tasks, calendar timer tasks, countdown task.
- Add `isDetectionDriven`, `activeDetectedBundleID`, `pendingCalendarNotificationTimestamp` for de-dup.
- Implement `consumeDetectorEvents()`, `consumeNotificationActions()`, `handleDetectionStarted`, `handleDetectionStopped`, `beginAutoStopCountdown`, `cancelAutoStopCountdown`, `scheduleCalendarTimers`, `handleCalendarTimerFired`, `startUpcomingMirrorTask`, `recordDetectedEvent`.
- Update `startRecording` to guard on `runState`.
- Update `stopRecording` to clear detection state and cancel countdown.
- Update `onLaunch` and `completeOnboarding` to start detector and notification consumers.

### 4. Update `AppCore.live(...)` factory
- Build `MeetingDetector` (live activity source) and `NotificationService` (live center).
- Pass them to AppCore init along with a new `BundledMeetingCatalog`.

### 5. Update PreviewAppCore
- Add `MeetingDetector` and `NotificationService` fakes to preview factory.

### 6. Update BiscottiTestSupport CoreFixture
- Add `MeetingDetector`, `NotificationService`, `FakeScheduler` to the fixture.
- `FakeScheduler` implementation with controllable clock advancement.

### 7. MenuBarUI module (`Sources/MenuBarUI/`)
- `MenuBarViewModel`: icon state, body state, formatting helpers, actions.
- `MenuBarContentView`: recording section, upcoming, recent, open/quit.
- `MenuBarLabelView`: icon + optional next-meeting text.
- Add to Package.swift with deps: AppCore, DataStore, DesignSystem.

### 8. App target updates (`App/`)
- Add `MenuBarExtra` scene in `BiscottiApp`.
- Add `NSApplicationDelegateAdaptor` for don't-quit-on-close, quit-while-recording, `UNUserNotificationCenterDelegate`.
- Add `SMAppService` launch-at-login registration.
- Add MenuBarUI + Notifications dependencies in project.yml.
- `NSCalendarsFullAccessUsageDescription` already in Info.plist (verified).

### 9. Unit tests for AppCore background slice
- `AppCoreBackgroundTests.swift`: detection -> notification flow, de-dup, auto-stop countdown, keep-recording cancel, calendar-start timers, reschedule, RunState transitions, onboarding gate, notification action dispatch.

### 10. Unit tests for MenuBarUI
- `MenuBarViewModelTests.swift`: icon state, formatting helpers, upcoming/recent limits, action delegation.

## Tests

### AppCore background coordination tests
- `detectionStartedPresentsAdHocNotification`: ad-hoc detection -> notification + detectedPending
- `suppressesAdHocWhileRecording`: no notification while recording
- `suppressesAdHocWhenCalendarRecentlyPrompted`: de-dup within suppression window
- `openAndRecordActionStartsRecording`: notification action -> start recording
- `openAndRecordNilKeyUsesBestMatch`: nil eventKey falls through to bestMatch
- `keepRecordingCancelsCountdown`: cancel auto-stop, recording continues
- `autoStopCountsDownAndStops`: 15s countdown -> auto-stop
- `manualRecordingDoesNotAutoStop`: detection stop ignored for manual recordings
- `detectionStoppedForWrongAppIgnored`: wrong bundleID ignored
- `calendarStartTimerPresentsAtStart`: timer fires at event start time
- `calendarTimerSuppressedWhileRecording`: no notification while recording
- `calendarTimerSkipsAlreadyStartedEvents`: past events skipped
- `runStateTransitionsManualFlow`: idle -> recording -> idle
- `runStateTransitionsDetectionFlow`: idle -> detectedPending -> recording -> idle
- `oneRecordingAtATimeRejectsSecondStart`: guard prevents double-start
- `onboardingGateSkipsDetection`: onLaunch with incomplete onboarding skips detection start
- `completeOnboardingStartsBackgroundServices`: starts detector + consumers after onboarding
- `detectedPendingResetsOnDetectionStop`: detectedPending -> idle when detected app stops

### MenuBarUI tests
- `menuBarIconIdleWhenNoUpcoming`: iconState == .idle
- `menuBarIconShowsNextMeetingWithin2h`: iconState == .nextMeeting
- `menuBarIconShowsRecordingWhenActive`: iconState == .recording
- `menuBarTruncatesTitleNotTime`: truncation with ellipsis
- `menuBarRelativeTimeFormats`: "in 5m", "in 1h 12m", "now"
- `menuBarIsWithin2Hours`: boundary checks
- `menuBarUpcomingLimitedTo2`: at most 2 items
- `menuBarRecentLimitedTo2`: at most 2 items
